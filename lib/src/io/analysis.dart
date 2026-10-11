import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:path/path.dart' as p;

import '../mutant.dart';
import '../typed_mutators.dart';

/// Where `dart pub get` / `flutter pub get` writes how the packages of a
/// package are resolved.
const packageConfigPath = '.dart_tool/package_config.json';

/// Thrown when a package cannot be analyzed.
class AnalysisUnavailable implements Exception {
  AnalysisUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The Dart SDK the package in [root] is resolved with: the one inside the
/// Flutter SDK that its package configuration names, or `null` (the SDK this
/// program runs on) for a package without Flutter.
String? sdkPathOf(String root) {
  // In a pub workspace the configuration is in the directory of the
  // workspace, above the package.
  var directory = root;
  File configIn(String directory) =>
      File(p.join(directory, '.dart_tool', 'package_config.json'));
  while (!configIn(directory).existsSync() &&
      p.dirname(directory) != directory) {
    directory = p.dirname(directory);
  }
  final config = configIn(directory);
  final Object? decoded;
  try {
    decoded = jsonDecode(config.readAsStringSync());
  } on FileSystemException {
    throw AnalysisUnavailable(
      '$packageConfigPath not found. Run "dart pub get" (or "flutter pub '
      'get") in the package first',
    );
  } on FormatException {
    throw AnalysisUnavailable('$packageConfigPath is not valid JSON');
  }
  final flutterRoot = decoded is Map ? decoded['flutterRoot'] : null;
  if (flutterRoot is! String) {
    return null;
  }
  final sdk = p.join(
    Uri.parse(flutterRoot).toFilePath(),
    'bin',
    'cache',
    'dart-sdk',
  );
  if (!Directory(sdk).existsSync()) {
    throw AnalysisUnavailable(
      'the Dart SDK of the Flutter SDK in $packageConfigPath is not there '
      '($sdk). Run "flutter pub get" in the package',
    );
  }
  return sdk;
}

/// True for what the compiler refuses, whatever `analysis_options.yaml`
/// says about its severity.
bool _refusedByCompiler(Diagnostic diagnostic) {
  final type = diagnostic.diagnosticCode.type;
  return type == DiagnosticType.COMPILE_TIME_ERROR ||
      type == DiagnosticType.SYNTACTIC_ERROR;
}

/// The `analysis_options.yaml` files below [directory], outside the
/// directories of the tools (`.dart_tool`, `build`, …): the options of a
/// directory apply to the files below it.
Iterable<String> _optionsBelow(Directory directory) sync* {
  final List<FileSystemEntity> entities;
  try {
    entities = directory.listSync(followLinks: false);
  } on FileSystemException {
    return;
  }
  for (final entity in entities) {
    final name = p.basename(entity.path);
    if (entity is File && name == 'analysis_options.yaml') {
      yield p.normalize(entity.path);
    } else if (entity is Directory &&
        !name.startsWith('.') &&
        name != 'build') {
      yield* _optionsBelow(entity);
    }
  }
}

String _withoutMark(String content) =>
    content.startsWith('﻿') ? content.substring(1) : content;

/// A package opened with `package:analyzer`, to resolve a file and to ask
/// whether a changed content of it still compiles. Nothing is written: the
/// changed content is laid over the file in memory.
///
/// The package is read the way its own tools read it
/// (`.dart_tool/package_config.json`, the SDK that file names), so this
/// program does not have to be a dependency of the package.
class PackageAnalysis {
  PackageAnalysis._(this.root, this._overlay, this._collection);

  /// Opens the package in [root] (absolute). Throws [AnalysisUnavailable]
  /// when its packages are not resolved.
  factory PackageAnalysis.open(String root) {
    final normalized = p.normalize(p.absolute(root));
    final sdk = sdkPathOf(normalized);
    final overlay = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE);
    // The options of the package are for its authors, and none of them says
    // whether a mutant compiles: `exclude` hides files from the analyzer,
    // the strict modes report what the compiler accepts, and `errors` can
    // turn a compile error into a hint. An empty file stands in for them.
    for (final options in [
      p.join(normalized, 'analysis_options.yaml'),
      ..._optionsBelow(Directory(normalized)),
    ]) {
      overlay.setOverlay(options, content: '', modificationStamp: 0);
    }
    return PackageAnalysis._(
      normalized,
      overlay,
      AnalysisContextCollection(
        includedPaths: [normalized],
        resourceProvider: overlay,
        sdkPath: sdk,
      ),
    );
  }

  final String root;
  final OverlayResourceProvider _overlay;
  final AnalysisContextCollection _collection;
  int _stamp = 1;

  /// By path: what the compiler refuses in the file as it is, before a
  /// mutant. A file can have such errors without being broken (a generated
  /// part that is not there); only what a mutant adds counts against it.
  final _baseline = <String, Map<String, int>>{};

  String _absolute(String path) =>
      p.normalize(p.joinAll([root, ...path.split('/')]));

  AnalysisContext _contextOf(String file) => _collection.contextFor(file);

  Future<void> _setContent(String file, String content) async {
    _overlay.setOverlay(file, content: content, modificationStamp: _stamp++);
    final context = _contextOf(file);
    context.changeFile(file);
    await context.applyPendingFileChanges();
  }

  /// The messages of what the compiler refuses in [file], and how often
  /// each is given. The place is left out: a mutant moves what follows it.
  Future<Map<String, int>> _refused(String file) async {
    final result = await _contextOf(file).currentSession.getErrors(file);
    if (result is! ErrorsResult) {
      throw AnalysisUnavailable('cannot analyze $file');
    }
    final counts = <String, int>{};
    for (final diagnostic in result.diagnostics.where(_refusedByCompiler)) {
      counts.update(
        diagnostic.message,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    return counts;
  }

  /// Takes [content] as the content of [path] (relative to the package, with
  /// `/`) and returns the typed mutants of it. [content] may start with a
  /// byte order mark; the offsets count it.
  Future<List<Mutant>> typedMutantsOf(String path, String content) async {
    final file = _absolute(path);
    final plain = _withoutMark(content);
    final shift = content.length - plain.length;
    await _setContent(file, plain);
    _baseline[path] = await _refused(file);
    final result = await _contextOf(file).currentSession.getResolvedUnit(file);
    if (result is! ResolvedUnitResult) {
      throw AnalysisUnavailable('cannot resolve $path');
    }
    return [
      for (final mutant in findTypedMutants(
        result.unit,
        plain,
        result.typeProvider,
        result.typeSystem,
      ))
        Mutant(
          mutant.mutator,
          mutant.offset + shift,
          mutant.end + shift,
          mutant.replacement,
        ),
    ];
  }

  /// Why [mutated], as the content of [path], does not compile: the first
  /// message of the analyzer that the file did not have before, or had less
  /// often
  /// ([typedMutantsOf] has to be called for [path] first). `null` when it
  /// compiles as well as the file did.
  ///
  /// Only [path] is looked at. A mutant that breaks another file (a changed
  /// signature) is found when the tests are compiled.
  Future<String?> compileErrorOf(String path, String mutated) async {
    final file = _absolute(path);
    final baseline = _baseline[path]!;
    await _setContent(file, _withoutMark(mutated));
    final refused = await _refused(file);
    for (final MapEntry(key: message, value: count) in refused.entries) {
      if (count > (baseline[message] ?? 0)) {
        return message;
      }
    }
    return null;
  }

  /// Forgets the content given for [path]: the file is read from the disk
  /// again.
  Future<void> release(String path) async {
    final file = _absolute(path);
    _baseline.remove(path);
    _overlay.removeOverlay(file);
    final context = _contextOf(file);
    context.changeFile(file);
    await context.applyPendingFileChanges();
  }

  Future<void> dispose() => _collection.dispose();
}
