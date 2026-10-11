import 'dart:convert';

import 'package:dart_mutant/src/driver.dart';
import 'package:test/test.dart';

String started(int id, String name, [int time = 0]) => jsonEncode({
  'type': 'testStart',
  'time': time,
  'test': {'id': id, 'name': name},
});

String ended(int id, [String result = 'success', int time = 0]) => jsonEncode({
  'type': 'testDone',
  'time': time,
  'testID': id,
  'result': result,
});

const done = '{"type":"done","success":true,"time":0}';

/// A log of the plan `-1, 4, 5, -1, 6, -1` that has got as far as [lines].
DriverLog log(
  List<String> lines, {
  List<int> plan = const [-1, 4, 5, -1, 6, -1],
}) {
  final log = DriverLog(plan);
  lines.forEach(log.add);
  return log;
}

/// A test of each position up to [last] that passes, but for the positions
/// [failing].
List<String> run(
  int last, {
  Set<int> failing = const {},
  List<int> plan = const [-1, 4, 5, -1, 6, -1],
}) => [
  for (var position = 0; position <= last; position++) ...[
    started(position, 'dart_mutant#$position#${plan[position]} a test'),
    ended(position, failing.contains(position) ? 'failure' : 'success'),
  ],
];

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

  group('testsObstacle', () {
    const fine = 'void main() {}';

    test('tests in one directory that the driver can call', () {
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

    test('a file with the name of the driver', () {
      expect(
        testsObstacle({'test/a_test.dart': fine}, taken: true),
        'has a file called dart_mutant_driver_test.dart next to its tests',
      );
    });

    test('a test the driver cannot call: the first one is named', () {
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

  test('driverPathOf', () {
    expect(
      driverPathOf(['test/x/a_test.dart', 'test/x/b_test.dart']),
      'test/x/dart_mutant_driver_test.dart',
    );
    expect(driverPathOf(['a_test.dart']), 'dart_mutant_driver_test.dart');
    // The first one decides; the caller has seen to it that they agree.
    expect(
      driverPathOf(['a/x_test.dart', 'b/y_test.dart', 'z_test.dart']),
      'a/dart_mutant_driver_test.dart',
    );
  });

  test('driverCommand', () {
    expect(driverCommand(['flutter', 'test', '--no-pub'], 'test/d_test.dart'), [
      'flutter',
      'test',
      '--no-pub',
      '--timeout',
      '10s',
      '--reporter',
      'json',
      'test/d_test.dart',
    ]);
  });

  group('testLibraryOf', () {
    String config(List<String> names) => jsonEncode({
      'packages': [
        for (final name in names) {'name': name},
        'not an object',
      ],
    });

    test('flutter_test for a Flutter package that has it', () {
      expect(
        testLibraryOf(config(['test', 'flutter_test']), flutter: true),
        'package:flutter_test/flutter_test.dart',
      );
    });

    test('test otherwise', () {
      expect(
        testLibraryOf(config(['flutter_test', 'test']), flutter: false),
        'package:test/test.dart',
      );
      expect(
        testLibraryOf(config(['test']), flutter: true),
        'package:test/test.dart',
      );
    });

    test('neither, or no package configuration to speak of', () {
      expect(testLibraryOf(config(['flutter_test']), flutter: false), isNull);
      expect(testLibraryOf(config(['tests']), flutter: true), isNull);
      expect(testLibraryOf(null, flutter: true), isNull);
      expect(testLibraryOf('{', flutter: false), isNull);
      expect(testLibraryOf('[]', flutter: false), isNull);
      expect(
        testLibraryOf('{"packages": {"name": "test"}}', flutter: false),
        isNull,
      );
    });
  });

  test('driverSource', () {
    expect(
      driverSource(
        testLibrary: 'package:test/test.dart',
        target: 'package:p/a.dart',
        tests: ['a_test.dart', "it's/b_test.dart"],
        state: r'/tmp/$state',
      ),
      r'''
// Written by dart_mutant for one run, and removed with it.
import 'dart:io';

import 'package:test/test.dart';

import 'package:p/a.dart' as target;
import 'a_test.dart' as tests0;
import 'it\'s/b_test.dart' as tests1;

const _state = '/tmp/\$state';

void main() {
  final plan = File('$_state/plan').readAsLinesSync().map(int.parse).toList();
  for (final (position, id) in plan.indexed) {
    group('dart_mutant#$position#$id', () {
      setUpAll(() => target.$dartMutantActive = id);
      setUp(() {
        target.$dartMutantActive = id;
        if (id != -1 && File('$_state/killed/$id').existsSync()) {
          throw StateError('dart_mutant: not run, a test before it failed');
        }
      });
      tearDownAll(() => target.$dartMutantActive = -1);
      File('$_state/declared').writeAsStringSync(
        '$position\n',
        mode: FileMode.append,
        flush: true,
      );
      target.$dartMutantActive = id;
      try {
        tests0.main();
        tests1.main();
      } catch (error, stack) {
        test(
          'dart_mutant: the tests cannot be declared',
          () => Error.throwWithStackTrace(error, stack),
        );
      } finally {
        target.$dartMutantActive = -1;
      }
    });
  }
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

  group('DriverLog.add', () {
    test('a test belongs to the position its name starts with', () {
      final found = log([
        started(1, 'loading test/driver_test.dart'),
        started(2, 'dart_mutant#0#-1 (setUpAll)', 10),
        started(3, 'dart_mutant#0#-1 a test', 20),
        started(4, 'dart_mutant#1#4', 30),
        started(5, 'dart_mutant#2#5 dart_mutant#1#4 a', 40),
      ]);
      expect(found.started, {0: 10, 1: 30, 2: 40});
      expect(found.current, 2);
      expect(found.time, 40);
    });

    test('a name that only looks like one of the driver, a position the '
        'plan does not have, a mutant that is not at that position', () {
      final found = log([
        started(1, 'dart_mutant#0#-1x'),
        started(2, 'dart_mutant#0#-11 a'),
        started(3, 'dart_mutant#1#'),
        started(4, 'a dart_mutant#1#4 b'),
        started(5, 'dart_mutant#6#-1 a'),
        started(6, 'dart_mutant#1#5 a'),
        started(7, 'dart_mutant#-1#4 a'),
        jsonEncode({
          'type': 'testStart',
          'test': {'id': '8', 'name': 'dart_mutant#1#4 a'},
        }),
        jsonEncode({
          'type': 'testStart',
          'test': {'id': 9, 'name': 9},
        }),
        jsonEncode({'type': 'testStart', 'test': 'dart_mutant#1#4 a'}),
      ]);
      expect(found.started, isEmpty);
      expect(found.current, isNull);
    });

    test('the last position of the plan is one', () {
      expect(log([started(1, 'dart_mutant#5#-1 a')]).started.keys, [5]);
    });

    test('the first failing test of a mutant is reported once; of the '
        'tests without a mutant, never', () {
      final found = DriverLog([-1, 4, -1]);
      expect(found.add(started(1, 'dart_mutant#0#-1 a')), isNull);
      expect(found.add(ended(1, 'failure')), isNull);
      expect(found.add(started(2, 'dart_mutant#1#4 a')), isNull);
      expect(found.add(ended(2)), isNull);
      expect(found.failed, {0});
      expect(found.add(started(3, 'dart_mutant#1#4 b')), isNull);
      expect(found.add(ended(3, 'error')), 4);
      expect(found.add(started(4, 'dart_mutant#1#4 c')), isNull);
      expect(found.add(ended(4, 'failure')), isNull);
      expect(found.failed, {0, 1});
      expect(found.loadFailed, isFalse);
      expect(found.failedWithoutMutant, 'a');
    });

    test('the first test that fails without a mutant is remembered by its '
        'own name', () {
      final found = log([
        started(1, 'dart_mutant#0#-1 the group the test'),
        started(2, 'dart_mutant#0#-1 another'),
        started(3, 'dart_mutant#3#-1 a third'),
        ended(2, 'failure'),
        ended(1, 'failure'),
        ended(3, 'failure'),
      ]);
      expect(found.failedWithoutMutant, 'another');
    });

    test('a failing test of no position is the driver that cannot be '
        'loaded', () {
      final found = log([started(1, 'loading test/d_test.dart'), ended(1)]);
      expect(found.loadFailed, isFalse);
      found.add(ended(1, 'error'));
      expect(found.loadFailed, isTrue);
      expect(found.failed, isEmpty);
    });

    test('a log starts at no time, and what is no event reports nothing', () {
      final found = DriverLog([-1, 4, -1]);
      expect(found.time, 0);
      expect(found.add('Compiling...'), isNull);
      expect(found.add('[1, 2]'), isNull);
      expect(found.add('7'), isNull);
    });

    test('what is no event is passed over', () {
      final found = log([
        'Compiling...',
        '[1, 2]',
        '{"type":"print","message":"x"}',
        '{"type":"suite","time":"late"}',
        '{"time":7}',
      ]);
      expect(found.started, isEmpty);
      expect(found.done, isFalse);
      expect(found.time, 7);
    });

    test('done, and ended after all', () {
      final found = log(['{"type":"done","time":9}']);
      expect(found.done, isTrue);
      expect(found.time, 9);
      found.ended();
      expect(found.done, isFalse);
    });
  });

  group('DriverLog.declared', () {
    test('the last position that was noted is the one at work, until a '
        'test starts', () {
      final found = DriverLog([-1, 4, -1]);
      expect(found.current, isNull);
      found.declared('0\n');
      expect(found.current, 0);
      found.declared('0\n1\n2\n');
      expect(found.current, 2);
      found.declared('0\n1\n2\n\n');
      expect(found.current, 2);
      found.add(started(1, 'dart_mutant#0#-1 a'));
      expect(found.current, 0);
    });

    test('a note that is half written changes nothing', () {
      final found = DriverLog([-1, 4, -1])..declared('1\n');
      found.declared('1\nx');
      expect(found.declaring, 1);
      found.declared('');
      expect(found.declaring, 1);
    });
  });

  group('DriverLog.millisecondsOf', () {
    test('from the first test of a position to the first of the next that '
        'has one, or to the last line', () {
      final found = log([
        started(1, 'dart_mutant#0#-1 a', 100),
        started(2, 'dart_mutant#0#-1 b', 150),
        started(3, 'dart_mutant#1#4 a', 400),
        // The position 2 has no test.
        started(4, 'dart_mutant#3#-1 a', 1000),
        ended(4, 'success', 1250),
      ]);
      expect(found.millisecondsOf(0), 300);
      expect(found.millisecondsOf(1), 600);
      expect(found.millisecondsOf(2), 0);
      expect(found.millisecondsOf(3), 250);
    });
  });

  group('DriverLog.limit', () {
    Duration limitOf(Duration baseline) =>
        baseline * 2 + const Duration(seconds: 1);
    const first = Duration(minutes: 10);

    Duration limit(DriverLog log) => log.limit(limitOf, first: first);

    test('compiling, declaring the tests without a mutant, and the first '
        'run of them: the limit of the first run', () {
      final found = DriverLog([-1, 4, 5, -1]);
      expect(limit(found), first);
      found.declared('0\n');
      expect(limit(found), first);
      found.add(started(1, 'dart_mutant#0#-1 a', 500));
      expect(limit(found), first);
    });

    test('declaring the tests of a mutant: the limit of a run that takes '
        'no time', () {
      final found = DriverLog([-1, 4, 5, -1])..declared('1\n');
      expect(limit(found), const Duration(seconds: 1));
      found.declared('2\n');
      expect(limit(found), const Duration(seconds: 1));
    });

    test('after the last declaration the test runner has its time', () {
      final found = DriverLog([-1, 4, 5, -1])..declared('3\n');
      expect(limit(found), first);
    });

    test('a later position: the limit of a run after the first one', () {
      final found = DriverLog([-1, 4, 5, -1])
        ..declared('3\n')
        ..add(started(1, 'dart_mutant#0#-1 a', 500))
        ..add(started(2, 'dart_mutant#1#4 a', 2500));
      expect(limit(found), const Duration(seconds: 5));
      found.add(started(3, 'dart_mutant#2#5 a', 9000));
      expect(limit(found), const Duration(seconds: 5));
    });
  });

  group('DriverLog.result', () {
    test('a driver that ran everything: killed is what a test failed on '
        'before the tests passed without a mutant', () {
      final lines = run(5, failing: {1, 4});
      final found = log([
        for (final (index, line) in lines.indexed)
          line.replaceFirst('"time":0', '"time":${index * 100}'),
        done,
      ]);
      final result = found.result;
      expect(result.failure, isNull);
      expect(result.killed, {4: 200, 6: 200});
      expect(result.again, [5]);
      expect(result.rest, isEmpty);
    });

    test('nothing failed: every mutant is measured again', () {
      final result = log([...run(5), done]).result;
      expect(result.killed, isEmpty);
      expect(result.again, [4, 5, 6]);
      expect(result.rest, isEmpty);
      expect(result.failure, isNull);
    });

    test('a driver that could not be loaded', () {
      const failure = 'the file with its mutants built in cannot be loaded';
      expect(log([]).result.failure, failure);
      expect(log([done]).result.failure, failure);
      final found = log([
        started(1, 'loading'),
        ended(1, 'error'),
        ...run(5),
        done,
      ]);
      expect(found.result.failure, failure);
      expect(found.result.killed, isEmpty);
    });

    test('the tests fail without a mutant, at the start or later', () {
      const failure =
          'the tests do not pass without a mutant when they are run more '
          'than once in one process ("a test" fails)';
      expect(
        log([
          ...run(5, failing: {0}),
          done,
        ]).result.failure,
        failure,
      );
      final later = log([
        ...run(5, failing: {1, 3}),
        done,
      ]).result;
      expect(later.failure, failure);
      expect(later.killed, isEmpty);
      expect(
        log([
          ...run(5, failing: {1, 5}),
          done,
        ]).result.failure,
        failure,
      );
    });

    test('the tests without a mutant did not run at all', () {
      final found = log([
        for (final line in run(5))
          if (!line.contains('dart_mutant#3#') && !line.contains('"testID":3'))
            line,
        done,
      ]);
      expect(
        found.result.failure,
        'the tests do not pass without a mutant when they are run more '
        'than once in one process',
      );
    });

    test('a mutant without a test is measured again', () {
      final found = log([
        for (final line in run(5, failing: {1}))
          if (!line.contains('dart_mutant#2#') && !line.contains('"testID":2'))
            line,
        done,
      ]);
      expect(found.result.killed.keys, [4]);
      expect(found.result.again, [5, 6]);
    });

    test('ended at a mutant: that one and the ones since the tests last '
        'passed without a mutant are measured again, the ones after it are '
        'for the next driver', () {
      final found = log(
        run(4, failing: {1, 3, 4}, plan: const [-1, 4, -1, 5, 6, 7, -1, 8, -1]),
        plan: const [-1, 4, -1, 5, 6, 7, -1, 8, -1],
      );
      final result = found.result;
      expect(result.failure, isNull);
      expect(result.killed.keys, [4]);
      expect(result.again, [5, 6]);
      expect(result.rest, [7, 8]);
    });

    test('ended at the first mutant', () {
      final result = log(run(1)).result;
      expect(result.killed, isEmpty);
      expect(result.again, [4]);
      expect(result.rest, [5, 6]);
    });

    test('a driver that was ended says it is done: it is not', () {
      final found = log([
        ...run(1, failing: {1}),
        done,
      ])..ended();
      expect(found.result.killed, isEmpty);
      expect(found.result.again, [4]);
      expect(found.result.rest, [5, 6]);
    });

    test('ended at the tests without a mutant', () {
      const failure = 'the tests did not end without a mutant';
      expect(log(run(0)).result.failure, failure);
      final later = log(run(3, failing: {1})).result;
      expect(later.failure, failure);
      expect(later.killed, isEmpty);
    });

    test('ended while the tests of a mutant were declared: that one is '
        'measured again, all others are for the next driver', () {
      final found = DriverLog([-1, 4, 5, -1, 6, -1])..declared('0\n1\n2\n');
      final result = found.result;
      expect(result.failure, isNull);
      expect(result.killed, isEmpty);
      expect(result.again, [5]);
      expect(result.rest, [4, 6]);
    });

    test('ended while the tests without a mutant were declared', () {
      for (final declared in ['0\n', '0\n1\n2\n3\n']) {
        final found = DriverLog([-1, 4, 5, -1, 6, -1])..declared(declared);
        expect(found.result.failure, 'the tests did not end without a mutant');
      }
    });

    test('done without a test', () {
      final found = DriverLog([-1, 4, -1])
        ..declared('2\n')
        ..add(done);
      final result = found.result;
      expect(result.failure, isNull);
      expect(result.killed, isEmpty);
      expect(result.again, isEmpty);
      expect(result.rest, isEmpty);
    });
  });

  test('a result is empty unless it is told otherwise', () {
    const result = DriverResult();
    expect(result.killed, isEmpty);
    expect(result.again, isEmpty);
    expect(result.rest, isEmpty);
    expect(result.failure, isNull);
  });
}
