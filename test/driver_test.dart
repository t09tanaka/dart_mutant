import 'dart:convert';

import 'package:dart_mutant/src/driver.dart';
import 'package:test/test.dart';

/// The test file of [position] is started: the suite [id].
String suite(int id, int position, {int time = 0, int test = 0}) => jsonEncode({
  'type': 'suite',
  'time': time,
  'suite': {'id': id, 'path': 'test/${driverNameOf(position, test)}'},
});

/// A test of the suite [suite] starts. Without [groups] it is the one that
/// loads the test file.
String started(
  int id,
  int suite,
  String name, {
  int time = 0,
  List<int> groups = const [1],
}) => jsonEncode({
  'type': 'testStart',
  'time': time,
  'test': {'id': id, 'name': name, 'suiteID': suite, 'groupIDs': groups},
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

/// The test file of each position up to [last] is loaded, and its one test
/// passes, but for the positions [failing]. The suite of a position has its
/// number, its test that number as well, and the test that loads it that
/// number plus 100.
List<String> run(int last, {Set<int> failing = const {}}) => [
  for (var position = 0; position <= last; position++) ...[
    suite(position, position),
    started(position + 100, position, 'loading', groups: const []),
    ended(position + 100),
    started(position, position, 'a test'),
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

  test('driverNameOf and positionOf', () {
    expect(driverNameOf(0, 0), 'dart_mutant_0_0_test.dart');
    expect(driverNameOf(12, 3), 'dart_mutant_12_3_test.dart');
    expect(driverPrefix, 'dart_mutant_');
    expect(positionOf('dart_mutant_0_0_test.dart'), 0);
    expect(positionOf('test/dart_mutant_12_3_test.dart'), 12);
    expect(positionOf(r'C:\p\test\dart_mutant_7_10_test.dart'), 7);
    expect(positionOf('/a/b/dart_mutant_105_0_test.dart'), 105);
    // Not one of them.
    expect(positionOf('test/my_dart_mutant_1_0_test.dart'), isNull);
    expect(positionOf('test/dart_mutant_1_0_test.dart.txt'), isNull);
    expect(positionOf('test/dart_mutant_1_test.dart'), isNull);
    expect(positionOf('test/dart_mutant_a_0_test.dart'), isNull);
    expect(positionOf('test/dart_mutant_1_0_testXdart'), isNull);
    expect(positionOf('test/dart_mutant_1_0_test.dart/a_test.dart'), isNull);
    expect(positionOf(''), isNull);
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
        'has a file whose name starts with dart_mutant_ next to its tests',
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

  test('driverPathOf', () {
    expect(
      driverPathOf(['test/x/a_test.dart', 'test/x/b_test.dart'], 3, 1),
      'test/x/dart_mutant_3_1_test.dart',
    );
    expect(driverPathOf(['a_test.dart'], 0, 0), 'dart_mutant_0_0_test.dart');
    // The first one decides; the caller has seen to it that they agree.
    expect(
      driverPathOf(['a/x_test.dart', 'b/y_test.dart', 'z_test.dart'], 2, 2),
      'a/dart_mutant_2_2_test.dart',
    );
  });

  test('driverCommand', () {
    expect(
      driverCommand(
        ['flutter', 'test', '--no-pub'],
        ['test/d_0_test.dart', 'test/d_1_test.dart'],
      ),
      [
        'flutter',
        'test',
        '--no-pub',
        '--timeout',
        '10s',
        '--concurrency',
        '1',
        '--reporter',
        'json',
        'test/d_0_test.dart',
        'test/d_1_test.dart',
      ],
    );
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

  test('driverSource: the mutant is at work before the tests are declared, '
      'and a test is not run after one of them failed', () {
    expect(
      driverSource(
        testLibrary: 'package:test/test.dart',
        target: 'package:p/a.dart',
        test: "it's/b_test.dart",
        id: 12,
        state: r'/tmp/$state',
      ),
      r'''
// Written by dart_mutant for one run, and removed with it.
import 'dart:io';

import 'package:test/test.dart';

import 'package:p/a.dart' as target;
import 'it\'s/b_test.dart' as tests;

const _state = '/tmp/\$state';

void main() {
  final cwd = File('$_state/cwd');
  if (cwd.existsSync()) {
    Directory.current = cwd.readAsStringSync();
  } else {
    cwd.writeAsStringSync(Directory.current.path, flush: true);
  }
  target.$dartMutantActive = 12;
  final killed = File('$_state/killed/12');
  setUp(() {
    if (killed.existsSync()) {
      throw StateError('dart_mutant: not run, a test before it failed');
    }
  });
  tests.main();
}
''',
    );
  });

  test('driverSource: without a mutant every test is run', () {
    expect(
      driverSource(
        testLibrary: 'package:flutter_test/flutter_test.dart',
        target: '../lib/a.dart',
        test: 'a_test.dart',
        id: -1,
        state: '/s',
      ),
      r'''
// Written by dart_mutant for one run, and removed with it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/a.dart' as target;
import 'a_test.dart' as tests;

const _state = '/s';

void main() {
  final cwd = File('$_state/cwd');
  if (cwd.existsSync()) {
    Directory.current = cwd.readAsStringSync();
  } else {
    cwd.writeAsStringSync(Directory.current.path, flush: true);
  }
  target.$dartMutantActive = -1;
  tests.main();
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
    test('a test belongs to the position of its test file', () {
      final driver = log([
        suite(7, 1, time: 30),
        started(8, 7, 'loading test/dart_mutant_1_0_test.dart', groups: []),
        ended(8),
        started(9, 7, 'a test', time: 40),
      ]);
      expect(driver.started, {1: 30});
      expect(driver.current, 1);
      expect(driver.time, 40);
      expect(driver.add(ended(9, 'failure')), 4);
      expect(driver.failed, {1});
      expect(driver.unloaded, isEmpty);
      expect(driver.passed, isEmpty);
    });

    test('a test file that is not of the plan, and a test of such a file: '
        'what fails there is nothing that can be told apart', () {
      final driver = log([
        jsonEncode({
          'type': 'suite',
          'suite': {'id': 1, 'path': 'test/other_test.dart'},
        }),
        // A position the plan does not have.
        suite(2, 6),
        jsonEncode({
          'type': 'suite',
          'suite': {'id': 'x', 'path': 'test/dart_mutant_0_0_test.dart'},
        }),
        jsonEncode({
          'type': 'suite',
          'suite': {'id': 3, 'path': 5},
        }),
        '{"type":"suite"}',
        started(10, 1, 'a test'),
        started(11, 2, 'a test'),
      ]);
      expect(driver.started, isEmpty);
      expect(driver.current, isNull);
      expect(driver.loadFailed, isFalse);
      expect(driver.add(ended(10)), isNull);
      expect(driver.passed, isEmpty);
      expect(driver.loadFailed, isFalse);
      expect(driver.add(ended(11, 'error')), isNull);
      expect(driver.loadFailed, isTrue);
      expect(driver.failed, isEmpty);
    });

    test('the last position of the plan is one', () {
      expect(log([suite(1, 5)]).started, {5: 0});
    });

    test('a test without a number, or without a test, is none', () {
      final driver = log([
        suite(1, 0),
        jsonEncode({
          'type': 'testStart',
          'test': {
            'id': 'a',
            'suiteID': 1,
            'name': 'n',
            'groupIDs': [1],
          },
        }),
        '{"type":"testStart"}',
      ]);
      expect(driver.add(ended(0)), isNull);
      expect(driver.passed, isEmpty);
    });

    test('the test that loads a test file is in no group: when it fails, '
        'the test file could not be loaded, and no test failed', () {
      final driver = log([
        suite(1, 1),
        started(2, 1, 'loading', groups: []),
        suite(3, 0),
        jsonEncode({
          'type': 'testStart',
          'test': {'id': 4, 'name': 'loading', 'suiteID': 3},
        }),
      ]);
      expect(driver.add(ended(2, 'error')), isNull);
      expect(driver.unloaded, {1});
      expect(driver.add(ended(4, 'failure')), isNull);
      expect(driver.unloaded, {1, 0});
      expect(driver.failed, isEmpty);
      expect(driver.loadFailed, isFalse);
      // One that passes is not counted as a test.
      final fine = log([suite(1, 1), started(2, 1, 'loading', groups: [])]);
      expect(fine.add(ended(2)), isNull);
      expect(fine.passed, isEmpty);
      expect(fine.unloaded, isEmpty);
    });

    test('the first failing test of a mutant is reported once; of the '
        'tests without a mutant never', () {
      final driver = log([
        suite(1, 1),
        started(10, 1, 'a'),
        started(11, 1, 'b'),
        suite(2, 3),
        started(12, 2, 'c'),
      ]);
      expect(driver.add(ended(10, 'failure')), 4);
      expect(driver.add(ended(11, 'error')), isNull);
      expect(driver.add(ended(12, 'failure')), isNull);
      expect(driver.failed, {1, 3});
    });

    test('the first test that fails without a mutant is remembered by its '
        'name', () {
      final driver = log([
        suite(1, 0),
        started(10, 1, 'group first'),
        started(11, 1, 'group second'),
        suite(2, 3),
        started(12, 2, 'third'),
        ended(11, 'failure'),
        ended(10, 'failure'),
        ended(12, 'failure'),
      ]);
      expect(driver.failedWithoutMutant, 'group second');
      expect(log([]).failedWithoutMutant, isNull);
    });

    test('a failing test of no test file is the test run that cannot be '
        'told apart', () {
      final driver = log([]);
      expect(driver.loadFailed, isFalse);
      expect(driver.add(ended(1, 'error')), isNull);
      expect(driver.loadFailed, isTrue);
      expect(driver.failed, isEmpty);
    });

    test('a log starts at no time, and what is no event reports nothing', () {
      final driver = log([]);
      expect(driver.time, 0);
      expect(driver.done, isFalse);
      expect(driver.current, isNull);
    });

    test('what is no event is passed over', () {
      final driver = log([suite(1, 1, time: 5)]);
      for (final line in ['', 'Compiling…', '[]', '"text"', '{', '{}']) {
        expect(driver.add(line), isNull);
      }
      expect(driver.add('{"type":"testDone","time":"soon"}'), isNull);
      expect(driver.time, 5);
      expect(driver.done, isFalse);
    });

    test('a test runner that was told to end is not done', () {
      expect(log(['{"type":"done","success":null}']).done, isFalse);
      expect(log(['{"type":"done","success":false}']).done, isTrue);
      expect(log([done]).done, isTrue);
    });

    test('the tests that passed are counted by position', () {
      final driver = log([
        suite(1, 0),
        started(10, 1, 'a'),
        ended(10),
        started(11, 1, 'b'),
        ended(11),
        suite(2, 1),
        started(12, 2, 'a'),
        ended(12),
        started(13, 2, 'b'),
        ended(13, 'failure'),
      ]);
      expect(driver.passed, {0: 2, 1: 1});
    });

    test('the test files of one position are one position: it is started '
        'when the first of them is', () {
      final driver = log([
        suite(1, 0, time: 3),
        suite(2, 0, test: 1, time: 9),
        started(10, 1, 'a'),
        started(11, 2, 'b'),
        ended(10),
        ended(11),
      ]);
      expect(driver.started, {0: 3});
      expect(driver.passed, {0: 2});
    });

    test('done, and ended after all', () {
      final driver = log([done]);
      expect(driver.done, isTrue);
      driver.ended();
      expect(driver.done, isFalse);
    });
  });

  group('DriverLog.millisecondsOf', () {
    test('from the start of the first test file of a position to the start '
        'of the next position that has one, or to the last line', () {
      final driver = log([
        suite(1, 0, time: 100),
        started(10, 1, 'a', time: 400),
        suite(2, 2, time: 1300),
        suite(3, 3, time: 1900),
        ended(10, 'success', 2500),
      ]);
      expect(driver.millisecondsOf(0), 1200);
      expect(driver.millisecondsOf(2), 600);
      expect(driver.millisecondsOf(3), 600);
      // No test file of it was started.
      expect(driver.millisecondsOf(1), 0);
      expect(driver.millisecondsOf(4), 0);
    });
  });

  group('DriverLog.limit', () {
    Duration limitOf(Duration baseline) =>
        baseline * 2 + const Duration(seconds: 1);
    const first = Duration(minutes: 10);

    test('before the first test file, and while the tests run without a '
        'mutant for the first time: the compiler and the test runner start '
        'then', () {
      expect(log([]).limit(limitOf, first: first), first);
      expect(
        log([suite(1, 0), started(10, 1, 'a')]).limit(limitOf, first: first),
        first,
      );
    });

    test('a later position: the limit of a run after the first one', () {
      final driver = log([suite(1, 0, time: 1000), suite(2, 1, time: 4000)]);
      expect(driver.limit(limitOf, first: first), const Duration(seconds: 7));
      driver
        ..add(suite(3, 2, time: 9000))
        ..add(started(10, 3, 'a', time: 60000));
      expect(driver.limit(limitOf, first: first), const Duration(seconds: 7));
    });
  });

  group('DriverLog.memoryLimit', () {
    int limitOf(int baseline) => baseline * 2 + 5;

    test('before the first test file and while the tests run without a '
        'mutant for the first time there is no limit, and what is held then '
        'is what a run without a mutant takes', () {
      final driver = log([]);
      expect(driver.memoryLimit(10, limitOf), isNull);
      driver.add(suite(1, 0));
      expect(driver.memoryLimit(100, limitOf), isNull);
      driver.add(suite(2, 1));
      expect(driver.memoryLimit(900, limitOf), 205);
      driver.add(suite(3, 2));
      expect(driver.memoryLimit(5000, limitOf), 205);
    });

    test('nothing was measured before the first mutant: the limit of a run '
        'that held nothing', () {
      final driver = log([suite(1, 0), suite(2, 1)]);
      expect(driver.memoryLimit(900, limitOf), 5);
    });
  });

  group('DriverLog.result', () {
    test('a test run that ran everything: killed is what a test failed on '
        'before the tests passed without a mutant, with how long it took', () {
      final driver = log([
        suite(0, 0, time: 0),
        started(0, 0, 'a'),
        ended(0),
        suite(1, 1, time: 100),
        started(1, 1, 'a'),
        ended(1, 'failure'),
        suite(2, 2, time: 250),
        started(2, 2, 'a'),
        ended(2),
        suite(3, 3, time: 300),
        started(3, 3, 'a'),
        ended(3),
        suite(4, 4, time: 400),
        started(4, 4, 'a'),
        ended(4, 'failure'),
        suite(5, 5, time: 470),
        started(5, 5, 'a'),
        ended(5),
        done,
      ]);
      final result = driver.result;
      expect(result.killed, {4: 150, 6: 70});
      expect(result.again, [5]);
      expect(result.rest, isEmpty);
      expect(result.failure, isNull);
    });

    test('nothing failed: every mutant is measured again', () {
      final result = log([...run(5), done]).result;
      expect(result.killed, isEmpty);
      expect(result.again, [4, 5, 6]);
      expect(result.rest, isEmpty);
      expect(result.failure, isNull);
    });

    test('nothing was started, or something failed that is no test of the '
        'plan', () {
      const failure = 'the file with its mutants built in cannot be loaded';
      expect(log([]).result.failure, failure);
      expect(log([done]).result.failure, failure);
      final result = log([
        ...run(5, failing: {1}),
        ended(99, 'error'),
        done,
      ]).result;
      expect(result.failure, failure);
      expect(result.killed, isEmpty);
      expect(result.again, isEmpty);
      expect(result.rest, isEmpty);
    });

    test('the tests fail without a mutant, at the start or later', () {
      const failure =
          'the tests do not pass without a mutant when the mutants are '
          'built in ("a test" fails)';
      for (final position in [0, 3, 5]) {
        final result = log([
          ...run(5, failing: {1, position}),
          done,
        ]).result;
        expect(result.failure, failure, reason: '$position');
        expect(result.killed, isEmpty, reason: '$position');
        expect(result.again, isEmpty);
        expect(result.rest, isEmpty);
      }
    });

    test('a test file cannot be loaded without a mutant', () {
      for (final position in [0, 3]) {
        final result = log([
          for (var at = 0; at <= 5; at++) ...[
            suite(at, at),
            started(at + 100, at, 'loading', groups: const []),
            ended(at + 100, at == position ? 'error' : 'success'),
            if (at != position) ...[started(at, at, 'a test'), ended(at)],
          ],
          done,
        ]).result;
        expect(
          result.failure,
          'the tests do not pass without a mutant when the mutants are '
          'built in',
          reason: '$position',
        );
      }
      // Also when a test of it passed: another test file of the position.
      final both = log([
        ...run(5),
        suite(9, 3, test: 1),
        started(90, 9, 'loading', groups: const []),
        ended(90, 'error'),
        done,
      ]).result;
      expect(both.failure, isNotNull);
    });

    test('other tests ran without a mutant than the first time', () {
      const failure =
          'the tests do not pass without a mutant when the mutants are '
          'built in';
      // More the second time.
      expect(
        log([
          ...run(5),
          started(50, 3, 'more'),
          ended(50),
          done,
        ]).result.failure,
        failure,
      );
      // None the last time.
      expect(log([...run(4), suite(5, 5), done]).result.failure, failure);
      // Fewer the second time.
      expect(
        log([
          started(50, 0, 'more'),
          ...run(5),
          ended(50),
          done,
        ]).result.failure,
        isNull,
      );
      expect(
        log([
          suite(0, 0),
          started(50, 0, 'more'),
          ended(50),
          ...run(5),
          done,
        ]).result.failure,
        failure,
      );
    });

    test('no test passed without a mutant', () {
      final result = log([
        for (var position = 0; position <= 5; position++)
          suite(position, position),
        done,
      ]).result;
      expect(
        result.failure,
        'the tests do not pass without a mutant when the mutants are '
        'built in',
      );
    });

    test('a mutant whose test file cannot be loaded is measured again, also '
        'when a test of it failed: the usual way tells a mutant that does '
        'not compile from one that fails', () {
      final result = log([
        ...run(5, failing: {1, 2}),
        suite(9, 2, test: 1),
        started(90, 9, 'loading', groups: const []),
        ended(90, 'error'),
        done,
      ]).result;
      expect(result.killed.keys, [4]);
      expect(result.again, [5, 6]);
      expect(result.failure, isNull);
    });

    test('a mutant without a test is measured again', () {
      final result = log([
        suite(0, 0),
        started(0, 0, 'a'),
        ended(0),
        suite(1, 1),
        suite(2, 2),
        suite(3, 3),
        started(3, 3, 'a'),
        ended(3),
        suite(4, 4),
        suite(5, 5),
        started(5, 5, 'a'),
        ended(5),
        done,
      ]).result;
      expect(result.killed, isEmpty);
      expect(result.again, [4, 5, 6]);
    });

    test('ended at a mutant: that one and the ones since the tests last '
        'passed without a mutant are measured again, the others are for '
        'the next test run', () {
      final driver = log([
        ...run(2, failing: {1}),
        done,
      ])..ended();
      final result = driver.result;
      expect(result.killed, isEmpty);
      expect(result.again, [4, 5]);
      expect(result.rest, [6]);
      expect(result.failure, isNull);

      final later = log(run(4, failing: {1}));
      final found = later.result;
      expect(found.killed.keys, [4]);
      expect(found.again, [5, 6]);
      expect(found.rest, isEmpty);
    });

    test('ended at the first mutant', () {
      final result = log(run(1)).result;
      expect(result.killed, isEmpty);
      expect(result.again, [4]);
      expect(result.rest, [5, 6]);
    });

    test('ended at a mutant of a longer plan: what was killed and what is '
        'measured again is not for the next test run', () {
      final result = log(
        run(6, failing: {1}),
        plan: const [-1, 4, 5, -1, 6, 7, 8, 9, -1],
      ).result;
      expect(result.killed.keys, [4]);
      expect(result.again, [5, 6, 7, 8]);
      expect(result.rest, [9]);
    });

    test('ended at the tests without a mutant', () {
      for (final last in [0, 3, 5]) {
        final result = log(run(last, failing: {1})).result;
        expect(result.failure, notEndedWithoutMutant, reason: '$last');
        expect(result.killed, isEmpty);
        expect(result.again, isEmpty);
        expect(result.rest, isEmpty);
      }
      expect(notEndedWithoutMutant, 'the tests did not end without a mutant');
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
