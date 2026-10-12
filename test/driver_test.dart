import 'dart:convert';

import 'package:dart_mutant/src/driver.dart';
import 'package:test/test.dart';

const plan = [-1, 4, 5, -1, 6, -1];

/// What the driver of one test file wrote down when its one test passed,
/// or failed, and the exit code that goes with it.
Ran ran({bool failed = false}) => Ran(
  exitCodes: [failed ? 255 : 0],
  notes: ['load 0', 'declared 0', '${failed ? 'fail' : 'pass'} 0 0'],
);

/// A log of [plan] as far as [last], in which the test fails in the
/// positions [failing].
DriverLog logOf(
  int last, {
  Set<int> failing = const {},
  List<int> plan = plan,
}) {
  final log = DriverLog(plan, tests: 1);
  for (var position = 0; position <= last; position++) {
    log.add(
      ran(failed: failing.contains(position)),
      milliseconds: 100 + position,
    );
  }
  return log;
}

void main() {
  test('packageNameOf', () {
    expect(packageNameOf('name: a_b1\nversion: 1.0.0\n'), 'a_b1');
    expect(packageNameOf('# a pubspec\r\nname:   "quoted"\r\n'), 'quoted');
    expect(packageNameOf("version: 1.0.0\nname: 'single'"), 'single');
    expect(packageNameOf('dependencies:\n  name: other\n'), isNull);
    expect(packageNameOf('named: a\n'), isNull);
    expect(packageNameOf('name: 1a\n'), isNull);
    expect(packageNameOf(''), isNull);
    // The first one counts.
    expect(packageNameOf('name: a\nname: b\n'), 'a');
  });

  group('importOf', () {
    test('a file below lib/ of a package with a name: by that name', () {
      expect(
        importOf('lib/src/a.dart', directory: 'test', package: 'p'),
        'package:p/src/a.dart',
      );
    });

    test('a file elsewhere, and a package without a name: by its place', () {
      expect(
        importOf('bin/a.dart', directory: 'test', package: 'p'),
        '../bin/a.dart',
      );
      expect(importOf('lib/a.dart', directory: 'test'), '../lib/a.dart');
      expect(
        importOf('liberal/a.dart', directory: '', package: 'p'),
        'liberal/a.dart',
      );
    });

    test('from the same directory, from above, from below, from beside', () {
      expect(importOf('test/a_test.dart', directory: 'test'), 'a_test.dart');
      expect(
        importOf('test/x/a_test.dart', directory: 'test'),
        'x/a_test.dart',
      );
      expect(
        importOf('test/a_test.dart', directory: 'test/x/y'),
        '../../a_test.dart',
      );
      expect(
        importOf('test/z/a_test.dart', directory: 'test/x'),
        '../z/a_test.dart',
      );
      expect(importOf('a_test.dart', directory: ''), 'a_test.dart');
      expect(importOf('a_test.dart', directory: 'x'), '../a_test.dart');
    });

    test('a directory with the name of the file is no shared directory', () {
      expect(importOf('test/x', directory: 'test/x'), '../x');
    });
  });

  test('directoryOf', () {
    expect(directoryOf('a.dart'), '');
    expect(directoryOf('test/a.dart'), 'test');
    expect(directoryOf('test/x/a.dart'), 'test/x');
  });

  test('dartString', () {
    expect(dartString('a'), "'a'");
    expect(dartString(r'a\b'), r"'a\\b'");
    expect(dartString("it's"), r"'it\'s'");
    expect(dartString(r'$a'), r"'\$a'");
    expect(dartString('a\nb\rc'), r"'a\nb\rc'");
    expect(dartString(r"\'$"), r"'\\\'\$'");
  });

  group('driverObstacle', () {
    test('a test file like most has none', () {
      expect(driverObstacle("import 'a.dart';\nvoid main() {}\n"), isNull);
      expect(
        driverObstacle('main() { test(); }\nvoid other(int a) {}'),
        isNull,
      );
    });

    test('an annotation on the library, whichever directive carries it', () {
      expect(
        driverObstacle(
          '@Timeout(Duration(minutes: 1))\nlibrary;\nvoid main() {}',
        ),
        'has an annotation on its library (@Timeout(Duration(minutes: 1)))',
      );
      expect(
        driverObstacle(
          "import 'a.dart';\n@TestOn('vm') @Skip()\nimport 'b.dart';\nvoid main() {}",
        ),
        "has an annotation on its library (@TestOn('vm'))",
      );
    });

    test('the first annotation of the first directive that has one is '
        'named', () {
      expect(
        driverObstacle(
          '@Tags(["a"]) @Skip()\nlibrary;\n@Timeout.none\n'
          "import 'a.dart';\nvoid main() {}",
        ),
        'has an annotation on its library (@Tags(["a"]))',
      );
    });

    test('a test file that cannot be parsed is judged by what is there', () {
      expect(driverObstacle('void main() { test(; }'), isNull);
      expect(driverObstacle('void other( {'), 'has no main()');
    });

    test('an annotation on a declaration is none on the library', () {
      expect(driverObstacle('@pragma("x")\nvoid main() {}'), isNull);
    });

    test('no main, or something else with that name', () {
      expect(driverObstacle('void other() {}'), 'has no main()');
      expect(driverObstacle('int main = 1;'), 'has no main()');
      expect(driverObstacle('class A { void main() {} }'), 'has no main()');
    });

    test('a main that takes arguments, or is no function to call', () {
      expect(
        driverObstacle('void main(List<String> a) {}'),
        'has a main() that takes arguments',
      );
      expect(
        driverObstacle('void main([List<String>? a]) {}'),
        'has a main() that takes arguments',
      );
      expect(
        driverObstacle('int get main => 1;'),
        'has a main() that takes arguments',
      );
    });

    test('a main that is async, or a generator', () {
      expect(
        driverObstacle('Future<void> main() async {}'),
        'has a main() that is async',
      );
      expect(
        driverObstacle('main() async => 1;'),
        'has a main() that is async',
      );
      expect(
        driverObstacle('Iterable<int> main() sync* {}'),
        'has a main() that is async',
      );
    });
  });

  test('driverNameOf: no test file, so that the test runner does not pick '
      'it up', () {
    expect(driverNameOf(0), 'dart_mutant_driver_0.dart');
    expect(driverNameOf(12), 'dart_mutant_driver_12.dart');
    expect(driverPrefix, 'dart_mutant_driver_');
  });

  group('testsObstacle', () {
    const fine = 'void main() {}';

    test('tests in one directory that a driver can call', () {
      expect(
        testsObstacle({
          'test/a_test.dart': fine,
          'test/b_test.dart': fine,
        }, taken: false),
        isNull,
      );
      expect(testsObstacle({'a_test.dart': fine}, taken: false), isNull);
    });

    test('tests in two directories', () {
      expect(
        testsObstacle({
          'test/a_test.dart': fine,
          'test/x/b_test.dart': fine,
        }, taken: false),
        'has tests in more than one directory',
      );
    });

    test('a file with a name that a driver could have', () {
      expect(
        testsObstacle({'test/a_test.dart': fine}, taken: true),
        'has a file whose name starts with dart_mutant_driver_ next to its '
        'tests',
      );
    });

    test('a test a driver cannot call: the first one is named', () {
      expect(
        testsObstacle({
          'test/a_test.dart': fine,
          'test/b_test.dart': 'void other() {}',
          'test/c_test.dart': 'main() async {}',
        }, taken: false),
        'has a test (test/b_test.dart) that has no main()',
      );
    });
  });

  group('configObstacle', () {
    test('no dart_test.yaml, an empty one, and one that only names tags', () {
      expect(configObstacle(null), isNull);
      expect(configObstacle(''), isNull);
      expect(configObstacle('# Nothing.\n\n'), isNull);
      expect(
        configObstacle(
          'tags:\n'
          '  # The slow ones.\n'
          '  process:\n'
          '  slow-ones: # and these\n'
          '\n'
          'tags: # again\n',
        ),
        isNull,
      );
    });

    test('anything else is for the test runner alone', () {
      const obstacle =
          'has a dart_test.yaml that says more than the names of tags, which '
          'only the test runner reads';
      for (final config in [
        'timeout: 2x\n',
        'retry: 2\n',
        'tags:\n  slow:\n    timeout: 2x\n',
        'tags:\n  slow: {timeout: 2x}\n',
        'tags: {slow: {skip: true}}\n',
        'platforms: [chrome]\n',
        'concurrency: 1',
        'tags:\n  slow:\nretry: 1\n',
        'tags\n',
        '  process\n',
        'x tags:\n',
        'tags:\n  1slow:\n',
        'tags:\n  slow one:\n',
      ]) {
        expect(configObstacle(config), obstacle, reason: config);
      }
    });
  });

  test('driverPathOf', () {
    expect(
      driverPathOf(['test/x/a_test.dart', 'test/x/b_test.dart'], 1),
      'test/x/dart_mutant_driver_1.dart',
    );
    expect(driverPathOf(['a_test.dart'], 0), 'dart_mutant_driver_0.dart');
    // The first one decides; the caller has seen to it that they agree.
    expect(
      driverPathOf(['a/x_test.dart', 'b/y_test.dart', 'z_test.dart'], 2),
      'a/dart_mutant_driver_2.dart',
    );
  });

  test('dartOf: what starts Dart programs, from the command that runs test '
      'files', () {
    expect(dartOf(['dart', 'test']), ['dart']);
    expect(dartOf(['/sdk/bin/dart', 'test']), ['/sdk/bin/dart']);
    expect(dartOf(['fvm', 'dart', 'test']), ['fvm', 'dart']);
    // Not of that form: the tests cannot be run as a program of their own.
    expect(dartOf(['flutter', 'test', '--no-pub']), isNull);
    expect(dartOf(['dart', 'test', '-p', 'chrome']), isNull);
    expect(dartOf(['dart', 'run', 'test:test']), isNull);
    expect(dartOf(['test']), isNull);
    expect(dartOf([]), isNull);
  });

  test('compileCommand and driverCommand', () {
    expect(compileCommand(['fvm', 'dart'], 'test/d_0.dart', '/s/d_0'), [
      'fvm',
      'dart',
      'compile',
      'exe',
      '--enable-asserts',
      'test/d_0.dart',
      '-o',
      '/s/d_0',
    ]);
    expect(driverCommand('/s/d_0', 12), ['/s/d_0', '12']);
    expect(driverCommand('d', -1), ['d', '-1']);
  });

  group('testLibraryOf', () {
    String config(List<String> names) => jsonEncode({
      'packages': [
        for (final name in names) {'name': name},
        'not an object',
      ],
    });

    test('test, with test_api to ask how a test went', () {
      expect(
        testLibraryOf(config(['flutter_test', 'test_api', 'test'])),
        'package:test/test.dart',
      );
    });

    test('one of them is missing, or there is no package configuration to '
        'speak of', () {
      expect(testLibraryOf(config(['flutter_test', 'test_api'])), isNull);
      expect(testLibraryOf(config(['tests', 'test_api'])), isNull);
      expect(testLibraryOf(config(['test'])), isNull);
      expect(testLibraryOf(null), isNull);
      expect(testLibraryOf('{'), isNull);
      expect(testLibraryOf('[]'), isNull);
      expect(
        testLibraryOf('{"packages": {"name": "test", "other": "test_api"}}'),
        isNull,
      );
    });
  });

  test('driverSource: the mutant is at work before the tests are declared, '
      'the driver writes down itself how each test went, and a test is not '
      'run after another failed for good', () {
    expect(
      driverSource(
        testLibrary: 'package:test/test.dart',
        target: 'package:p/a.dart',
        test: "it's/b_test.dart",
        index: 1,
        state: r'/tmp/$state',
      ),
      r'''
// Written by dart_mutant for one run, and removed with it.
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_api/src/backend/invoker.dart';

import 'package:p/a.dart' as target;
import 'it\'s/b_test.dart' as tests;

const _state = '/tmp/\$state';

void _note(String what, [int? test]) => File('$_state/log').writeAsStringSync(
  '$what 1${test == null ? '' : ' $test'}\n',
  mode: FileMode.append,
);

void main(List<String> arguments) {
  final id = int.parse(arguments.single);
  target.$dartMutantActive = id;
  _note('load');
  final numbers = Expando<int>();
  var count = 0;
  Object? failed;
  Object? skipped;
  tearDownAll(() {
    if (failed == null) {
      Timer(const Duration(milliseconds: 200), () => exit(0));
    }
  });
  setUp(() {
    final test = Invoker.current!.liveTest;
    numbers[test] ??= count++;
    if (id != -1 && failed != null && !identical(failed, test)) {
      skipped = test;
      _note('skip', numbers[test]);
      throw StateError('dart_mutant: not run, a test before it failed');
    }
  });
  tearDown(() {
    final test = Invoker.current!.liveTest;
    if (identical(skipped, test)) {
      return;
    }
    if (test.state.result.isPassing) {
      _note('pass', numbers[test]);
      if (identical(failed, test)) {
        failed = null;
      }
    } else {
      _note('fail', numbers[test]);
      failed = test;
    }
  });
  tests.main();
  _note('declared');
}
''',
    );
  });

  test('planOf: the tests without a mutant first, after every 25 mutants, '
      'and at the end', () {
    expect(planOf([7]), [-1, 7, -1]);
    expect(planOf([7, 3]), [-1, 7, 3, -1]);
    final ids = [for (var id = 100; id < 151; id++) id];
    final plan = planOf(ids);
    expect(plan.where((id) => id != -1), ids);
    expect(
      [
        for (final (position, id) in plan.indexed)
          if (id == -1) position,
      ],
      [0, 26, 52, 54],
    );
    expect(planOf(ids.sublist(0, 50)).length, 53);
    expect(planOf(ids.sublist(0, 50)).last, -1);
    expect(planOf(ids.sublist(0, 49)).length, 52);
  });

  group('outcomeOf', () {
    ({Outcome outcome, int tests}) of(
      List<int> exitCodes,
      List<String> notes, {
      int tests = 1,
      bool ended = false,
    }) => outcomeOf(
      Ran(exitCodes: exitCodes, notes: notes, ended: ended),
      tests: tests,
    );

    test('every test passed: every test file had its process, it ended '
        'with 0, declared its tests, and no test failed or was left out', () {
      expect(of([0], ['load 0', 'declared 0', 'pass 0 0', 'pass 0 1']), (
        outcome: Outcome.passed,
        tests: 2,
      ));
      expect(
        of(
          [0, 0],
          [
            'load 0',
            'declared 0',
            'pass 0 0',
            'load 1',
            'declared 1',
            'pass 1 0',
          ],
          tests: 2,
        ),
        (outcome: Outcome.passed, tests: 2),
      );
      // Without a test as well: that is for whoever counts them.
      expect(of([0], ['load 0', 'declared 0']), (
        outcome: Outcome.passed,
        tests: 0,
      ));
    });

    test('a test failed: its driver wrote that down after declaring its '
        'tests, and its process ended with another exit code than 0', () {
      expect(
        of([255], ['load 0', 'declared 0', 'pass 0 0', 'fail 0 1', 'skip 0 2']),
        (outcome: Outcome.failed, tests: 3),
      );
      expect(of([1], ['declared 0', 'fail 0 0']).outcome, Outcome.failed);
      // In the second test file, when the first passed.
      expect(
        of(
          [0, 255],
          ['declared 0', 'pass 0 0', 'declared 1', 'fail 1 0'],
          tests: 2,
        ).outcome,
        Outcome.failed,
      );
      // The other test files are not run after it.
      expect(
        of([255], ['declared 0', 'fail 0 0'], tests: 2).outcome,
        Outcome.failed,
      );
    });

    test('a failure that only one side has is none', () {
      // The process failed, and no test of it did: a setUpAll, an error
      // that arrives when its test has ended, a test that ends the process.
      expect(
        of([255], ['load 0', 'declared 0', 'pass 0 0']).outcome,
        Outcome.undecided,
      );
      expect(of([255], const []).outcome, Outcome.undecided);
      // A test failed, and the process says that all is well.
      expect(of([0], ['declared 0', 'fail 0 0']).outcome, Outcome.undecided);
      // It failed in a test file whose process passed; another one failed.
      expect(
        of(
          [0, 255],
          ['declared 0', 'fail 0 0', 'declared 1', 'pass 1 0'],
          tests: 2,
        ).outcome,
        Outcome.undecided,
      );
      // Every test passed, and one of the processes says otherwise.
      expect(
        of(
          [0, 255],
          ['declared 0', 'pass 0 0', 'declared 1', 'pass 1 0'],
          tests: 2,
        ).outcome,
        Outcome.undecided,
      );
      // It failed in a test file whose process did not end by itself.
      expect(
        of(
          [0],
          ['declared 0', 'pass 0 0', 'declared 1', 'fail 1 0'],
          tests: 2,
        ).outcome,
        Outcome.undecided,
      );
    });

    test('a test file that could not declare its tests decides nothing, '
        'also when a test of it is said to have failed', () {
      expect(of([255], ['load 0']).outcome, Outcome.undecided);
      expect(of([255], ['load 0', 'fail 0 0']).outcome, Outcome.undecided);
      expect(of([0], ['load 0', 'pass 0 0']).outcome, Outcome.undecided);
      // One of two.
      expect(
        of([0, 0], ['declared 0', 'pass 0 0', 'load 1'], tests: 2).outcome,
        Outcome.undecided,
      );
    });

    test('not every test file had its process, or a test was left out', () {
      expect(
        of([0], ['declared 0', 'pass 0 0'], tests: 2).outcome,
        Outcome.undecided,
      );
      expect(
        of([0], ['declared 0', 'pass 0 0', 'skip 0 1']).outcome,
        Outcome.undecided,
      );
      expect(
        of(
          [0, 0, 0],
          ['declared 0', 'declared 1', 'declared 2'],
          tests: 2,
        ).outcome,
        Outcome.undecided,
      );
    });

    test('the last run of a test is how it went: one that failed and '
        'passed when it was tried again passed', () {
      expect(of([0], ['declared 0', 'fail 0 0', 'pass 0 0', 'pass 0 1']), (
        outcome: Outcome.passed,
        tests: 2,
      ));
      expect(
        of([255], ['declared 0', 'pass 0 0', 'fail 0 0']).outcome,
        Outcome.failed,
      );
      expect(
        of([255], ['declared 0', 'fail 0 0', 'pass 0 0']).outcome,
        Outcome.undecided,
      );
    });

    test('a limit ended a process: nothing is decided, whatever was '
        'written down', () {
      expect(
        of(const [], ['declared 0', 'fail 0 0'], ended: true).outcome,
        Outcome.undecided,
      );
      expect(
        of([0], ['declared 0', 'pass 0 0'], ended: true).outcome,
        Outcome.undecided,
      );
      expect(
        of([255], ['declared 0', 'fail 0 0'], ended: true).outcome,
        Outcome.undecided,
      );
    });

    test('what is no line of a driver is passed over', () {
      expect(
        of(
          [0],
          [
            '',
            'declared',
            'declared x',
            'declared 0 0',
            'pass 0',
            'pass 0 x',
            'pass x 0',
            'pass 0 0 0',
            'passed 0 0',
            'fail',
            'load 0 0',
            '00:00 +1: All tests passed!',
          ],
        ),
        (outcome: Outcome.undecided, tests: 0),
      );
      expect(const Ran(exitCodes: [], notes: []).ended, isFalse);
    });
  });

  group('DriverLog', () {
    test('a plan that ran: killed is what a test failed on before the '
        'tests passed without a mutant, with how long it took', () {
      final log = logOf(5, failing: {1, 4});
      expect(log.next, isNull);
      expect(log.failure, isNull);
      final result = log.result;
      expect(result.killed, {4: 101, 6: 104});
      expect(result.again, [5]);
      expect(result.failure, isNull);
    });

    test('the positions are taken one after the other', () {
      final log = DriverLog(plan, tests: 1);
      expect(log.next, 0);
      log.add(ran(), milliseconds: 1);
      expect(log.next, 1);
      expect(logOf(4).next, 5);
    });

    test('nothing failed: every mutant is for the usual way', () {
      final result = logOf(5).result;
      expect(result.killed, isEmpty);
      expect(result.again, [4, 5, 6]);
    });

    test('a mutant that is not decided is for the usual way', () {
      final log = logOf(0)
        ..add(const Ran(exitCodes: [255], notes: []), milliseconds: 1)
        ..add(ran(failed: true), milliseconds: 2)
        ..add(ran(), milliseconds: 3);
      expect(log.result.killed, {5: 2});
      // And the one that was not run yet.
      expect(log.result.again, [4, 6]);
    });

    test('the tests do not pass without a mutant, at the start or later: '
        'nothing is used, and nothing is run after it', () {
      for (final position in [0, 3, 5]) {
        final log = logOf(position, failing: {1, position});
        expect(log.failure, notPassingWithoutMutant, reason: '$position');
        expect(log.next, isNull);
        expect(log.result.failure, notPassingWithoutMutant);
        expect(log.result.killed, isEmpty);
        expect(log.result.again, isEmpty);
      }
      expect(
        notPassingWithoutMutant,
        'the tests do not pass without a mutant when they are run as a '
        'program of their own, with the mutants built in',
      );
    });

    test('without a mutant the two sides have to agree as well', () {
      final log = logOf(2, failing: {1})
        ..add(
          const Ran(exitCodes: [255], notes: ['declared 0', 'pass 0 0']),
          milliseconds: 1,
        );
      expect(log.failure, notPassingWithoutMutant);
    });

    test('other tests ran without a mutant than the first time, or none', () {
      final more = logOf(2)
        ..add(
          const Ran(
            exitCodes: [0],
            notes: ['declared 0', 'pass 0 0', 'pass 0 1'],
          ),
          milliseconds: 1,
        );
      expect(more.failure, notPassingWithoutMutant);
      final none = DriverLog(
        plan,
        tests: 1,
      )..add(const Ran(exitCodes: [0], notes: ['declared 0']), milliseconds: 1);
      expect(none.failure, notPassingWithoutMutant);
    });

    test('a limit ended the tests without a mutant', () {
      final log = logOf(
        2,
        failing: {1},
      )..add(const Ran(exitCodes: [], notes: [], ended: true), milliseconds: 1);
      expect(log.failure, notEndedWithoutMutant);
      expect(log.result.failure, notEndedWithoutMutant);
      expect(notEndedWithoutMutant, 'the tests did not end without a mutant');
    });

    test('stopped before the plan was done: what failed since the tests '
        'last passed without a mutant, and what was not run, is for the '
        'usual way', () {
      final log = logOf(4, failing: {1, 2, 4});
      expect(log.next, 5);
      expect(log.result.killed, {4: 101, 5: 102});
      expect(log.result.again, [6]);

      final early = logOf(1, failing: {1});
      expect(early.result.killed, isEmpty);
      expect(early.result.again, [4, 5, 6]);

      final longer = logOf(
        5,
        failing: {1, 4},
        plan: const [-1, 4, 5, -1, 6, 7, 8, 9, -1],
      );
      expect(longer.result.killed.keys, [4]);
      // Not decided, failed since the tests last passed, and not run.
      expect(longer.result.again, [5, 7, 6, 8, 9]);
    });
  });

  test('a result is empty unless it is told otherwise', () {
    const result = DriverResult();
    expect(result.killed, isEmpty);
    expect(result.again, isEmpty);
    expect(result.failure, isNull);
  });
}
