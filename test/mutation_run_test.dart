import 'dart:convert';

import 'package:dart_mutant/src/mutant.dart';
import 'package:dart_mutant/src/mutation_run.dart';
import 'package:test/test.dart';

const source = 'int a(int x) =>\n    x + 1;\n';
const plus = Mutant('ArithmeticOperator', 22, 23, '-');
const one = Mutant('NumberLiteral', 24, 25, '2');

FileRun runOf(List<MutantResult> results) =>
    FileRun(source: source, results: results);

void main() {
  test('the limits are those of test_gates 0.1.0', () {
    expect(perTestTimeoutSeconds, 10);
    expect(baselineLimit, const Duration(minutes: 10));
    expect(processLimit(Duration.zero), const Duration(seconds: 20));
    expect(
      processLimit(const Duration(seconds: 7)),
      const Duration(seconds: 41),
    );
  });

  test('usesFlutter: a dependency from the Flutter SDK', () {
    expect(
      usesFlutter('dependencies:\n  flutter:\n    sdk: flutter\n'),
      isTrue,
    );
    expect(
      usesFlutter(
        'dev_dependencies:\r\n  flutter_test:\r\n    sdk: flutter # x\r\n',
      ),
      isTrue,
    );
    expect(usesFlutter('environment:\n  sdk: ^3.11.0\n'), isFalse);
    expect(usesFlutter('description: sdk: flutter\n'), isFalse);
    expect(usesFlutter('environment:\n  flutter: ">=3.0.0"\n'), isFalse);
  });

  test('testCommandFor and mutantCommand', () {
    expect(testCommandFor(flutter: true), ['flutter', 'test', '--no-pub']);
    expect(testCommandFor(flutter: false), ['dart', 'test']);
    expect(testCommandFor(flutter: true, override: ['fvm', 'dart', 'test']), [
      'fvm',
      'dart',
      'test',
    ]);
    expect(
      mutantCommand(['dart', 'test'], ['test/a_test.dart', 'b_test.dart']),
      [
        'dart',
        'test',
        '--fail-fast',
        '--timeout',
        '10s',
        'test/a_test.dart',
        'b_test.dart',
      ],
    );
  });

  test('classifyRun', () {
    String of(int? exitCode, String output, {bool timedOut = false}) =>
        classifyRun(exitCode: exitCode, output: output, timedOut: timedOut);
    expect(of(0, 'All tests passed!'), 'Survived');
    expect(of(1, 'Some tests failed.'), 'Killed');
    expect(of(null, '', timedOut: true), 'Timeout');
    expect(of(1, "lib/a.dart:3:7: Error: A value of type 'x'"), 'CompileError');
    expect(
      of(1, 'Compilation failed for testPath=/x/a_test.dart'),
      'CompileError',
    );
    // The word alone is not the compiler's.
    expect(of(1, 'StateError: bad'), 'Killed');
    expect(of(255, ''), 'Killed');
  });

  test('positionOf counts lines and columns from 1', () {
    expect(positionOf(source, 0), (line: 1, column: 1));
    expect(positionOf(source, 21), (line: 2, column: 6));
    expect(positionOf('a\r\nb', 3), (line: 2, column: 1));
    expect(positionOf(source, source.length), (line: 3, column: 1));
  });

  test('numbered: the syntax mutants keep their numbers whatever the typed '
      'ones are', () {
    expect(numbered(source, [plus], [one]), [plus, one]);
    expect(numbered(source, [plus], []), [plus]);
  });

  test('numbered: a typed mutant that makes the same program as a mutant '
      'before it is left out', () {
    // `x + 1` → `x - 1`, written by three mutators.
    const same = Mutant('Other', 20, 25, 'x - 1');
    const again = Mutant('Another', 22, 25, '- 1');
    expect(numbered(source, [plus], [same, one, again]), [plus, one]);
    expect(numbered(source, [], [same, again]), [same]);
    // The syntax mutants are never left out.
    expect(numbered(source, [plus, plus], []), [plus, plus]);
  });

  test('isReport', () {
    expect(isReport('{"files": {}}'), isTrue);
    expect(isReport(jsonEncode(buildReport(const {}))), isTrue);
    expect(isReport('{"files": []}'), isFalse);
    expect(isReport('{}'), isFalse);
    expect(isReport('[]'), isFalse);
    expect(isReport('int a() => 1;'), isFalse);
  });

  group('buildReport', () {
    test('a file with its mutants, in the mutation-testing-elements '
        'schema', () {
      final report = buildReport({
        'lib/a.dart': runOf([
          const MutantResult(plus, killed, milliseconds: 1200),
          const MutantResult(one, compileError, reason: 'no'),
        ]),
      });
      expect(report, {
        'schemaVersion': '2',
        'thresholds': {'high': 100, 'low': 100},
        'framework': {'name': 'dart_mutant', 'version': '0.1.0'},
        'files': {
          'lib/a.dart': {
            'language': 'dart',
            'source': source,
            'mutants': [
              {
                'id': 'lib/a.dart#0',
                'mutatorName': 'ArithmeticOperator',
                'replacement': '-',
                'status': 'Killed',
                'duration': 1200,
                'location': {
                  'start': {'line': 2, 'column': 7},
                  'end': {'line': 2, 'column': 8},
                },
              },
              {
                'id': 'lib/a.dart#1',
                'mutatorName': 'NumberLiteral',
                'replacement': '2',
                'status': 'CompileError',
                'statusReason': 'no',
                'duration': 0,
                'location': {
                  'start': {'line': 2, 'column': 9},
                  'end': {'line': 2, 'column': 10},
                },
              },
            ],
          },
        },
      });
    });

    test('the files of an earlier report come first, as they were', () {
      final report = buildReport(
        {'lib/a.dart': runOf(const [])},
        others: {
          'lib/z.dart': {'anything': 1},
        },
      );
      expect((report['files']! as Map).keys, ['lib/z.dart', 'lib/a.dart']);
      expect((report['files']! as Map)['lib/z.dart'], {'anything': 1});
    });
  });

  test('otherReportFiles: what is not of this run, whatever the spelling '
      'of the path', () {
    final existing = jsonEncode({
      'files': {
        './lib/a.dart': {'a': 1},
        'lib/b.dart': {'b': 1},
        r'lib\c.dart': {'c': 1},
      },
    });
    expect(otherReportFiles(existing, ['lib/a.dart', 'lib/c.dart']), {
      'lib/b.dart': {'b': 1},
    });
    expect(otherReportFiles(null, ['lib/a.dart']), isEmpty);
    expect(otherReportFiles('{', ['lib/a.dart']), isEmpty);
    expect(otherReportFiles('[]', ['lib/a.dart']), isEmpty);
    expect(otherReportFiles('{"files": 1}', ['lib/a.dart']), isEmpty);
  });

  test('carriedResults: --force forgets the files of the run and nothing '
      'else', () {
    const saved = {'lib/a.dart': 1, 'lib/b.dart': 2};
    expect(carriedResults(saved, force: false, targets: ['lib/a.dart']), saved);
    expect(carriedResults(saved, force: true, targets: ['lib/a.dart']), {
      'lib/b.dart': 2,
    });
  });

  group('results of the last run', () {
    const input = FileInput(
      source: source,
      tests: {'test/a_test.dart': 'test'},
      command: ['dart', 'test'],
    );
    final entry = incrementalEntry(input, const [
      MutantResult(plus, killed, milliseconds: 5),
      MutantResult(one, compileError, reason: 'why'),
    ]);

    List<String>? reused(Object? entry, FileInput input) => reusableResults(
      entry,
      input,
    )?.map((r) => '${r.mutant.mutator} ${r.status} ${r.reason}').toList();

    test('the same input: the mutants, their statuses and reasons', () {
      final decoded = jsonDecode(jsonEncode(entry));
      expect(reused(decoded, input), [
        'ArithmeticOperator Killed null',
        'NumberLiteral CompileError why',
      ]);
      final first = reusableResults(decoded, input)!.first.mutant;
      expect(
        (first.offset, first.end, first.replacement),
        (plus.offset, plus.end, plus.replacement),
      );
    });

    test('what is kept of the input, key by key', () {
      expect(input.toJson(), {
        'toolVersion': '0.1.0',
        'mutatorsVersion': 2,
        'command': ['dart', 'test'],
        'source': source,
        'tests': {'test/a_test.dart': 'test'},
      });
    });

    test('a mutant at the start of the file, at its end, and one that only '
        'puts text in, are reused', () {
      Object? entryOf(int offset, int end) => {
        'input': input.toJson(),
        'mutants': [
          {
            'mutator': 'A',
            'offset': offset,
            'end': end,
            'replacement': 'x',
            'status': 'Killed',
          },
        ],
      };
      for (final (offset, end) in [
        (0, 1),
        (0, 0),
        (1, 1),
        (source.length - 1, source.length),
        (source.length, source.length),
      ]) {
        expect(reused(entryOf(offset, end), input), [
          'A Killed null',
        ], reason: '$offset to $end');
      }
    });

    test('a timeout is measured again', () {
      final withTimeout = incrementalEntry(input, const [
        MutantResult(plus, timeout),
      ]);
      expect(reused(withTimeout, input), ['ArithmeticOperator null null']);
    });

    test('anything else that changed: nothing is reused', () {
      for (final other in [
        const FileInput(
          source: '$source ',
          tests: {'test/a_test.dart': 'test'},
          command: ['dart', 'test'],
        ),
        const FileInput(
          source: source,
          tests: {'test/a_test.dart': 'test2'},
          command: ['dart', 'test'],
        ),
        const FileInput(
          source: source,
          tests: {'lib/a_test.dart': 'test'},
          command: ['dart', 'test'],
        ),
        const FileInput(
          source: source,
          tests: {'test/a_test.dart': 'test', 'lib/a_test.dart': ''},
          command: ['dart', 'test'],
        ),
        const FileInput(
          source: source,
          tests: {'test/a_test.dart': 'test'},
          command: ['flutter', 'test'],
        ),
      ]) {
        expect(reused(entry, other), isNull);
      }
      for (final version in ['toolVersion', 'mutatorsVersion']) {
        final changed = jsonDecode(jsonEncode(entry)) as Map<String, Object?>;
        (changed['input']! as Map<String, Object?>)[version] = 'other';
        expect(reused(changed, input), isNull, reason: version);
      }
    });

    test('an entry that is not one: nothing is reused', () {
      Map<String, Object?> broken(Object? mutant) => {
        'input': input.toJson(),
        'mutants': [mutant],
      };
      for (final entry in <Object?>[
        null,
        1,
        {'input': input.toJson()},
        {'input': input.toJson(), 'mutants': 1},
        broken(1),
        broken({'mutator': 'A', 'offset': 0, 'end': 1, 'replacement': ''}),
        broken({
          'mutator': 'A',
          'offset': 0,
          'end': 1,
          'replacement': '',
          'status': 'Killed',
          'reason': 1,
        }),
        // A place outside the source.
        broken({
          'mutator': 'A',
          'offset': 5,
          'end': 4,
          'replacement': '',
          'status': 'Killed',
        }),
        broken({
          'mutator': 'A',
          'offset': 0,
          'end': source.length + 1,
          'replacement': '',
          'status': 'Killed',
        }),
        broken({
          'mutator': 'A',
          'offset': -1,
          'end': 1,
          'replacement': '',
          'status': 'Killed',
        }),
      ]) {
        expect(reused(entry, input), isNull, reason: '$entry');
      }
    });
  });

  group('what a run prints', () {
    final run = runOf(const [
      MutantResult(plus, survived, milliseconds: 900),
      MutantResult(one, killed, milliseconds: 800),
      MutantResult(one, compileError, reason: 'why'),
      MutantResult(one, compileError),
      MutantResult(one, timeout),
    ]);

    test('fileLine', () {
      expect(
        fileLine('lib/a.dart', run, reused: 0, milliseconds: 1740),
        '  lib/a.dart: 5 mutants / killed 1 / survived 1 / timeout 1 / '
        'compile error 2 (1 found before the run) (1.7s)',
      );
      expect(
        fileLine('lib/a.dart', runOf(const []), reused: 3, milliseconds: 0),
        '  lib/a.dart: 0 mutants / killed 0 / survived 0 / timeout 0 / '
        'compile error 0 (3 from the last run, 0.0s)',
      );
    });

    test('found before the run: only the compile errors with a reason', () {
      final refused = runOf(const [
        MutantResult(one, compileError, reason: 'a'),
        MutantResult(one, compileError, reason: 'b'),
        MutantResult(one, compileError),
        MutantResult(one, killed, reason: 'not a compile error'),
      ]);
      expect(refused.refusedBeforeRun, 2);
      expect(
        totalCounts([refused]),
        '4 mutants / killed 1 / survived 0 / timeout 0 / compile error 3 '
        '(2 found before the run)',
      );
    });

    test('the seconds of a file, to a tenth', () {
      String seconds(int milliseconds) => fileLine(
        'a',
        runOf(const []),
        reused: 0,
        milliseconds: milliseconds,
      ).split('(').last;
      expect(seconds(100100), '100.1s)');
      expect(seconds(1960), '2.0s)');
      expect(seconds(949), '0.9s)');
    });

    test('survivorLines: blanks around the texts are not shown', () {
      const padded = Mutant('BlockStatement', 15, 26, '\n  {}\n');
      expect(
        survivorLines({
          'lib/b.dart': runOf(const [MutantResult(padded, survived)]),
        }),
        ['  lib/b.dart:1:16 BlockStatement: x + 1; → {}'],
      );
    });

    test('totalCounts adds the files up', () {
      expect(
        totalCounts([run, run]),
        '10 mutants / killed 2 / survived 2 / timeout 2 / compile error 4 '
        '(2 found before the run)',
      );
      expect(
        totalCounts(const []),
        '0 mutants / killed 0 / survived 0 / timeout 0 / compile error 0',
      );
    });

    test('survivorLines: the place, the mutator and the change, on one '
        'line', () {
      expect(survivorLines({'lib/a.dart': run}), [
        '  lib/a.dart:2:7 ArithmeticOperator: + → -',
      ]);
      const block = Mutant('GuardThrows', 13, 26, '{\n  throw 1;\n}');
      expect(
        survivorLines({
          'lib/b.dart': runOf(const [MutantResult(block, survived)]),
        }),
        ['  lib/b.dart:1:14 GuardThrows: => x + 1; → { throw 1; }'],
      );
      expect(survivorLines({'lib/a.dart': runOf(const [])}), isEmpty);
    });
  });

  test('Mutant.applyTo and inSourceOrder', () {
    expect(plus.applyTo(source), 'int a(int x) =>\n    x - 1;\n');
    const first = Mutant('A', 1, 2, 'a');
    const second = Mutant('B', 1, 2, 'b');
    expect(inSourceOrder([one, second, plus, first]), [
      second,
      first,
      plus,
      one,
    ]);
  });
}
