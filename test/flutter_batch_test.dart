import 'dart:convert';

import 'package:dart_mutant/src/driver.dart';
import 'package:dart_mutant/src/flutter_batch.dart';
import 'package:test/test.dart';

/// The events of a report of the test runner, as `--file-reporter json`
/// writes them: one a line.
class Report {
  final _lines = <String>[];
  var _id = 0;
  var _time = 0;

  void _add(Map<String, Object?> event) =>
      _lines.add(jsonEncode({...event, 'time': _time += 10}));

  /// A wrapper begins: its file is loaded ([loaded], or why not), and its
  /// tests are in a group. Returns the id of the suite.
  int suite(int position, {String? loadError, String? path}) {
    final suite = _id++;
    _add({
      'type': 'suite',
      'suite': {
        'id': suite,
        'platform': 'vm',
        'path': path ?? '/copy/${wrapperPathOf(position)}',
      },
    });
    final loading = start(suite, 'loading /copy/x', groups: const []);
    if (loadError != null) {
      error(loading, loadError);
    }
    done(loading, loadError == null ? 'success' : 'error');
    return suite;
  }

  /// A test starts. Returns its id.
  int start(int suite, String name, {List<int> groups = const [1]}) {
    final id = _id++;
    _add({
      'type': 'testStart',
      'test': {'id': id, 'name': name, 'suiteID': suite, 'groupIDs': groups},
    });
    return id;
  }

  void error(int test, String error, {String stackTrace = ''}) => _add({
    'type': 'error',
    'testID': test,
    'error': error,
    'stackTrace': stackTrace,
    'isFailure': false,
  });

  void print(int test, String message) => _add({
    'type': 'print',
    'testID': test,
    'messageType': 'print',
    'message': message,
  });

  void done(int test, String result) =>
      _add({'type': 'testDone', 'testID': test, 'result': result});

  /// A test from its start to its end.
  void test(int suite, String name, {String result = 'success'}) {
    final id = start(suite, name);
    if (result != 'success') {
      error(id, 'Expected: <1>');
    }
    done(id, result);
  }

  /// A wrapper whose tests ran as they do without a mutant, but for [fails].
  int wrapper(int position, {String? fails, String result = 'failure'}) {
    final id = suite(position);
    test(id, '(setUpAll)');
    for (final name in ['first', 'second']) {
      test(id, name, result: name == fails ? result : 'success');
    }
    test(id, '(tearDownAll)');
    return id;
  }

  void end({required bool success}) =>
      _add({'type': 'done', 'success': success});

  String get text => _lines.map((line) => '$line\n').join();
}

void main() {
  test('startsFor: a working copy for every 10 mutants, and no more than '
      'there are', () {
    expect(mutantsPerStart, 10);
    expect(startsFor(mutants: 1, jobs: 4), 1);
    expect(startsFor(mutants: 10, jobs: 4), 1);
    expect(startsFor(mutants: 11, jobs: 4), 2);
    expect(startsFor(mutants: 30, jobs: 4), 3);
    expect(startsFor(mutants: 31, jobs: 4), 4);
    expect(startsFor(mutants: 400, jobs: 4), 4);
    expect(startsFor(mutants: 400, jobs: 1), 1);
    expect(mutantsToBatch, 8);
  });

  test('wrapperPathOf and positionOf: in the directory of the tool, not '
      'next to the tests', () {
    expect(wrapperDirectory, '.dart_tool/dart_mutant_flutter');
    expect(
      wrapperPathOf(12),
      '.dart_tool/dart_mutant_flutter/wrapper_12_test.dart',
    );
    expect(positionOf('/copy/${wrapperPathOf(0)}'), 0);
    expect(positionOf('/copy/${wrapperPathOf(120)}'), 120);
    expect(positionOf(r'C:\copy\wrapper_7_test.dart'), 7);
    expect(positionOf('wrapper_7_test.dart'), isNull);
    expect(positionOf('/copy/test/a_test.dart'), isNull);
    expect(positionOf('/copy/wrapper_7_test.dart.txt'), isNull);
    expect(positionOf('/copy/my_wrapper_7_test.dart'), isNull);
    expect(positionOf('/copy/wrapper_x_test.dart'), isNull);
  });

  group('flutterOf', () {
    test('flutter test, after any prefix, with what says how the package '
        'is built', () {
      for (final command in [
        ['flutter', 'test'],
        ['flutter', 'test', '--no-pub'],
        ['flutter', 'test', '--pub'],
        ['fvm', 'flutter', 'test', '--no-pub'],
        ['/sdk/bin/flutter', 'test', '--no-pub'],
        [r'C:\sdk\bin\flutter.bat', 'test'],
        ['flutter', 'test', '--no-pub', '--dart-define=A=1'],
        ['flutter', 'test', '--dart-define-from-file=env.json'],
      ]) {
        expect(flutterOf(command), command, reason: '$command');
      }
    });

    test('not another command, and not with what says which tests are run '
        'or how', () {
      for (final command in [
        <String>[],
        ['flutter'],
        ['dart', 'test'],
        ['flutter', 'run'],
        ['test', 'flutter'],
        ['myflutter', 'test'],
        ['flutter', 'test', '--platform', 'chrome'],
        ['flutter', 'test', '--no-pub', '--concurrency=4'],
        ['flutter', 'test', '--reporter', 'json'],
        ['flutter', 'test', '--coverage'],
        ['flutter', 'test', '--dart-define'],
        ['flutter', 'test', '--no-pubs'],
        ['flutter', 'test', 'test/a_test.dart'],
      ]) {
        expect(flutterOf(command), isNull, reason: '$command');
      }
    });
  });

  test('batchCommand: one test file at a time, every test of each, the '
      'time of a test in a start of its own, and the report in a file', () {
    expect(
      batchCommand(
        ['fvm', 'flutter', 'test', '--no-pub'],
        report: '/state/report.json',
        wrappers: ['a_test.dart', 'b_test.dart'],
      ),
      [
        'fvm',
        'flutter',
        'test',
        '--no-pub',
        '--concurrency=1',
        '--timeout',
        '10s',
        '--reporter',
        'json',
        '--file-reporter',
        'json:/state/report.json',
        'a_test.dart',
        'b_test.dart',
      ],
    );
  });

  test('flutterTestLibraryOf: a package with flutter_test', () {
    String config(List<Object?> packages) =>
        jsonEncode({'configVersion': 2, 'packages': packages});
    expect(
      flutterTestLibraryOf(
        config([
          {'name': 'test_api'},
          {'name': 'flutter_test'},
        ]),
      ),
      'package:flutter_test/flutter_test.dart',
    );
    expect(
      flutterTestLibraryOf(
        config([
          {'name': 'test'},
          {'name': 'flutter'},
          'flutter_test',
        ]),
      ),
      isNull,
    );
    expect(flutterTestLibraryOf(config([])), isNull);
    expect(flutterTestLibraryOf(null), isNull);
    expect(flutterTestLibraryOf('{'), isNull);
    expect(flutterTestLibraryOf('[]'), isNull);
    expect(
      flutterTestLibraryOf('{"packages": {"name": "flutter_test"}}'),
      isNull,
    );
  });

  group('testConfigOf', () {
    ({String? config, String? obstacle}) of(String test, Set<String> files) =>
        testConfigOf(test, exists: files.contains);

    test('none, and the one at the top of the package: nothing to call', () {
      expect(of('test/a_test.dart', {}), (config: null, obstacle: null));
      expect(of('a_test.dart', {}), (config: null, obstacle: null));
      expect(of('test/sub/a_test.dart', {'flutter_test_config.dart'}), (
        config: null,
        obstacle: null,
      ));
      expect(of('a_test.dart', {'flutter_test_config.dart'}), (
        config: null,
        obstacle: null,
      ));
      // One of another directory is not one of the test file.
      expect(of('test/a/a_test.dart', {'test/b/flutter_test_config.dart'}), (
        config: null,
        obstacle: null,
      ));
    });

    test('the nearest one below the top is called by the wrapper', () {
      expect(of('test/a_test.dart', {'test/flutter_test_config.dart'}), (
        config: 'test/flutter_test_config.dart',
        obstacle: null,
      ));
      expect(
        of('test/a/b/c_test.dart', {
          'test/flutter_test_config.dart',
          'test/a/flutter_test_config.dart',
        }),
        (config: 'test/a/flutter_test_config.dart', obstacle: null),
      );
      expect(
        of('test/a/b/c_test.dart', {'test/a/b/flutter_test_config.dart'}),
        (config: 'test/a/b/flutter_test_config.dart', obstacle: null),
      );
    });

    test('one below the top and one at the top: flutter test would call '
        'both for a wrapper', () {
      expect(
        of('test/a_test.dart', {
          'test/flutter_test_config.dart',
          'flutter_test_config.dart',
        }),
        (
          config: null,
          obstacle:
              'has a test (test/a_test.dart) with a flutter_test_config.dart '
              'of its own (test/flutter_test_config.dart) and one at the top '
              'of the package',
        ),
      );
    });
  });

  group('wrapperObstacle', () {
    String? of(Map<String, String> tests, [Set<String> files = const {}]) =>
        wrapperObstacle(tests, exists: files.contains);

    test('one test file with a main, which may be async', () {
      expect(of({'test/a_test.dart': 'void main() {}'}), isNull);
      expect(of({'test/a_test.dart': 'Future<void> main() async {}'}), isNull);
      expect(of({}), isNull);
    });

    test('more than one test file', () {
      expect(
        of({
          'test/a_test.dart': 'void main() {}',
          'test/b_test.dart': 'void main() {}',
        }),
        'has more than one test file, which a start of the test runner runs '
        'at the same time',
      );
    });

    test('what a test file that calls another cannot keep', () {
      expect(
        of({'test/a_test.dart': '@Timeout(Duration(seconds: 1))\nlibrary;'}),
        'has a test (test/a_test.dart) that has an annotation on its '
        'library (@Timeout(Duration(seconds: 1)))',
      );
      expect(
        of({'test/a_test.dart': 'void main(List<String> a) {}'}),
        'has a test (test/a_test.dart) that has a main() that takes '
        'arguments',
      );
      expect(
        of({'test/a_test.dart': 'void main() { Platform.script; }'}),
        'has a test (test/a_test.dart) that asks which program runs it '
        '(Platform.script)',
      );
    });

    test('a flutter_test_config.dart that cannot be kept', () {
      expect(
        of(
          {'test/a_test.dart': 'void main() {}'},
          {'test/flutter_test_config.dart', 'flutter_test_config.dart'},
        ),
        startsWith('has a test (test/a_test.dart) with a '),
      );
      expect(
        of(
          {'test/a_test.dart': 'void main() {}'},
          {'test/flutter_test_config.dart'},
        ),
        isNull,
      );
    });
  });

  group('wrapperSource', () {
    String source({int id = 3, String? config}) => wrapperSource(
      testLibrary: 'package:flutter_test/flutter_test.dart',
      target: 'package:fixture/a.dart',
      test: '../../test/a_test.dart',
      id: id,
      root: "/work/it's/1",
      state: '/work/1/.dart_tool/dart_mutant_flutter',
      config: config,
    );

    test('the mutant is at work before the tests are declared, and the '
        'main of the test file is what main returns', () {
      final text = source();
      expect(text, contains("import 'package:fixture/a.dart' as target;"));
      expect(text, contains("import '../../test/a_test.dart' as tests;"));
      expect(text, isNot(contains('as config')));
      expect(
        text,
        contains("import '../../test/a_test.dart' as tests;\n\nconst _root = "),
      );
      expect(text, contains(r"const _root = '/work/it\'s/1';"));
      expect(
        text,
        contains("const _state = '/work/1/.dart_tool/dart_mutant_flutter';"),
      );
      final at = text.indexOf(r'target.$dartMutantActive = 3;');
      expect(at, greaterThan(0));
      expect(text.indexOf('setUpAll('), greaterThan(at));
      expect(
        text.indexOf('return (tests.main as dynamic)();'),
        greaterThan(text.indexOf('tearDownAll(')),
      );
    });

    test('with a flutter_test_config.dart, through its testExecutable', () {
      final text = source(config: '../../test/flutter_test_config.dart');
      expect(
        text,
        contains("import '../../test/flutter_test_config.dart' as config;"),
      );
      expect(text, contains('return config.testExecutable(tests.main);'));
      expect(text, isNot(contains('as dynamic')));
    });

    test('a wrapper of a mutant does not run its tests when the working '
        'copy is not as the first wrapper found it; one without a mutant '
        'does', () {
      const refuses = 'else if (first.readAsStringSync() != _tree()) {';
      expect(source(), contains(refuses));
      expect(
        source(),
        contains("throw StateError('dart_mutant: $leftBefore')"),
      );
      final none = source(id: -1);
      expect(none, contains(r'target.$dartMutantActive = -1;'));
      expect(none, isNot(contains(refuses)));
      expect(none, isNot(contains(leftBefore)));
      expect(none, contains('      _first = true;\n    }\n  });'));
      // The first one says so when its own tests left something.
      for (final text in [source(), none]) {
        expect(text, contains('_first = true;'));
        expect(text, contains("throw StateError('dart_mutant: $leftByTests')"));
      }
      expect(
        leftBefore,
        'the tests before these left or changed a file in the working copy',
      );
      expect(
        leftByTests,
        'the tests left or changed a file in the working copy',
      );
    });

    test('what is compared: everything in the working copy but .dart_tool '
        'and build at its top', () {
      expect(
        source(),
        contains(r"RegExp(r'^[/\\](\.dart_tool|build)($|[/\\])')"),
      );
      expect(
        source(),
        contains('listSync(recursive: true, followLinks: false)'),
      );
    });
  });

  group('suitesOf', () {
    test('a wrapper of which every test passed, and one of which a test '
        'failed or ended with an error', () {
      final report = Report()
        ..wrapper(0)
        ..wrapper(1, fails: 'first')
        ..wrapper(2, fails: 'second', result: 'error')
        ..end(success: false);
      final (:suites, :done) = suitesOf(report.text);
      expect(done, isFalse);
      expect(suites.keys, [0, 1, 2]);
      expect(suites[0]!.outcome, Outcome.passed);
      expect(suites[1]!.outcome, Outcome.failed);
      expect(suites[2]!.outcome, Outcome.failed);
      for (final suite in suites.values) {
        expect(suite.tests, 2);
        expect(suite.complete, isTrue);
        expect(suite.dirty, isFalse);
      }
      // From the event of the suite to the last one of it: 2 for the
      // loading and 8 for the four tests, 10 ms apart; 9 with an error.
      expect(suites[0]!.milliseconds, 100);
      expect(suites[1]!.milliseconds, 110);
    });

    test('a report that says that all passed', () {
      final report = Report()
        ..wrapper(0)
        ..end(success: true);
      expect(suitesOf(report.text).done, isTrue);
    });

    test('the wrapper a report ends with is not complete when the report '
        'does not say that the run is done', () {
      final report = Report()
        ..wrapper(0)
        ..wrapper(1, fails: 'first');
      final (:suites, :done) = suitesOf(report.text);
      expect(done, isNull);
      expect(suites[0]!.complete, isTrue);
      expect(suites[1]!.complete, isFalse);
      expect(suites[1]!.outcome, Outcome.failed);
    });

    test('a file that cannot be loaded', () {
      final report = Report()
        ..suite(0, loadError: 'Failed to load "x": Compilation failed')
        ..end(success: false);
      final suite = suitesOf(report.text).suites[0]!;
      expect(suite.outcome, Outcome.undecided);
      expect(suite.tests, 0);
    });

    test('no test at all', () {
      final report = Report();
      final id = report.suite(0);
      report
        ..test(id, '(setUpAll)')
        ..end(success: true);
      expect(suitesOf(report.text).suites[0]!.outcome, Outcome.undecided);
    });

    test('a setUpAll or a tearDownAll that fails, whatever the tests did', () {
      for (final hook in [
        '(setUpAll)',
        'a group (setUpAll)',
        'a group (tearDownAll)',
      ]) {
        for (final result in ['failure', 'success']) {
          final report = Report();
          final id = report.suite(0);
          report
            ..test(id, 'first', result: result)
            ..test(id, hook, result: 'error')
            ..end(success: false);
          final suite = suitesOf(report.text).suites[0]!;
          expect(suite.outcome, Outcome.undecided, reason: '$hook $result');
          expect(suite.tests, 1);
          expect(suite.dirty, isFalse);
        }
      }
    });

    test('the wrapper that found something in the working copy', () {
      final report = Report();
      final id = report.suite(1);
      final hook = report.start(id, '(setUpAll)');
      report
        ..error(hook, 'Bad state: dart_mutant: $leftBefore')
        ..done(hook, 'error')
        ..end(success: false);
      final suite = suitesOf(report.text).suites[1]!;
      expect(suite.outcome, Outcome.undecided);
      expect(suite.dirty, isTrue);
    });

    test('a test that started and did not end', () {
      final report = Report();
      final id = report.suite(0);
      report
        ..test(id, 'first', result: 'failure')
        ..start(id, 'second');
      expect(suitesOf(report.text).suites[0]!.outcome, Outcome.undecided);
      expect(suitesOf(report.text).suites[0]!.tests, 1);
    });

    test('an error for a test that had ended', () {
      final report = Report();
      final id = report.suite(0);
      final first = report.start(id, 'first');
      report
        ..done(first, 'success')
        ..test(id, 'second', result: 'failure')
        ..error(first, 'late')
        ..end(success: false);
      expect(suitesOf(report.text).suites[0]!.outcome, Outcome.undecided);
    });

    test('what a test prints when it has ended is no error', () {
      final report = Report();
      final id = report.suite(0);
      final first = report.start(id, 'first');
      report
        ..done(first, 'success')
        ..print(first, 'still here')
        ..test(id, 'second', result: 'failure')
        ..end(success: false);
      expect(suitesOf(report.text).suites[0]!.outcome, Outcome.failed);
    });

    test('a test that ran out of time', () {
      for (final error in [
        'TimeoutException after 0:00:10.000000: Test timed out after 10 '
            'seconds.',
        'Test timed out after 10 seconds.',
      ]) {
        final report = Report();
        final id = report.suite(0);
        final first = report.start(id, 'first');
        report
          ..error(first, error)
          ..done(first, 'error')
          ..test(id, 'second', result: 'failure')
          ..end(success: false);
        expect(
          suitesOf(report.text).suites[0]!.outcome,
          Outcome.undecided,
          reason: error,
        );
      }
    });

    test('what was printed or thrown has the form of a compiler error', () {
      for (final where in ['error', 'stackTrace', 'print']) {
        final report = Report();
        final id = report.suite(0);
        final first = report.start(id, 'first');
        const text = 'a.dart:3:4: Error: bad';
        if (where == 'print') {
          report
            ..print(first, text)
            ..error(first, 'Expected: <1>');
        } else {
          report.error(
            first,
            where == 'error' ? text : 'Expected: <1>',
            stackTrace: where == 'error' ? '' : text,
          );
        }
        report
          ..done(first, 'failure')
          ..end(success: false);
        expect(
          suitesOf(report.text).suites[0]!.outcome,
          Outcome.undecided,
          reason: where,
        );
      }
    });

    test('what is no event, and what is not of a wrapper, is left out', () {
      final report = Report()..wrapper(0, fails: 'first');
      final other = report.suite(0, path: '/copy/test/a_test.dart');
      report
        ..test(other, 'first')
        ..end(success: false);
      final text =
          'not json\n[1]\n{"type":"testDone"}\n'
          '{"type":"suite","time":"1"}\n'
          '{"type":"suite","time":1,"suite":{"id":"x","path":1}}\n'
          '{"type":"testStart","time":1,"test":{"id":900,"suiteID":900}}\n'
          '{"type":"testStart","time":1,"test":{"id":"a","suiteID":0,'
          '"name":"x"}}\n'
          '{"type":"testStart","time":1,"test":{"id":901,"suiteID":0,'
          '"name":7}}\n'
          '{"type":"testDone","time":1,"testID":2,"result":7}\n'
          '{"type":"testDone","time":1,"testID":"2","result":"error"}\n'
          '{"type":"error","time":1,"testID":999,"error":"Test timed out"}\n'
          '{"type":"done","time":1,"success":"no"}\n'
          '{"type":"other","time":1}\n'
          '${report.text}'
          '{"type":"testDone","testID":3,"resu';
      final (:suites, :done) = suitesOf(text);
      expect(done, isFalse);
      expect(suites.keys, [0]);
      expect(suites[0]!.outcome, Outcome.failed);
      expect(suites[0]!.tests, 2);
    });

    test('a test of no group is the loading of the file, not a test', () {
      final report = Report();
      final id = report.suite(0);
      report
        ..start(id, 'odd', groups: const [])
        ..end(success: false);
      // It did not end: unclear, and not counted.
      final suite = suitesOf(report.text).suites[0]!;
      expect(suite.outcome, Outcome.undecided);
      expect(suite.tests, 0);
    });
  });

  group('attributable', () {
    const passed = SuiteRun(outcome: Outcome.passed, tests: 1, milliseconds: 1);
    const failed = SuiteRun(outcome: Outcome.failed, tests: 1, milliseconds: 1);
    const undecided = SuiteRun(
      outcome: Outcome.undecided,
      tests: 1,
      milliseconds: 1,
    );

    test('a suite is complete and clean unless it is told otherwise', () {
      expect(passed.complete, isTrue);
      expect(passed.dirty, isFalse);
    });

    test('the exit code, the report and the wrappers agree', () {
      expect(
        attributable(
          exitCode: 0,
          done: true,
          suites: {0: passed, 1: passed},
          wrappers: 2,
        ),
        isTrue,
      );
      expect(
        attributable(
          exitCode: 1,
          done: false,
          suites: {0: passed, 1: failed},
          wrappers: 2,
        ),
        isTrue,
      );
      expect(
        attributable(
          exitCode: 1,
          done: false,
          suites: {0: passed, 1: undecided},
          wrappers: 2,
        ),
        isTrue,
      );
      // What is printed in the form of a compiler error fails no test.
      expect(
        attributable(
          exitCode: 0,
          done: true,
          suites: {0: passed, 1: undecided},
          wrappers: 2,
        ),
        isTrue,
      );
    });

    test('they do not', () {
      // The report does not say that the run is done.
      expect(
        attributable(exitCode: 1, done: null, suites: {0: failed}, wrappers: 1),
        isFalse,
      );
      // A wrapper is missing.
      expect(
        attributable(exitCode: 0, done: true, suites: {0: passed}, wrappers: 2),
        isFalse,
      );
      // Another exit code than the report says.
      expect(
        attributable(exitCode: 1, done: true, suites: {0: passed}, wrappers: 1),
        isFalse,
      );
      expect(
        attributable(
          exitCode: 0,
          done: false,
          suites: {0: failed},
          wrappers: 1,
        ),
        isFalse,
      );
      expect(
        attributable(
          exitCode: 255,
          done: false,
          suites: {0: failed},
          wrappers: 1,
        ),
        isFalse,
      );
      // All passed, says the report, and a test failed.
      expect(
        attributable(
          exitCode: 0,
          done: true,
          suites: {0: passed, 1: failed},
          wrappers: 2,
        ),
        isFalse,
      );
      // Not all passed, says the report, and every wrapper did.
      expect(
        attributable(
          exitCode: 1,
          done: false,
          suites: {0: passed, 1: passed},
          wrappers: 2,
        ),
        isFalse,
      );
    });
  });

  test('progressOf: the events that say that the run goes on', () {
    for (final type in ['suite', 'testStart', 'testDone', 'done']) {
      expect(progressOf('{"type":"$type","time":7}'), (time: 7, type: type));
    }
    for (final line in [
      '',
      'Some tests failed.',
      '{"type":"print","time":7}',
      '{"type":"error","time":7}',
      '{"type":7,"time":7}',
      '{"time":7}',
      '{"type":"suite"}',
      '{"type":"suite","time":"7"}',
      '{"type":"suite","time":7',
      '[{"type":"suite","time":7}]',
      ' {"type":"suite","time":7}',
    ]) {
      expect(progressOf(line), isNull, reason: line);
    }
  });

  group('Quiet', () {
    Duration limitOf(Duration tests) => tests * 3 + const Duration(seconds: 5);

    test('no limit until the second wrapper begins; then from what the '
        'tests of the first took, and what loading it took', () {
      final quiet = Quiet(limitOf);
      expect(quiet.limit, isNull);
      for (final (time, type) in [
        (0, 'suite'),
        (1, 'testStart'),
        // Loaded after 4 seconds.
        (4000, 'testDone'),
        (4010, 'testStart'),
        (4200, 'testDone'),
        (4210, 'testStart'),
        (4500, 'testDone'),
      ]) {
        expect(quiet.add((time: time, type: type)), isFalse, reason: '$time');
        expect(quiet.limit, isNull);
      }
      // The tests took 600 ms.
      expect(quiet.add((time: 4600, type: 'suite')), isTrue);
      expect(quiet.limit, const Duration(milliseconds: 1800 + 5000 + 4000));
      // And it stays.
      for (final (time, type) in [
        (4700, 'testStart'),
        (9000, 'testDone'),
        (9100, 'suite'),
        (9900, 'done'),
      ]) {
        expect(quiet.add((time: time, type: type)), isFalse);
      }
      expect(quiet.limit, const Duration(milliseconds: 10800));
    });

    test('a first wrapper of which no test ended: all of it counts as '
        'tests', () {
      final quiet = Quiet(limitOf)
        ..add((time: 100, type: 'suite'))
        ..add((time: 110, type: 'testStart'));
      expect(quiet.add((time: 2100, type: 'suite')), isTrue);
      expect(quiet.limit, const Duration(milliseconds: 5000 + 2100));
    });

    test('the run is done after one wrapper: no limit', () {
      final quiet = Quiet(limitOf)
        ..add((time: 0, type: 'suite'))
        ..add((time: 10, type: 'testDone'))
        ..add((time: 20, type: 'done'));
      expect(quiet.limit, isNull);
    });
  });
}
