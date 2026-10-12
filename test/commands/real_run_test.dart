@Tags(['process'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mutant/dart_mutant.dart';
import 'package:test/test.dart';

/// `dart_mutant run` against the real thing: the package in example/,
/// copied into a temporary directory, with `dart test` as the test runner.
void main() {
  late Directory dir;
  final out = <String>[];
  final err = <String>[];

  const sources = [
    'pubspec.yaml',
    'plan.json',
    'lib/discount.dart',
    'test/discount_test.dart',
  ];

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('dart_mutant_real_');
    for (final source in sources) {
      File('${dir.path}/$source')
        ..createSync(recursive: true)
        ..writeAsBytesSync(File('example/$source').readAsBytesSync());
    }
    // The packages are in the cache: this package depends on `test` too.
    final pubGet = Process.runSync(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: dir.path);
    expect(pubGet.exitCode, 0, reason: '${pubGet.stdout}${pubGet.stderr}');
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  for (final oneByOne in [false, true]) {
    test('every mutant of the example, '
        '${oneByOne ? 'each with a start of the test runner of its own' : 'in one start of the test runner'}: '
        'what the analyzer refuses is not run, what is run is killed or '
        'survives, and none of it fails to compile in the test run', () async {
      out.clear();
      err.clear();
      final before = [
        for (final source in sources)
          File('${dir.path}/$source').readAsBytesSync(),
      ];
      final code = await run([
        'run',
        '--force',
        if (oneByOne) '--one-by-one',
        '--jobs',
        '1',
        '--dir',
        dir.path,
        '--plan',
        '${dir.path}/plan.json',
        '--',
        Platform.resolvedExecutable,
        'test',
      ], Io(out: out.add, err: err.add));

      final report =
          jsonDecode(
                File(
                  '${dir.path}/reports/mutation/mutation.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final file =
          (report['files']! as Map<String, Object?>)['lib/discount.dart']!
              as Map<String, Object?>;
      final lines = (file['source']! as String).split('\n');
      String shown(Map<String, Object?> mutant) {
        final location = mutant['location']! as Map<String, Object?>;
        final start = location['start']! as Map<String, Object?>;
        final end = location['end']! as Map<String, Object?>;
        final original = start['line'] == end['line']
            ? lines[(start['line']! as int) - 1].substring(
                (start['column']! as int) - 1,
                (end['column']! as int) - 1,
              )
            : '…';
        final replacement = (mutant['replacement']! as String).replaceAll(
          RegExp(r'\s+'),
          ' ',
        );
        return '${mutant['mutatorName']} $original → $replacement: '
            '${mutant['status']}'
            '${mutant.containsKey('statusReason') ? ' (analyzer)' : ''}';
      }

      expect(
        [
          for (final mutant in (file['mutants']! as List))
            shown(mutant as Map<String, Object?>),
        ],
        [
          // The syntax mutants, as test_gates 0.1.0 numbers them. The code
          // after the guard relies on it: four of them are not programs.
          'BlockStatement … → {}: Killed',
          'ConditionalExpression cents == null → (cents == null) || true: '
              'CompileError (analyzer)',
          'ConditionalExpression cents == null → (cents == null) && false: '
              'CompileError (analyzer)',
          'EqualityOperator == → !=: CompileError (analyzer)',
          'BlockStatement … → {}: CompileError (analyzer)',
          'ArithmeticOperator * → /: Killed',
          'ArithmeticOperator - → +: Killed',
          'ArithmeticOperator / → *: Killed',
          // The typed mutants: the guard in forms that compile.
          'GuardAlwaysTaken … → { return null; } else if (1 == 1) '
              '{ return null; }: Killed',
          "GuardThrows … → { throw StateError('mutant'); }: Killed",
          'ReturnValue null → 0: Killed',
          'MethodExpression .clamp(0, 100) → : Killed',
          // No test has a percentage below zero.
          'NumberLiteral 0 → 1: Survived',
          'NumberLiteral 100 → 101: Killed',
          'NumberLiteral 100 → 99: Killed',
          'ReturnValue (cents * (100 - rate) / 100).round() → null: Killed',
          'NumberLiteral 100 → 101: Killed',
          'NumberLiteral 100 → 99: Killed',
          'NumberLiteral 100 → 101: Killed',
          'NumberLiteral 100 → 99: Killed',
          'MethodExpression round → floor: Killed',
          // No test has a price that rounds down.
          'MethodExpression round → ceil: Survived',
        ],
      );
      expect(code, 1);
      // With one start for the mutants, also what it killed and what is left.
      expect(out, hasLength(oneByOne ? 2 : 4));
      expect(err, [
        'dart_mutant run: 2 surviving mutant(s)',
        '  - lib/discount.dart:7:30 / NumberLiteral / 0 → 1 (Survived)',
        '  - lib/discount.dart:8:39 / MethodExpression / round → ceil (Survived)',
        'dart_mutant run: FAILED (22 mutants / killed 16 / survived 2 / timeout 0 '
            '/ compile error 4 (4 found before the run))',
      ]);
      expect([
        for (final source in sources)
          File('${dir.path}/$source').readAsBytesSync(),
      ], before);
    });
  }
}
