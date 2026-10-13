import 'dart:convert';
import 'dart:math';

import 'driver.dart';
import 'json.dart';
import 'mutation_run.dart';
import 'schemata.dart';

/// How many mutants of a file of a Flutter package there have to be to run
/// for them to be built into the file. With fewer, each gets a start of
/// `flutter test` of its own from the beginning: the one start for all of
/// them, with the tests without a mutant first and last, costs about as
/// much as three starts, and every mutant that is not killed there costs
/// its own start on top.
const mutantsToBatch = 8;

/// How many mutants a working copy has to have to do before another one is
/// used as well: in every copy the test runner is started once more, and
/// compiles the tests anew, which takes about as long as this many mutants.
const mutantsPerStart = 10;

/// In how many working copies the [mutants] that are built into a file of
/// a Flutter package are run, with [jobs] of them at hand: one for every
/// [mutantsPerStart] mutants, and no more than there are.
int startsFor({required int mutants, required int jobs}) =>
    min(jobs, (mutants / mutantsPerStart).ceil());

/// Where the wrappers of a file are written, with the report of the test
/// runner and what the wrappers write down: a directory of the tool in the
/// working copy, relative to it. A wrapper is the test file of one mutant:
/// it puts the mutant to work and calls the `main` of the test file.
///
/// Not next to the tests: code that lists the files of the package (a tool
/// that looks for test files, and its tests) would find more files there
/// than a start of the test runner of its own shows it.
const wrapperDirectory = '.dart_tool/dart_mutant_flutter';

/// The path of the wrapper of the position [position] of a plan
/// ([planOf]), relative to the working copy.
String wrapperPathOf(int position) =>
    '$wrapperDirectory/wrapper_${position}_test.dart';

final _wrapperPath = RegExp(r'[/\\]wrapper_(\d+)_test\.dart$');

/// The position of the wrapper at [path], as the test runner names it, or
/// `null` when it is none.
int? positionOf(String path) {
  final match = _wrapperPath.firstMatch(path);
  return match == null ? null : int.parse(match.group(1)!);
}

/// What may follow `flutter test` in a test command for the mutants of a
/// file to be run by one start of it: what says how the package is built,
/// and nothing that says which tests are run, how many at a time, or how
/// they are reported.
bool _kept(String option) =>
    option == '--no-pub' ||
    option == '--pub' ||
    option.startsWith('--dart-define=') ||
    option.startsWith('--dart-define-from-file=');

/// [command] when it runs the test files of a Flutter package and can run
/// the wrappers of many mutants in one start: `flutter test`, after any
/// prefix (`fvm flutter test`), followed by nothing but `--no-pub`, `--pub`
/// and `--dart-define`s. `null` for a command of another form (`dart test`,
/// `flutter test --platform chrome`): each mutant gets a start of its own.
List<String>? flutterOf(List<String> command) {
  for (var index = 0; index + 1 < command.length; index++) {
    final program = command[index].split(RegExp(r'[/\\]')).last;
    if ((program == 'flutter' || program == 'flutter.bat') &&
        command[index + 1] == 'test') {
      return command.skip(index + 2).every(_kept) ? command : null;
    }
  }
  return null;
}

/// The one start of the test runner for the wrappers [wrappers]: one test
/// file at a time (two would share the files of the package), every test
/// of each (no `--fail-fast`: the first failing test of one mutant would
/// end the run for all of them), a test with the time it has in a start of
/// its own ([perTestTimeoutSeconds]), and the report of the test runner in
/// the file [report] as well, which is the one that is read: nothing a
/// test prints gets into it.
List<String> batchCommand(
  List<String> command, {
  required String report,
  required List<String> wrappers,
}) => [
  ...command,
  '--concurrency=1',
  '--timeout',
  '${perTestTimeoutSeconds}s',
  '--reporter',
  'json',
  '--file-reporter',
  'json:$report',
  ...wrappers,
];

/// `package:flutter_test/flutter_test.dart` when the package with the
/// package configuration [packageConfig] has `flutter_test`, with which a
/// wrapper declares what it runs before the tests; else `null`.
String? flutterTestLibraryOf(String? packageConfig) {
  if (packageConfig == null) {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(packageConfig);
  } on FormatException {
    return null;
  }
  final packages = asObject(decoded)?['packages'];
  return packages is List &&
          packages.any(
            (package) => asObject(package)?['name'] == 'flutter_test',
          )
      ? 'package:flutter_test/flutter_test.dart'
      : null;
}

/// The name of the file with which a package says how its tests are
/// started: `flutter test` calls `testExecutable` of the one that is
/// nearest to a test file, from its directory up to the package.
const testConfigName = 'flutter_test_config.dart';

/// Which [testConfigName] a wrapper of the test file [test] (relative to
/// the package, with `/`) has to call, and why it cannot be run by wrappers
/// when that is so. [exists] says whether a file of the package is there.
///
/// A wrapper is in [wrapperDirectory], so `flutter test` finds no
/// [testConfigName] for it but the one at the top of the package. The one
/// nearest to the test file is the one a start of its own uses:
///
/// - none: nothing to call;
/// - the one at the top of the package: `flutter test` calls it for the
///   wrapper as well;
/// - one below the top, and none at the top: the wrapper calls it
///   ([config]), as `flutter test` does;
/// - one below the top, and one at the top: `flutter test` would call the
///   one at the top for the wrapper, and only the other for the test file.
///   That is an [obstacle].
({String? config, String? obstacle}) testConfigOf(
  String test, {
  required bool Function(String path) exists,
}) {
  // The directories of the test file below the top of the package, the
  // nearest first. A list of a length, not a loop that goes up: a mutant of
  // such a loop does not end.
  final directories = test.split('/')..removeLast();
  final nearest = [
    for (final (index, _) in directories.indexed)
      '${directories.take(directories.length - index).join('/')}/'
          '$testConfigName',
  ].where(exists).firstOrNull;
  if (nearest == null) {
    return (config: null, obstacle: null);
  }
  return exists(testConfigName)
      ? (
          config: null,
          obstacle:
              'has a test ($test) with a $testConfigName of its own '
              '($nearest) and one at the top of the package',
        )
      : (config: nearest, obstacle: null);
}

/// Why the test files [tests] (path → source) of a file of a Flutter
/// package cannot be run by wrappers, or `null` when they can.
///
/// - There has to be one test file: `flutter test` runs the test files of
///   one start at the same time, each in a process of its own, and the
///   wrappers are run one after the other.
/// - What [driverObstacle] says of it, but for a `main` that is `async`:
///   the test runner waits for the `main` of a wrapper, which returns what
///   the `main` of the test file returns.
/// - What [testConfigOf] says of it.
String? wrapperObstacle(
  Map<String, String> tests, {
  required bool Function(String path) exists,
}) {
  if (tests.length > 1) {
    return 'has more than one test file, which a start of the test runner '
        'runs at the same time';
  }
  if (tests.isEmpty) {
    return null;
  }
  final MapEntry(key: path, value: source) = tests.entries.single;
  final obstacle = driverObstacle(source, asyncMain: true);
  return obstacle != null
      ? 'has a test ($path) that $obstacle'
      : testConfigOf(path, exists: exists).obstacle;
}

/// The test file of the mutant [id] ([noMutant] for none) of [target] (as
/// the wrapper imports it): it puts the mutant to work and calls the `main`
/// of [test] (as the wrapper imports it), through `testExecutable` of
/// [config] when the test file has one (see [testConfigOf]). The test
/// runner runs it as it runs any test file: `flutter test` gives every test
/// file **a process of its own**, so the mutant is at work in the whole
/// process, from before the first line of the tests, and two mutants share
/// nothing that two starts of the test runner do not share.
///
/// But for the files of the package: the wrappers of a file are run in one
/// working copy, one after the other, and a test file of which a test has
/// failed is run to its end (a start per mutant has `--fail-fast`), so more
/// can be left there than a start per mutant leaves. So before its tests
/// run (in a `setUpAll`, which runs before any other), a wrapper compares
/// what is in the working copy [root] with what was there when the first
/// wrapper ran (the file `tree` in [state], both absolute): the names of
/// its directories, and the names, the sizes and the times of its files,
/// without `.dart_tool` and `build`. When that is not the same, the wrapper
/// fails there, no test of it is run, and the mutant gets a start of its
/// own. The first wrapper, which has no mutant, compares it once more when
/// its tests have run: tests that pass and leave something are no tests to
/// run many mutants in a row with. (A later wrapper without a mutant runs
/// its tests whatever it finds: it shows that the tests still pass.)
///
/// [testLibrary] is what declares `setUpAll` in the package.
String wrapperSource({
  required String testLibrary,
  required String target,
  required String test,
  required int id,
  required String root,
  required String state,
  String? config,
}) =>
    '''
// Written by dart_mutant for one run, and removed with it.
import 'dart:io';

import ${dartString(testLibrary)};

import ${dartString(target)} as target;
import ${dartString(test)} as tests;
${config == null ? '' : 'import ${dartString(config)} as config;\n'}
const _root = ${dartString(root)};
const _state = ${dartString(state)};

String _tree() {
  final lines = <String>[];
  for (final entity in Directory(
    _root,
  ).listSync(recursive: true, followLinks: false)) {
    final path = entity.path.substring(_root.length);
    if (RegExp(r'^[/\\\\](\\.dart_tool|build)(\$|[/\\\\])').hasMatch(path)) {
      continue;
    }
    if (entity is File) {
      final stat = entity.statSync();
      lines.add('\$path \${stat.size} \${stat.modified.microsecondsSinceEpoch}');
    } else if (entity is Link) {
      lines.add('\$path -> \${entity.targetSync()}');
    } else {
      lines.add(path);
    }
  }
  return (lines..sort()).join('\\n');
}

var _first = false;

Object? main() {
  target.$switchName = $id;
  setUpAll(() {
    final first = File('\$_state/tree');
    if (!first.existsSync()) {
      first.writeAsStringSync(_tree(), flush: true);
      _first = true;
    }${id == noMutant ? '' : """ else if (first.readAsStringSync() != _tree()) {
      throw StateError('dart_mutant: $leftBefore');
    }"""}
  });
  tearDownAll(() {
    if (_first && File('\$_state/tree').readAsStringSync() != _tree()) {
      throw StateError('dart_mutant: $leftByTests');
    }
  });
  return ${config == null ? '(tests.main as dynamic)()' : 'config.testExecutable(tests.main)'};
}
''';

/// What a wrapper says when it does not run its tests.
const leftBefore =
    'the tests before these left or changed a file in the working copy';

/// What a wrapper without a mutant says when its tests have run.
const leftByTests = 'the tests left or changed a file in the working copy';

/// What is known of one wrapper from the report of the test runner.
class SuiteRun {
  const SuiteRun({
    required this.outcome,
    required this.tests,
    required this.milliseconds,
    this.complete = true,
    this.dirty = false,
  });

  /// See [suitesOf].
  final Outcome outcome;

  /// How many tests of it ended, without what the test runner adds (the
  /// loading of the file, `setUpAll`, `tearDownAll`).
  final int tests;

  /// From the first event of the wrapper to the last.
  final int milliseconds;

  /// False for the wrapper the report ends with, when the report does not
  /// say that the run is done: nothing says that it ran to its end.
  final bool complete;

  /// True when the wrapper did not run its tests for what it found in the
  /// working copy ([leftBefore]).
  final bool dirty;
}

/// The runner's own text for a test that ran out of time.
final _timedOut = RegExp(r'TimeoutException|Test timed out');

bool _isHook(String name) =>
    name.endsWith('(setUpAll)') || name.endsWith('(tearDownAll)');

/// What the report [report] of the test runner (`--file-reporter json`,
/// one event a line) says of every wrapper in it, by position
/// ([positionOf]), and whether it says that the run is done, and how
/// ([done] is `null` when it does not).
///
/// **A test failed** ([Outcome.failed]) when a test of the wrapper ended
/// with `failure` or `error`, and nothing about the wrapper is unclear.
/// **All tests passed** ([Outcome.passed]) when at least one test ended,
/// each with `success`, and nothing is unclear. Anything else is
/// [Outcome.undecided], and so is a wrapper about which something is
/// unclear:
///
/// - the file could not be loaded (it does not compile, its `main` threw);
/// - a `setUpAll` or `tearDownAll` did not end with `success` (one of them
///   is the wrapper's own check of the working copy);
/// - a test started and did not end;
/// - an error arrived for a test that had ended;
/// - an error is a test that ran out of time;
/// - what the tests printed and threw has the form of a compiler error,
///   which a start of the test runner of its own is read as a mutant that
///   does not compile ([classifyRun]).
///
/// A line that is no event (the report was cut off in the middle of one)
/// is left out, and so is an event of a suite that is no wrapper.
({Map<int, SuiteRun> suites, bool? done}) suitesOf(String report) {
  final position = <int, int>{};
  final suiteOf = <int, int>{};
  final names = <int, String>{};
  final real = <int, bool>{};
  final results = <int, String>{};
  final started = <int, int>{};
  final ended = <int, int>{};
  final unclear = <int>{};
  final dirty = <int>{};
  final texts = <int, StringBuffer>{};
  bool? done;
  int? last;

  for (final line in const LineSplitter().convert(report)) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    final event = asObject(decoded);
    final time = event?['time'];
    if (event == null || time is! int) {
      continue;
    }
    switch (event['type']) {
      case 'suite':
        final suite = asObject(event['suite']);
        final id = suite?['id'];
        final path = suite?['path'];
        final at = path is String ? positionOf(path) : null;
        if (id is int && at != null) {
          position[id] = at;
          started[at] = time;
          ended[at] = time;
          last = at;
        }
      case 'testStart':
        final test = asObject(event['test']);
        final id = test?['id'];
        final at = position[test?['suiteID']];
        final name = test?['name'];
        final groups = test?['groupIDs'];
        if (id is int && at != null && name is String) {
          suiteOf[id] = at;
          names[id] = name;
          // The loading of a file is a test of no group.
          real[id] = groups is List && groups.isNotEmpty && !_isHook(name);
          ended[at] = time;
        }
      case 'error' || 'print':
        final at = suiteOf[event['testID']];
        if (at != null) {
          ended[at] = time;
          texts.putIfAbsent(at, StringBuffer.new)
            ..writeln(event['error'] ?? event['message'])
            ..writeln(event['stackTrace']);
          if (event['type'] == 'error') {
            final error = '${event['error']}';
            if (results.containsKey(event['testID']) ||
                _timedOut.hasMatch(error)) {
              unclear.add(at);
            }
            if (error.contains(leftBefore)) {
              dirty.add(at);
            }
          }
        }
      case 'testDone':
        final id = event['testID'];
        final at = suiteOf[id];
        final result = event['result'];
        if (id is int && at != null && result is String) {
          results[id] = result;
          ended[at] = time;
        }
      case 'done':
        final success = event['success'];
        done = success is bool ? success : null;
    }
  }

  final suites = <int, SuiteRun>{};
  for (final at in started.keys) {
    final tests = [
      for (final MapEntry(key: id, value: suite) in suiteOf.entries)
        if (suite == at) id,
    ];
    final own = tests.where((id) => real[id]!).toList();
    final others = tests.where((id) => !real[id]!);
    final clear =
        !unclear.contains(at) &&
        tests.every(results.containsKey) &&
        others.every((id) => results[id] == 'success') &&
        own.isNotEmpty &&
        classifyRun(
              // Of a start that failed, whatever its exit code.
              exitCode: null,
              output: '${texts[at]}',
              timedOut: false,
            ) !=
            compileError;
    suites[at] = SuiteRun(
      outcome: !clear
          ? Outcome.undecided
          : own.every((id) => results[id] == 'success')
          ? Outcome.passed
          : Outcome.failed,
      tests: own.where(results.containsKey).length,
      milliseconds: ended[at]! - started[at]!,
      complete: done != null || at != last,
      dirty: dirty.contains(at),
    );
  }
  return (suites: suites, done: done);
}

/// Whether a start of the test runner that ended by itself with [exitCode]
/// ended the way its report [done] and [suites] say ([suitesOf]) for
/// [wrappers] wrappers: the report says that the run is done, every wrapper
/// is in it, it ended with 0 when it says that all passed and with 1 when
/// not, and no test of a wrapper failed where it says that all passed. When
/// that is not so, nothing of the start is used.
bool attributable({
  required int exitCode,
  required bool? done,
  required Map<int, SuiteRun> suites,
  required int wrappers,
}) =>
    done != null &&
    suites.length == wrappers &&
    exitCode == (done ? 0 : 1) &&
    (done
        ? suites.values.every((suite) => suite.outcome != Outcome.failed)
        : suites.values.any((suite) => suite.outcome != Outcome.passed));

/// What a line of the standard output of the test runner tells while it
/// runs (`--reporter json`), for how long it may go on only: `null` for a
/// line that is no event of a wrapper beginning (`suite`), of a test
/// starting or ending, or of the run being done; else the time of the event
/// (milliseconds since the start) and which it is. Nothing else is read
/// there: what is known of a mutant is read from the report in the file.
({int time, String type})? progressOf(String line) {
  if (!line.startsWith('{')) {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    return null;
  }
  final event = asObject(decoded);
  final time = event?['time'];
  final type = event?['type'];
  return time is int &&
          type is String &&
          const {'suite', 'testStart', 'testDone', 'done'}.contains(type)
      ? (time: time, type: type)
      : null;
}

/// How long a start may go on without a test starting or ending, and from
/// when: fed with what [progressOf] says of every line, it is `null` until
/// the second wrapper begins, and then [limitOf] of what the tests of the
/// first one took (it has no mutant), plus what loading the first one took,
/// which is more than loading a later one takes.
class Quiet {
  Quiet(this.limitOf);

  final Duration Function(Duration tests) limitOf;

  var _suites = 0;
  int? _loaded;

  /// See [Quiet].
  Duration? limit;

  /// Takes the next event. Returns true when [limit] is known from now on.
  bool add(({int time, String type}) event) {
    if (event.type == 'suite') {
      _suites++;
      if (_suites == 2) {
        final loaded = _loaded ?? event.time;
        limit =
            limitOf(Duration(milliseconds: event.time - loaded)) +
            Duration(milliseconds: loaded);
        return true;
      }
    } else if (event.type == 'testDone') {
      // The first test of a wrapper is the loading of its file.
      _loaded ??= event.time;
    }
    return false;
  }
}
