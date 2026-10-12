import 'dart:convert';

import 'package:dart_mutant/src/driver.dart';
import 'package:test/test.dart';

const plan = [-1, 4, 5, -1, 6, -1];

/// What the test runner says when it starts on [position], with [failed]
/// tests failed so far.
String loading(int position, {int failed = 0, int test = 0}) =>
    '00:01 +7${failed == 0 ? '' : ' -$failed'}: '
    'loading test/${driverNameOf(position, test)}';

/// What the test runner says at the end.
String summary(int failed) => failed == 0
    ? '00:09 +12: All tests passed!'
    : '00:09 +12 -$failed: Some tests failed.';

/// A test run of [plan] with one test file and one test per position, as
/// far as [last]: the test fails in the positions [failing]. In the
/// positions [unseen] the test runner counts a failure more than the
/// driver wrote down. The position [last] is started and not ended, unless
/// it is the last one of the plan, after which the test runner says how
/// many tests failed.
DriverLog ran(
  int last, {
  Set<int> failing = const {},
  Set<int> unseen = const {},
  Set<int> undeclared = const {},
  List<int> plan = plan,
  bool ended = true,
}) {
  final log = DriverLog(plan, tests: 1);
  var failed = 0;
  for (var position = 0; position <= last; position++) {
    log
      ..output(loading(position, failed: failed))
      ..record('load $position 0 ${1000 + position * 100}');
    if (position == last && last != plan.length - 1) {
      break;
    }
    if (undeclared.contains(position)) {
      failed++;
    } else {
      log
        ..record('declared $position 0 ${1010 + position * 100}')
        ..record(
          '${failing.contains(position) ? 'fail' : 'pass'} $position 0 0 '
          '${1050 + position * 100}',
        );
    }
    if (failing.contains(position)) {
      failed++;
    }
    if (unseen.contains(position)) {
      failed++;
    }
  }
  if (last == plan.length - 1 && ended) {
    log.output(summary(failed));
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

    test('a test file that imports dart:isolate starts isolates of its '
        'own', () {
      expect(
        driverObstacle("import 'dart:isolate';\nvoid main() {}"),
        'imports dart:isolate: an isolate that it starts does not end with '
        'the test file of a mutant, and no mutant is at work in it',
      );
      expect(
        driverObstacle("import 'dart:isolate' as i;\nvoid main() {}"),
        startsWith('imports dart:isolate'),
      );
      // An annotation comes first, as before.
      expect(
        driverObstacle("@Skip()\nimport 'dart:isolate';\nvoid main() {}"),
        startsWith('imports dart:isolate'),
      );
      expect(driverObstacle("import 'dart:io';\nvoid main() {}"), isNull);
      expect(driverObstacle("export 'dart:isolate';\nvoid main() {}"), isNull);
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
        'expanded',
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
        testLibraryOf(
          config(['test', 'test_api', 'flutter_test']),
          flutter: true,
        ),
        'package:flutter_test/flutter_test.dart',
      );
    });

    test('test otherwise', () {
      expect(
        testLibraryOf(
          config(['flutter_test', 'test_api', 'test']),
          flutter: false,
        ),
        'package:test/test.dart',
      );
      expect(
        testLibraryOf(config(['test', 'test_api']), flutter: true),
        'package:test/test.dart',
      );
    });

    test('neither, no test_api to ask how a test went, or no package '
        'configuration to speak of', () {
      expect(
        testLibraryOf(config(['flutter_test', 'test_api']), flutter: false),
        isNull,
      );
      expect(
        testLibraryOf(config(['tests', 'test_api']), flutter: true),
        isNull,
      );
      expect(testLibraryOf(config(['test']), flutter: false), isNull);
      expect(testLibraryOf(config(['flutter_test']), flutter: true), isNull);
      expect(testLibraryOf(null, flutter: true), isNull);
      expect(testLibraryOf('{', flutter: false), isNull);
      expect(testLibraryOf('[]', flutter: false), isNull);
      expect(
        testLibraryOf(
          '{"packages": {"name": "test", "other": "test_api"}}',
          flutter: false,
        ),
        isNull,
      );
    });
  });

  test('driverSource: the mutant is at work before the tests are declared, '
      'the driver writes down itself how each test went, and a test is not '
      'run after one of them failed', () {
    expect(
      driverSource(
        testLibrary: 'package:test/test.dart',
        target: 'package:p/a.dart',
        test: "it's/b_test.dart",
        position: 7,
        index: 1,
        id: 12,
        state: r'/tmp/$state',
      ),
      r'''
// Written by dart_mutant for one run, and removed with it.
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_api/src/backend/invoker.dart';

import 'package:p/a.dart' as target;
import 'it\'s/b_test.dart' as tests;

const _state = '/tmp/\$state';

void _note(String what, [int? test]) => File('$_state/log').writeAsStringSync(
  '$what 7 1 ${test == null ? '' : '$test '}'
  '${DateTime.now().millisecondsSinceEpoch}\n',
  mode: FileMode.append,
);

void main() {
  final cwd = File('$_state/cwd');
  if (cwd.existsSync()) {
    Directory.current = cwd.readAsStringSync();
  } else {
    cwd.writeAsStringSync(Directory.current.path, flush: true);
  }
  exitCode = 0;
  target.$dartMutantActive = 12;
  _note('load');
  final numbers = Expando<int>();
  var count = 0;
  final killed = File('$_state/killed/12');
  Object? failed;
  Object? skipped;
  setUp(() {
    final test = Invoker.current!.liveTest;
    numbers[test] ??= count++;
    if (12 != -1 && !identical(failed, test) && killed.existsSync()) {
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
        if (killed.existsSync()) {
          killed.deleteSync();
        }
      }
    } else {
      _note('fail', numbers[test]);
      failed = test;
      killed.createSync();
    }
  });
  tests.main();
  _note('declared');
}
''',
    );
  });

  test('driverSource: without a mutant, for the first test file of the '
      'first position', () {
    final source = driverSource(
      testLibrary: 'package:flutter_test/flutter_test.dart',
      target: '../lib/a.dart',
      test: 'a_test.dart',
      position: 0,
      index: 0,
      id: -1,
      state: '/s',
    );
    expect(
      source,
      contains("import 'package:flutter_test/flutter_test.dart';"),
    );
    expect(source, contains("import '../lib/a.dart' as target;"));
    expect(source, contains("import 'a_test.dart' as tests;"));
    expect(source, contains("const _state = '/s';"));
    expect(source, contains(r"  '$what 0 0 ${test == null"));
    expect(source, contains(r'  target.$dartMutantActive = -1;'));
    // No test is ever left out.
    expect(source, contains('    if (-1 != -1 && '));
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

  group('DriverLog.record', () {
    test('a driver that is started is the position that is at work, from '
        'the time it wrote', () {
      final log = DriverLog(plan, tests: 2);
      expect(log.current, isNull);
      expect(log.time, 0);
      log.record('load 0 0 1000');
      expect(log.started, {0: 1000});
      expect(log.current, 0);
      log
        ..record('load 0 1 1040')
        ..record('declared 0 1 1050');
      expect(log.started, {0: 1000});
      expect(log.time, 1050);
      log.record('load 5 0 1100');
      expect(log.current, 5);
    });

    test('what is no line of a driver is passed over', () {
      final log = DriverLog(plan, tests: 2);
      for (final line in [
        '',
        'load',
        'load 0',
        'load 0 0',
        'load 0 0 0 0 0',
        'load x 0 1000',
        'load 0 x 1000',
        'load 0 0 soon',
        // A position the plan does not have, a test file there is none of.
        'load 6 0 1000',
        'load -1 0 1000',
        'load 0 2 1000',
        'load 0 -1 1000',
        'loaded 0 0 1000',
        'declared 6 0 1000',
        'declared 0 2 1000',
        // Half written.
        'load 0 0 ',
        'pass 0 0 0',
        // Of a position no driver of which was started.
        'pass 0 0 0 1000',
        'fail 1 0 0 1000',
      ]) {
        log.record(line);
      }
      expect(log.started, isEmpty);
      expect(log.time, 0);
      log.record('load 0 0 1000');
      for (final line in [
        'pass 0 2 0 2000',
        'pass 0 -1 0 2000',
        'passed 0 0 0 2000',
        'pass 0 0 0 x',
        'pass 0 0 x 2000',
        'pass 0 0 0 2000 1',
      ]) {
        log.record(line);
      }
      expect(log.time, 1000);
      log.record('pass 0 1 3 2000');
      expect(log.time, 2000);
    });
  });

  group('DriverLog.output', () {
    test('the test runner is done when it says how the tests ended', () {
      final log = DriverLog(plan, tests: 1);
      expect(log.done, isFalse);
      expect(log.failedAtEnd, isNull);
      log.output('00:09 +12 ~1 -3: Some tests failed.');
      expect(log.done, isTrue);
      expect(log.failedAtEnd, 3);
      expect(
        (DriverLog(
          plan,
          tests: 1,
        )..output('01:09 +12: All tests passed!')).failedAtEnd,
        0,
      );
      expect(
        (DriverLog(
          plan,
          tests: 1,
        )..output('00:09 +12 ~4: All tests passed!')).failedAtEnd,
        0,
      );
    });

    test('what is no such line says nothing: what a test prints, the name '
        'of a test, a line that only looks like one', () {
      final log = DriverLog(plan, tests: 1);
      for (final line in [
        '',
        'Some tests failed.',
        '00:09 +12 -3: test/a_test.dart: Some tests failed.',
        '00:09 +12 -3: Some tests failed. [E]',
        ' 00:09 +12 -3: Some tests failed.',
        '00:09 12 -3: Some tests failed.',
        '00:09 +12 -x: Some tests failed.',
        '00:09 +12 -3 Some tests failed.',
        '{"type":"done","success":false}',
      ]) {
        log.output(line);
      }
      expect(log.done, isFalse);
    });
  });

  group('DriverLog.millisecondsOf', () {
    test('from the start of the first driver of a position to the start of '
        'the next position that has one, or to the last line of a '
        'driver', () {
      final log = DriverLog(plan, tests: 1)
        ..record('load 0 0 1000')
        ..record('pass 0 0 0 1400')
        ..record('load 2 0 2300')
        ..record('load 3 0 2900')
        ..record('pass 3 0 0 3500');
      expect(log.millisecondsOf(0), 1300);
      expect(log.millisecondsOf(2), 600);
      expect(log.millisecondsOf(3), 600);
      // No driver of it was started.
      expect(log.millisecondsOf(1), 0);
      expect(log.millisecondsOf(4), 0);
    });
  });

  group('DriverLog.limit', () {
    Duration limitOf(Duration baseline) =>
        baseline * 2 + const Duration(seconds: 1);
    const first = Duration(minutes: 10);

    test('before the first driver, and while the tests run without a '
        'mutant for the first time: the compiler and the test runner start '
        'then', () {
      final log = DriverLog(plan, tests: 1);
      expect(log.limit(limitOf, first: first), first);
      log.record('load 0 0 1000');
      expect(log.limit(limitOf, first: first), first);
    });

    test('a later position: the limit of a run after the first one', () {
      final log = DriverLog(plan, tests: 1)
        ..record('load 0 0 1000')
        ..record('load 1 0 4000');
      expect(log.limit(limitOf, first: first), const Duration(seconds: 7));
      log
        ..record('load 2 0 9000')
        ..record('pass 2 0 0 60000');
      expect(log.limit(limitOf, first: first), const Duration(seconds: 7));
    });
  });

  group('DriverLog.memoryLimit', () {
    int limitOf(int baseline) => baseline * 2 + 5;

    test('before the first driver and while the tests run without a mutant '
        'for the first time there is no limit, and what is held then is '
        'what a run without a mutant takes', () {
      final log = DriverLog(plan, tests: 1);
      expect(log.memoryLimit(10, limitOf), isNull);
      log.record('load 0 0 1000');
      expect(log.memoryLimit(100, limitOf), isNull);
      log.record('load 1 0 1100');
      expect(log.memoryLimit(900, limitOf), 205);
      log.record('load 2 0 1200');
      expect(log.memoryLimit(5000, limitOf), 205);
    });

    test('nothing was measured before the first mutant: the limit of a run '
        'that held nothing', () {
      final log = DriverLog(plan, tests: 1)
        ..record('load 0 0 1000')
        ..record('load 1 0 1100');
      expect(log.memoryLimit(900, limitOf), 5);
    });
  });

  group('DriverLog.result', () {
    const notPassing =
        'the tests do not pass without a mutant when the mutants are built in';

    test('a test run that ran everything: killed is what a driver wrote '
        'down as failed, and the test runner counted, before the tests '
        'passed without a mutant; with how long it took', () {
      final result = ran(5, failing: {1, 4}).result;
      expect(result.killed, {4: 100, 6: 100});
      expect(result.again, [5]);
      expect(result.rest, isEmpty);
      expect(result.failure, isNull);
    });

    test('nothing failed: every mutant is measured again', () {
      final log = ran(5);
      expect(log.failedAtEnd, 0);
      final result = log.result;
      expect(result.killed, isEmpty);
      expect(result.again, [4, 5, 6]);
      expect(result.rest, isEmpty);
      expect(result.failure, isNull);
    });

    test('no driver was started', () {
      const failure = 'the file with its mutants built in cannot be loaded';
      expect(DriverLog(plan, tests: 1).result.failure, failure);
      final log = DriverLog(plan, tests: 1)
        ..output(loading(0))
        ..output(summary(1));
      expect(log.result.failure, failure);
      expect(log.result.killed, isEmpty);
    });

    test('a driver says a test failed, and the test runner counted none: '
        'the mutant is not killed', () {
      final log = DriverLog(plan, tests: 1);
      for (var position = 0; position <= 5; position++) {
        log
          ..output(loading(position))
          ..record('load $position 0 1000')
          ..record('declared $position 0 1000')
          ..record('${position == 1 ? 'fail' : 'pass'} $position 0 0 1000');
      }
      log.output(summary(0));
      expect(log.result.killed, isEmpty);
      expect(log.result.again, [4, 5, 6]);
      expect(log.result.failure, isNull);
    });

    test('the test runner counted a failure that no driver saw (in a '
        'setUpAll, after the test had ended): with a mutant, that mutant is '
        'measured again, also when a test of it failed', () {
      final result = ran(5, failing: {1, 4}, unseen: {2, 4}).result;
      expect(result.killed.keys, [4]);
      expect(result.again, [5, 6]);
      expect(result.failure, isNull);
    });

    test('without a mutant, nothing of the test run is used', () {
      for (final position in [0, 3, 5]) {
        final result = ran(5, failing: {1}, unseen: {position}).result;
        expect(result.failure, notPassing, reason: '$position');
        expect(result.killed, isEmpty);
        expect(result.again, isEmpty);
        expect(result.rest, isEmpty);
      }
    });

    test('the tests fail without a mutant, at the start or later', () {
      for (final position in [0, 3, 5]) {
        final result = ran(5, failing: {1, position}).result;
        expect(result.failure, notPassing, reason: '$position');
        expect(result.killed, isEmpty, reason: '$position');
      }
    });

    test('a test file that cannot declare its tests: without a mutant '
        'nothing is used, and with one the mutant is measured again', () {
      for (final position in [0, 3, 5]) {
        expect(
          ran(5, failing: {1}, undeclared: {position}).result.failure,
          notPassing,
          reason: '$position',
        );
      }
      final result = ran(5, failing: {1}, undeclared: {2}).result;
      expect(result.killed.keys, [4]);
      expect(result.again, [5, 6]);
      expect(result.failure, isNull);
    });

    test('one of two test files of a mutant cannot declare its tests, and '
        'a test of the other fails: measured again', () {
      const two = [-1, 4, -1];
      DriverLog log({required bool declared}) {
        final log = DriverLog(two, tests: 2);
        for (final position in [0, 1, 2]) {
          log
            ..output(loading(position, failed: position == 2 ? 2 : 0))
            ..record('load $position 0 1000')
            ..record('declared $position 0 1000')
            ..record('${position == 1 ? 'fail' : 'pass'} $position 0 0 1000')
            ..output(loading(position, test: 1))
            ..record('load $position 1 1000');
          if (position != 1 || declared) {
            log
              ..record('declared $position 1 1000')
              ..record('pass $position 1 0 1000');
          }
        }
        return log..output(summary(2));
      }

      expect(log(declared: false).result.killed, isEmpty);
      expect(log(declared: false).result.again, [4]);
      // With both declared, and a second test that failed.
      final both = log(declared: true)..record('fail 1 1 0 1000');
      expect(both.result.killed.keys, [4]);
    });

    test('other tests passed without a mutant than the first time, or '
        'none', () {
      final more = ran(5)..record('pass 3 0 1 2000');
      expect(more.result.failure, notPassing);
      final fewer = ran(5)..record('pass 0 0 1 2000');
      expect(fewer.result.failure, notPassing);
      final none = DriverLog(plan, tests: 1);
      for (var position = 0; position <= 5; position++) {
        none
          ..output(loading(position))
          ..record('load $position 0 1000')
          ..record('declared $position 0 1000');
      }
      none.output(summary(0));
      expect(none.result.failure, notPassing);
    });

    test('a test that failed and passed when it was tried again passed; '
        'one that was not run after another failed is counted by both '
        'sides', () {
      final retried = ran(5, failing: {1})..record('pass 1 0 0 2000');
      // The test runner counted the one of the first try as well.
      expect(retried.result.killed, isEmpty);
      expect(retried.result.again, [4, 5, 6]);

      final log = DriverLog(plan, tests: 1);
      for (var position = 0; position <= 5; position++) {
        log
          ..output(loading(position, failed: position > 1 ? 2 : 0))
          ..record('load $position 0 1000')
          ..record('declared $position 0 1000')
          ..record('${position == 1 ? 'fail' : 'pass'} $position 0 0 1000');
        if (position == 1) {
          log.record('skip 1 0 1 1000');
        }
      }
      log.output(summary(2));
      expect(log.result.killed.keys, [4]);
      // A test that was only left out is no test that failed.
      final skippedOnly = DriverLog(const [-1, 4, -1], tests: 1);
      for (final position in [0, 1, 2]) {
        skippedOnly
          ..output(loading(position, failed: position == 2 ? 1 : 0))
          ..record('load $position 0 1000')
          ..record('declared $position 0 1000')
          ..record('${position == 1 ? 'skip' : 'pass'} $position 0 0 1000');
      }
      skippedOnly.output(summary(1));
      expect(skippedOnly.result.killed, isEmpty);
      expect(skippedOnly.result.again, [4]);
    });

    test('ended at a mutant: that one and the ones since the tests last '
        'passed without a mutant are measured again, the others are for '
        'the next test run', () {
      final result = ran(2, failing: {1}).result;
      expect(result.killed, isEmpty);
      expect(result.again, [4, 5]);
      expect(result.rest, [6]);
      expect(result.failure, isNull);

      final later = ran(4, failing: {1}).result;
      expect(later.killed.keys, [4]);
      expect(later.again, [5, 6]);
      expect(later.rest, isEmpty);
    });

    test('ended at the first mutant', () {
      final result = ran(1).result;
      expect(result.killed, isEmpty);
      expect(result.again, [4]);
      expect(result.rest, [5, 6]);
    });

    test('ended at a mutant of a longer plan: what was killed and what is '
        'measured again is not for the next test run', () {
      final result = ran(
        6,
        failing: {1},
        plan: const [-1, 4, 5, -1, 6, 7, 8, 9, -1],
      ).result;
      expect(result.killed.keys, [4]);
      expect(result.again, [5, 6, 7, 8]);
      expect(result.rest, [9]);
    });

    test('ended at the tests without a mutant, also at the last ones when '
        'the test runner does not say how the tests ended', () {
      for (final last in [0, 3]) {
        final result = ran(last, failing: {1}).result;
        expect(result.failure, notEndedWithoutMutant, reason: '$last');
        expect(result.killed, isEmpty);
        expect(result.again, isEmpty);
        expect(result.rest, isEmpty);
      }
      expect(
        ran(5, failing: {1}, ended: false).result.failure,
        notEndedWithoutMutant,
      );
      expect(notEndedWithoutMutant, 'the tests did not end without a mutant');
      expect(
        noVerdict,
        'the test runner did not say how the tests ended, or its exit code '
        'says something else',
      );
    });

    test('the test runner started on a position that no driver wrote of: '
        'its count is all there is, and it has to be none', () {
      final log = DriverLog(const [-1, 4, -1], tests: 1)
        ..output(loading(0))
        ..record('load 0 0 1000')
        ..record('declared 0 0 1000')
        ..record('pass 0 0 0 1000')
        ..output(loading(1))
        ..output(loading(2))
        ..record('load 2 0 1000')
        ..record('declared 2 0 1000')
        ..record('pass 2 0 0 1000')
        ..output(summary(0));
      expect(log.result.killed, isEmpty);
      expect(log.result.again, [4]);
    });

    test('a test file of a position was never started, in any position: '
        'the tests did not pass without a mutant', () {
      final log = DriverLog(const [-1, 4, -1], tests: 2);
      for (final position in [0, 1, 2]) {
        log
          ..output(loading(position, failed: position == 2 ? 1 : 0))
          ..record('load $position 0 1000')
          ..record('declared $position 0 1000')
          ..record('${position == 1 ? 'fail' : 'pass'} $position 0 0 1000');
      }
      log.output(summary(1));
      expect(log.result.failure, notPassing);
    });

    test('a test failed without a mutant beside the ones that passed, and '
        'both sides say so', () {
      final log = DriverLog(const [-1, 4, -1], tests: 1);
      for (final position in [0, 1, 2]) {
        log
          ..output(loading(position))
          ..record('load $position 0 1000')
          ..record('declared $position 0 1000')
          ..record('pass $position 0 0 1000');
      }
      // The same test again, which fails this time: as many tests ran.
      log
        ..record('fail 2 0 0 1000')
        ..output(summary(1));
      expect(log.result.failure, notPassing);
    });

    test('the test runner did not say that it started on a position, and '
        'did for the one after it: the test run ended there', () {
      for (final missing in [0, 1]) {
        final log = DriverLog(plan, tests: 1);
        for (var position = 0; position <= 5; position++) {
          if (position != missing) {
            log.output(loading(position));
          }
          log
            ..record('load $position 0 1000')
            ..record('declared $position 0 1000')
            ..record('pass $position 0 0 1000');
        }
        log.output(summary(0));
        // Both are about the tests without a mutant: of the first position
        // the start is not known, of the second the end of the first.
        expect(log.result.failure, notEndedWithoutMutant, reason: '$missing');
      }
    });

    test('a line of the test runner about a test whose name ends like a '
        'driver is no line about that driver', () {
      final log = DriverLog(plan, tests: 1)
        ..output(
          '00:01 +7 -9: test/${driverNameOf(0, 0)}: reads '
          'test/${driverNameOf(1, 0)}',
        );
      final full = ran(5, failing: {1});
      for (var position = 0; position <= 5; position++) {
        log
          ..output(loading(position, failed: position > 1 ? 1 : 0))
          ..record('load $position 0 ${1000 + position * 100}')
          ..record('declared $position 0 1000')
          ..record('${position == 1 ? 'fail' : 'pass'} $position 0 0 1000');
      }
      log.output(summary(1));
      expect(log.result.killed.keys, full.result.killed.keys);
      expect(log.result.killed.keys, [4]);
    });

    test('drivers at the top of the package', () {
      final log = DriverLog(const [-1, 4, -1], tests: 1);
      for (final position in [0, 1, 2]) {
        log
          ..output(
            '00:01 +3${position == 2 ? ' -1' : ''}: '
            'loading ${driverNameOf(position, 0)}',
          )
          ..record('load $position 0 1000')
          ..record('declared $position 0 1000')
          ..record('${position == 1 ? 'fail' : 'pass'} $position 0 0 1000');
      }
      log.output(summary(1));
      expect(log.result.killed.keys, [4]);
    });

    test('a line of the test runner about a test file that is no driver of '
        'the plan, or a second one about a position, changes nothing', () {
      final log = ran(5, failing: {1})
        ..output('00:02 +9 -7: loading test/other_test.dart')
        ..output(loading(6, failed: 9))
        ..output(loading(2, failed: 9))
        ..output(loading(1, failed: 9, test: 1));
      expect(log.result.killed.keys, [4]);
      expect(log.result.failure, isNull);
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
