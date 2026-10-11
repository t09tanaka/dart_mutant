import 'package:dart_mutant/src/plan.dart';
import 'package:test/test.dart';

void main() {
  group('parsePlan', () {
    test('the files and their tests, in the order they are written', () {
      final targets = parsePlan('''
{
  "version": 1,
  "targets": [
    {"file": "lib/b.dart", "tests": ["test/b_test.dart", "test/x_test.dart"]},
    {"file": "lib/a.dart", "tests": []}
  ]
}''');
      expect(
        {for (final target in targets) target.file: target.tests},
        {
          'lib/b.dart': ['test/b_test.dart', 'test/x_test.dart'],
          'lib/a.dart': <String>[],
        },
      );
      expect(targets.first.file, 'lib/b.dart');
    });

    for (final (name, text, message) in [
      ('not JSON', '{', 'is not valid JSON'),
      ('an array', '[]', 'must be a JSON object'),
      ('another version', '{"version": 2, "targets": []}', '"version" must'),
      (
        'targets that are no list',
        '{"version": 1, "targets": {}}',
        '"targets"',
      ),
      ('no targets', '{"version": 1, "targets": []}', 'at least one entry'),
      (
        'a target that is no object',
        '{"version": 1, "targets": ["lib/a.dart"]}',
        'targets[0] must have "file"',
      ),
      (
        'tests that are no strings',
        '{"version": 1, "targets": [{"file": "lib/a.dart", "tests": [1]}]}',
        'targets[0] must have "file"',
      ),
      (
        'no tests',
        '{"version": 1, "targets": [{"file": "lib/a.dart"}]}',
        'targets[0] must have "file"',
      ),
      (
        'an absolute path',
        '{"version": 1, "targets": [{"file": "/lib/a.dart", "tests": []}]}',
        '"/lib/a.dart" must be a path inside the package',
      ),
      (
        'a test outside the package',
        '{"version": 1, "targets": [{"file": "lib/a.dart", '
            '"tests": ["../t_test.dart"]}]}',
        '"../t_test.dart" must be a path inside the package',
      ),
      (
        'a file that is not Dart',
        '{"version": 1, "targets": [{"file": "lib/a.txt", "tests": []}]}',
        'is not a .dart file',
      ),
      (
        'a file twice',
        '{"version": 1, "targets": [{"file": "lib/a.dart", "tests": []}, '
            '{"file": "lib/a.dart", "tests": []}]}',
        'targets[1]: "lib/a.dart" is listed twice',
      ),
      (
        'a test twice',
        '{"version": 1, "targets": [{"file": "lib/a.dart", '
            '"tests": ["a_test.dart", "a_test.dart"]}]}',
        'a test is listed twice',
      ),
    ]) {
      test('$name is refused', () {
        expect(
          () => parsePlan(text),
          throwsA(
            isA<PlanError>().having(
              (error) => '$error',
              'message',
              contains(message),
            ),
          ),
        );
      });
    }
  });

  test('isPlainRelativePath', () {
    for (final path in ['a.dart', 'lib/a.dart', 'lib/a b/c.dart']) {
      expect(isPlainRelativePath(path), isTrue, reason: path);
    }
    for (final path in [
      '',
      '/a.dart',
      './a.dart',
      'lib/../a.dart',
      'lib//a.dart',
      r'lib\a.dart',
      'C:/a.dart',
      'lib/',
    ]) {
      expect(isPlainRelativePath(path), isFalse, reason: path);
    }
  });

  test('normalizePath', () {
    expect(normalizePath('./lib/a.dart'), 'lib/a.dart');
    expect(normalizePath(r'.\lib\a.dart'), 'lib/a.dart');
    expect(normalizePath('././a.dart'), 'a.dart');
    expect(normalizePath('lib/a.dart'), 'lib/a.dart');
  });

  test('defaultTestCandidates: next to the file, and the mirror under '
      'test/', () {
    expect(defaultTestCandidates('lib/a/b.dart'), [
      'lib/a/b_test.dart',
      'test/a/b_test.dart',
    ]);
    // Outside lib/ there is no mirror.
    expect(defaultTestCandidates('bin/tool.dart'), ['bin/tool_test.dart']);
    expect(defaultTestCandidates('library/a.dart'), ['library/a_test.dart']);
  });

  test('isGlob', () {
    for (final argument in ['lib/*.dart', 'lib/**.dart', 'a?.dart', '{a,b}']) {
      expect(isGlob(argument), isTrue, reason: argument);
    }
    expect(isGlob('lib/a.dart'), isFalse);
  });

  test('selectTargets', () {
    const files = ['lib/a.dart', 'lib/b.dart', 'lib/c.dart'];
    expect(selectTargets(files, []).selected, files);
    final some = selectTargets(files, ['lib/c.dart', './lib/a.dart', 'x.dart']);
    expect(some.selected, ['lib/a.dart', 'lib/c.dart']);
    expect(some.unknown, ['x.dart']);
  });
}
