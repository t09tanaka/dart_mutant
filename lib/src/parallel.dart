import 'dart:convert';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'json.dart';

/// The most test runs that are started at a time when `--jobs` does not say.
const maxDefaultJobs = 4;

/// How many test runs are started at a time when `--jobs` does not say, on a
/// machine with [processors] logical processors: a quarter of them, at least
/// one and at most [maxDefaultJobs].
///
/// One test run is more than one busy thread (the compiler, the test runner
/// and the process that runs the tests), so the number of processors itself
/// would be too many: the runs then slow each other down, and what a mutant
/// costs comes close to its time limit.
int defaultJobs(int processors) => max(1, min(processors ~/ 4, maxDefaultJobs));

/// The directories that are not copied into a working copy, wherever they
/// are in the package: what version control and the tools write, which no
/// test reads and which can be large.
const skippedDirectories = {
  '.git',
  'node_modules',
  'Pods',
  '.gradle',
  '.idea',
  '.symlinks',
};

/// The same, for a directory at the top of the package only. `build` is the
/// output of `flutter build`; further down (`lib/src/build`) it can be
/// source.
const skippedAtTop = {'build', 'coverage', 'reports'};

/// The directories of the platforms of a Flutter app, at the top of the
/// package. A `build` directory anywhere below one of them is the output of
/// that platform's build tool.
const platformDirectories = {
  'android',
  'ios',
  'linux',
  'macos',
  'web',
  'windows',
};

/// The same, directly below a `.dart_tool` (of the package, or of a package
/// inside it): the state of this tool (the working copies are in it), and
/// the caches of the build tools. What the test runners need
/// (`package_config.json`, `version`, the snapshot of the test runner, the
/// native assets) is copied.
const skippedInDartTool = {'dart_mutant', 'build', 'flutter_build'};

/// True when [path] (relative to the package, with `/`), or a directory above
/// it, is left out of a working copy.
bool skippedInCopy(String path) {
  final segments = path.split('/');
  for (final (index, segment) in segments.indexed) {
    if (skippedDirectories.contains(segment)) {
      return true;
    }
    if (index == 0 && skippedAtTop.contains(segment)) {
      return true;
    }
    // (`build` itself is no platform directory, so this is never the first
    // segment.)
    if (segment == 'build' && platformDirectories.contains(segments.first)) {
      return true;
    }
    if (index > 0 &&
        segments[index - 1] == '.dart_tool' &&
        skippedInDartTool.contains(segment)) {
      return true;
    }
  }
  return false;
}

final _workspace = RegExp(
  r'^(resolution:\s*workspace|workspace:)',
  multiLine: true,
);

/// Why the package in [root] (absolute) cannot be run from a copy of its
/// directory, or `null` when it can. [resolvedRoot] is [root] without
/// symbolic links, when that is another path: the package configuration can
/// name the package by either.
///
/// [pubspec] is its `pubspec.yaml` and [packageConfig] its
/// `.dart_tool/package_config.json` (`null` when there is none). A copy is a
/// directory somewhere else, so it only works when nothing in the package
/// configuration depends on where the package is:
///
/// - a pub workspace keeps one configuration above its packages;
/// - a `path:` dependency outside the package (`../shared`) is written
///   relative to the package, and would point somewhere else from the copy;
/// - a package inside the package that is written as an absolute path would
///   still be read from the package, not from the copy, so that a mutant in
///   the copy would not be seen by the tests.
///
/// A `path:` dependency inside the package (`packages/api`) is written
/// relative and is copied with the package.
String? copyObstacle({
  required String root,
  required String pubspec,
  required String? packageConfig,
  String? resolvedRoot,
}) {
  bool inPackage(String location) => [
    root,
    ?resolvedRoot,
  ].any((root) => location == root || p.isWithin(root, location));

  if (_workspace.hasMatch(pubspec.replaceAll('\r\n', '\n'))) {
    return 'the package is part of a pub workspace';
  }
  if (packageConfig == null) {
    return 'the package has no .dart_tool/package_config.json of its own';
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(packageConfig);
  } on FormatException {
    return '.dart_tool/package_config.json is not valid JSON';
  }
  final packages = asObject(decoded)?['packages'];
  if (packages is! List) {
    return '.dart_tool/package_config.json lists no packages';
  }
  final configDirectory = p.join(root, '.dart_tool');
  for (final package in packages) {
    final entry = asObject(package);
    final name = entry?['name'];
    final rootUri = entry?['rootUri'];
    if (rootUri is! String) {
      continue;
    }
    final Uri uri;
    try {
      uri = Uri.parse(rootUri);
    } on FormatException {
      continue;
    }
    if (uri.hasScheme) {
      if (!uri.isScheme('file')) {
        continue;
      }
      final location = p.normalize(uri.toFilePath());
      if (inPackage(location)) {
        return 'the package "$name" is inside the package and written as an '
            'absolute path in .dart_tool/package_config.json';
      }
    } else {
      final location = p.normalize(
        p.join(configDirectory, p.fromUri(Uri(path: uri.path))),
      );
      if (!inPackage(location)) {
        return 'the dependency "$name" is at a path relative to the package '
            '($rootUri)';
      }
    }
  }
  return null;
}
