import 'dart:convert';
import 'dart:io';

import 'package:dart_mutant/dart_mutant.dart';

import 'compiled.dart';

/// A package in a temporary directory whose packages are "resolved" without
/// `dart pub get`: a package configuration that only knows the package
/// itself is enough for code that imports `dart:` libraries and its own
/// files.
class PackageFixture {
  PackageFixture({String name = 'fixture'})
    : dir = Directory(
        Directory.systemTemp
            .createTempSync('dart_mutant_')
            .resolveSymbolicLinksSync(),
      ) {
    write('pubspec.yaml', 'name: $name\nenvironment:\n  sdk: ^3.11.0\n');
    write(
      '.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': name,
            'rootUri': '../',
            'packageUri': 'lib/',
            'languageVersion': '3.11',
          },
        ],
      }),
    );
  }

  final Directory dir;
  final out = <String>[];
  final err = <String>[];

  String get path => dir.path;

  void delete() {
    dir.deleteSync(recursive: true);
    if (_shared != null) {
      _shared!.deleteSync(recursive: true);
    }
  }

  Directory? _shared;

  /// A directory outside the package, for what the stand-in for the test
  /// runner writes when it is started in copies of the package.
  Directory get shared => _shared ??= Directory(
    Directory.systemTemp
        .createTempSync('dart_mutant_shared_')
        .resolveSymbolicLinksSync(),
  );

  /// [fake], writing its log to [shared].
  List<String> get sharedFake => [...fake, '--shared=${shared.path}'];

  List<String> _sharedFiles(String prefix) => [
    for (final entity in shared.listSync())
      if (entity.uri.pathSegments.last.startsWith(prefix))
        entity.uri.pathSegments.last.substring(prefix.length),
  ];

  /// The process ids of the runs of [sharedFake].
  List<String> get sharedRuns => _sharedFiles('run.');

  /// The directories the runs of [sharedFake] were started in.
  List<String> get sharedRunDirectories => [
    for (final run in sharedRuns)
      File('${shared.path}/run.$run').readAsStringSync(),
  ];

  /// The process ids of the runs of [sharedFake] that hung.
  List<String> get sharedHung => _sharedFiles('started.');

  /// Forgets the runs of [sharedFake] so far.
  void clearShared() {
    for (final entity in shared.listSync()) {
      entity.deleteSync();
    }
  }

  File file(String path) => File('${dir.path}/$path');

  void write(String path, String content) => file(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  String read(String path) => file(path).readAsStringSync();

  Io get io => Io(out: out.add, err: err.add);

  /// The stand-in for the test runner, see
  /// test/fixtures/run/fake_test.dart.txt.
  List<String> get fake => _script ?? [compiledFake()];

  List<String>? _script;

  /// Makes [fake] a program of the test's own: [source] is run from the
  /// package, as `dart fake_test.dart`.
  void fakeFromSource(String source) {
    write('fake_test.dart', source);
    _script = [Platform.resolvedExecutable, 'fake_test.dart'];
  }

  /// A test file as the stand-in reads it: the rules it checks [target]
  /// with.
  void fakeTest(String target, List<String> rules, {String? at}) => write(
    at ?? target.replaceFirst('.dart', '_test.dart'),
    ['// file: $target', for (final rule in rules) '// $rule', ''].join('\n'),
  );

  List<String> get runs => file('runs.log').existsSync()
      ? file('runs.log').readAsLinesSync()
      : const [];
}
