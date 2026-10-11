import 'dart:convert';

import 'package:dart_mutant/src/io/analysis.dart';
import 'package:test/test.dart';

import 'support/package_fixture.dart';

void main() {
  late PackageFixture package;

  setUp(() => package = PackageFixture());

  tearDown(() => package.delete());

  /// Whether each of [contents] compiles as the content of lib/a.dart,
  /// which holds [source].
  Future<List<bool>> compiles(String source, List<String> contents) async {
    package.write('lib/a.dart', source);
    final analysis = PackageAnalysis.open(package.path);
    await analysis.typedMutantsOf('lib/a.dart', source);
    final verdicts = [
      for (final content in contents)
        await analysis.compileErrorOf('lib/a.dart', content) == null,
    ];
    await analysis.dispose();
    return verdicts;
  }

  test('what the compiler refuses is told from what it accepts', () async {
    expect(
      await compiles('int f(int a, int b) => a * b;\n', [
        'int f(int a, int b) => a + b;\n',
        // A double where an int is returned.
        'int f(int a, int b) => a / b;\n',
        // Not Dart.
        'int f(int a, int b) => a * ;\n',
        // Only a warning: an unused variable.
        'int f(int a, int b) { var c = 1; return a * b; }\n',
      ]),
      [true, false, false, true],
    );
  });

  test('the message says why', () async {
    const source = 'int f(String? s) => s == null ? 0 : s.length;\n';
    package.write('lib/a.dart', source);
    final analysis = PackageAnalysis.open(package.path);
    await analysis.typedMutantsOf('lib/a.dart', source);
    expect(
      await analysis.compileErrorOf(
        'lib/a.dart',
        'int f(String? s) => s != null ? 0 : s.length;\n',
      ),
      contains("'length' can't be unconditionally accessed"),
    );
    await analysis.dispose();
  });

  test('errors the file already has are not counted against a mutant: a '
      'generated part that is not there', () async {
    const source = '''
part 'a.g.dart';

int f(int a) => a + generated();
''';
    expect(
      await compiles(source, [
        source.replaceFirst('+', '-'),
        source.replaceFirst('a +', "'' +"),
      ]),
      [true, false],
    );
  });

  test('analysis_options.yaml of the package decides nothing: strict '
      'modes, exclude, and errors turned into something else', () async {
    package.write('analysis_options.yaml', '''
analyzer:
  exclude:
    - lib/**
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true
  errors:
    return_of_invalid_type: ignore
    dead_code: error
''');
    expect(
      await compiles('int f(dynamic a) => a;\n', [
        // strict-casts would refuse this; the compiler does not.
        'int f(dynamic a) => a + 1;\n',
        // Turned off in the options; the compiler still refuses it.
        "int f(dynamic a) => 'a';\n",
        // Dead code is an error in the options, and none for the compiler.
        'int f(dynamic a) { return a; return a; }\n',
      ]),
      [true, false, true],
    );
  });

  test('the options of a directory below decide nothing either', () async {
    package.write('lib/analysis_options.yaml', '''
analyzer:
  exclude:
    - "**"
''');
    expect(
      await compiles('int f(int a, int b) => a * b;\n', [
        'int f(int a, int b) => a + b;\n',
        'int f(int a, int b) => a / b;\n',
      ]),
      [true, false],
    );
  });

  test('one more error of a kind the file already has is an error of the '
      'mutant', () async {
    const source = '''
int f() => missing();
int g(int a) => a;
''';
    expect(
      await compiles(source, [
        source.replaceFirst('=> a;', '=> a + 1;'),
        source.replaceFirst('=> a;', '=> missing();'),
      ]),
      [true, false],
    );
  });

  test('the package configuration of a pub workspace is above the '
      'package', () async {
    package.write('packages/member/pubspec.yaml', 'name: member\n');
    const source = 'int f(int a) => a.abs();\n';
    package.write('packages/member/lib/a.dart', source);
    final member = '${package.path}/packages/member';
    expect(sdkPathOf(member), isNull);
    final analysis = PackageAnalysis.open(member);
    expect(await analysis.typedMutantsOf('lib/a.dart', source), hasLength(1));
    await analysis.dispose();
  });

  test('another file of the package, and a byte order mark', () async {
    package.write('lib/b.dart', 'int twice(int a) => a * 2;\n');
    const source =
        "﻿import 'package:fixture/b.dart';\n\n"
        'int f(int a) => twice(a).abs();\n';
    package.write('lib/a.dart', source);
    final analysis = PackageAnalysis.open(package.path);
    final mutants = await analysis.typedMutantsOf('lib/a.dart', source);
    expect(
      [
        for (final mutant in mutants)
          '${source.substring(mutant.offset, mutant.end)} → '
              '${mutant.replacement}',
      ],
      ['.abs() → '],
    );
    expect(await analysis.compileErrorOf('lib/a.dart', source), isNull);
    expect(
      await analysis.compileErrorOf(
        'lib/a.dart',
        source.replaceFirst('twice(a)', 'twice()'),
      ),
      isNotNull,
    );
    await analysis.dispose();
  });

  test('a file can be analyzed again after it was released', () async {
    const source = 'int f(int a) => a.abs();\n';
    package.write('lib/a.dart', source);
    final analysis = PackageAnalysis.open(package.path);
    for (var round = 0; round < 2; round++) {
      expect(await analysis.typedMutantsOf('lib/a.dart', source), hasLength(1));
      expect(
        await analysis.compileErrorOf('lib/a.dart', 'int f(int a) => a.b();\n'),
        isNotNull,
      );
      await analysis.release('lib/a.dart');
    }
    await analysis.dispose();
  });

  group('a package that cannot be analyzed', () {
    test('no package configuration', () {
      package.file(packageConfigPath).deleteSync();
      expect(
        () => PackageAnalysis.open(package.path),
        throwsA(
          isA<AnalysisUnavailable>().having(
            (error) => '$error',
            'message',
            contains('Run "dart pub get"'),
          ),
        ),
      );
    });

    test('a package configuration that is not JSON', () {
      package.write(packageConfigPath, '{');
      expect(
        () => PackageAnalysis.open(package.path),
        throwsA(isA<AnalysisUnavailable>()),
      );
    });

    test('a Flutter SDK that is not there', () {
      package.write(
        packageConfigPath,
        jsonEncode({
          'configVersion': 2,
          'packages': <Object>[],
          'flutterRoot': 'file:///no/such/flutter',
        }),
      );
      expect(
        () => sdkPathOf(package.path),
        throwsA(
          isA<AnalysisUnavailable>().having(
            (error) => error.message,
            'message',
            contains('Run "flutter pub get"'),
          ),
        ),
      );
    });

    test('without Flutter the SDK is the one this program runs on', () {
      expect(sdkPathOf(package.path), isNull);
    });
  });
}
