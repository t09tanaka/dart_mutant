import 'dart:convert';

import 'json.dart';

/// One file to mutate, and the test files that are run on its mutants.
class Target {
  const Target(this.file, this.tests);

  /// Relative to the package, with `/`.
  final String file;

  /// Relative to the package, with `/`. May be empty: the run then fails for
  /// this file, because nothing could judge its mutants.
  final List<String> tests;
}

/// Thrown by [parsePlan] when the text is not a plan.
class PlanError implements Exception {
  PlanError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// True when [path] names something inside the package the way a plan and
/// the report write it: relative, with `/`, without `.` or `..` segments.
bool isPlainRelativePath(String path) =>
    path.isNotEmpty &&
    !path.contains(r'\') &&
    !RegExp(r'^[A-Za-z]:').hasMatch(path) &&
    path
        .split('/')
        .every((part) => part.isNotEmpty && part != '.' && part != '..');

/// [path] as it is compared: `\` as `/`, and without `./` in front.
String normalizePath(String path) =>
    path.replaceAll(r'\', '/').replaceFirst(_leadingDots, '');

final _leadingDots = RegExp(r'^(\./)+');

/// Reads a plan file: which files to mutate, and for each the tests to run.
///
/// ```json
/// {
///   "version": 1,
///   "targets": [
///     {"file": "lib/price.dart", "tests": ["test/price_test.dart"]}
///   ]
/// }
/// ```
///
/// The order of `targets` is the order of the run and of the report. A file
/// may be listed once.
List<Target> parsePlan(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (error) {
    throw PlanError('is not valid JSON: ${error.message}');
  }
  final root = asObject(decoded);
  if (root == null) {
    throw PlanError('must be a JSON object');
  }
  if (root['version'] != 1) {
    throw PlanError('"version" must be 1');
  }
  final rawTargets = root['targets'];
  if (rawTargets is! List || rawTargets.isEmpty) {
    throw PlanError('"targets" must be a list with at least one entry');
  }
  final targets = <Target>[];
  final seen = <String>{};
  for (final (index, item) in rawTargets.indexed) {
    final at = 'targets[$index]';
    final target = asObject(item);
    final file = target?['file'];
    final tests = asStrings(target?['tests']);
    if (file is! String || tests == null) {
      throw PlanError(
        '$at must have "file" (a string) and "tests" (a list of strings)',
      );
    }
    for (final path in [file, ...tests]) {
      if (!isPlainRelativePath(path)) {
        throw PlanError(
          '$at: ${jsonEncode(path)} must be a path inside the package, '
          'relative to it, written with "/" and without "." or ".."',
        );
      }
    }
    if (!file.endsWith('.dart')) {
      throw PlanError('$at: ${jsonEncode(file)} is not a .dart file');
    }
    if (!seen.add(file)) {
      throw PlanError('$at: ${jsonEncode(file)} is listed twice');
    }
    if (tests.toSet().length != tests.length) {
      throw PlanError('$at: a test is listed twice');
    }
    targets.add(Target(file, tests));
  }
  return targets;
}

final _libPrefix = RegExp('^lib/');

/// Where the test of [file] is looked for when no plan says so, in order:
/// next to it (`lib/a/b.dart` → `lib/a/b_test.dart`), and the mirror under
/// `test/` (`test/a/b_test.dart`).
List<String> defaultTestCandidates(String file) {
  final base = file.substring(0, file.length - '.dart'.length);
  return {
    '${base}_test.dart',
    '${base.replaceFirst(_libPrefix, 'test/')}_test.dart',
  }.toList();
}

/// True when [argument] is a glob, not a path.
bool isGlob(String argument) => RegExp(r'[*?\[\]{}]').hasMatch(argument);

/// The targets a run is limited to with `--only`: those of [files] that are
/// in [requested], in the order of [files], and the requested paths that are
/// no target. No request means every file.
({List<String> selected, List<String> unknown}) selectTargets(
  List<String> files,
  List<String> requested,
) {
  final wanted = requested.map(normalizePath).toSet();
  return (
    selected: [
      for (final file in files)
        if (wanted.isEmpty || wanted.contains(file)) file,
    ],
    unknown: [
      for (final path in wanted)
        if (!files.contains(path)) path,
    ],
  );
}
