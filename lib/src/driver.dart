import 'dart:convert';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'json.dart';
import 'mutation_run.dart';
import 'schemata.dart';

/// How many mutants are run between two runs of the tests without a mutant
/// (see [planOf]).
const mutantsBetweenChecks = 25;

/// What the name of a test file that runs the tests on one mutant starts
/// with.
const driverPrefix = 'dart_mutant_';

/// The name of the test file that runs test file number [test] of a file
/// for position [position] of a plan (see [planOf]).
String driverNameOf(int position, int test) =>
    '$driverPrefix${position}_${test}_test.dart';

final _driverName = RegExp(
  '(?:^|[/\\\\])$driverPrefix(\\d+)_\\d+_test\\.dart\$',
);

/// The position of a plan that the test file at [path] is for, or `null`
/// when it is none of [driverNameOf].
int? positionOf(String path) {
  final match = _driverName.firstMatch(path);
  return match == null ? null : int.parse(match.group(1)!);
}

final _pubspecName = RegExp(r'''^name:\s*['"]?([A-Za-z_][A-Za-z0-9_]*)''');

/// The name of the package of [pubspec], or `null` when it has none.
String? packageNameOf(String pubspec) {
  for (final line in pubspec.split('\n')) {
    final match = _pubspecName.firstMatch(line);
    if (match != null) {
      return match.group(1);
    }
  }
  return null;
}

/// How [path] (relative to the package, with `/`) is imported by a test
/// file in [directory] (the same, `''` for the package itself) so that it is
/// the library the tests import: by its `package:` name when it is below
/// `lib/` and the package is called [package], else by its place.
String importOf(String path, {required String directory, String? package}) {
  if (package != null && path.startsWith('lib/')) {
    return 'package:$package/${path.substring('lib/'.length)}';
  }
  final from = directory.isEmpty ? const <String>[] : directory.split('/');
  final to = path.split('/');
  var shared = 0;
  for (
    ;
    shared < from.length &&
        shared < to.length - 1 &&
        from[shared] == to[shared];
    shared++
  ) {}
  // A list of a length, not a loop that counts: a mutant of the loop
  // (`up--`) adds to the list until the memory of the machine is used up.
  return [
    ...List.filled(from.length - shared, '..'),
    ...to.skip(shared),
  ].join('/');
}

/// The directory of [path] (with `/`), `''` for a file at the top.
String directoryOf(String path) =>
    path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';

/// [text] as a Dart string literal.
String dartString(String text) =>
    "'${text.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$').replaceAll('\n', r'\n').replaceAll('\r', r'\r')}'";

/// Why the tests in [test] (the source of a test file) cannot be run by the
/// driver, or `null` when they can: the driver calls `main()` of the file
/// from its own `main()`, with a mutant at work.
///
/// - `main` has to be there, take no argument and not be `async`.
/// - An annotation on the library (`@Timeout`, `@TestOn`, `@Retry`, `@Tags`,
///   `@Skip`) is for the test runner, which would not see it on the driver.
/// - A test file that imports `dart:isolate` starts isolates of its own:
///   they do not end with the driver, and no mutant is at work in them.
String? driverObstacle(String test) {
  final unit = parseString(content: test, throwIfDiagnostics: false).unit;
  if (importsIsolates(unit)) {
    return startsIsolates;
  }
  final annotated = [
    for (final directive in unit.directives)
      if (directive.metadata.isNotEmpty) directive,
  ];
  if (annotated.isNotEmpty) {
    return 'has an annotation on its library '
        '(${annotated.first.metadata.first.toSource()})';
  }
  for (final declaration in unit.declarations) {
    if (declaration is FunctionDeclaration &&
        declaration.name.lexeme == 'main') {
      final main = declaration.functionExpression;
      if (main.parameters?.parameters.isEmpty != true) {
        return 'has a main() that takes arguments';
      }
      return main.body.isAsynchronous || main.body.isGenerator
          ? 'has a main() that is async'
          : null;
    }
  }
  return 'has no main()';
}

/// Why the test files [tests] (path → source) cannot be run by drivers, or
/// `null` when they can. The drivers are put next to them, so that what the
/// test runner does for a directory (`flutter_test_config.dart`, the place
/// of golden files) is done for them; they have to be in one directory, in
/// which no file has a name that a driver could have ([taken]).
String? testsObstacle(Map<String, String> tests, {required bool taken}) {
  if ({for (final test in tests.keys) directoryOf(test)}.length != 1) {
    return 'has tests in more than one directory';
  }
  if (taken) {
    return 'has a file whose name starts with $driverPrefix next to its tests';
  }
  for (final MapEntry(key: path, value: source) in tests.entries) {
    final obstacle = driverObstacle(source);
    if (obstacle != null) {
      return 'has a test ($path) that $obstacle';
    }
  }
  return null;
}

/// Where the driver for position [position] and test file number [test] of
/// the test files [tests] is put: next to them.
String driverPathOf(List<String> tests, int position, int test) {
  final directory = directoryOf(tests.first);
  final name = driverNameOf(position, test);
  return directory.isEmpty ? name : '$directory/$name';
}

/// [command] for the test files [drivers]: a test gets the time it gets the
/// usual way, and the test files are loaded and run one after the other,
/// in this order. The run is not ended at the first failing test: that is
/// the test of one mutant.
///
/// What a test did is not read from the output of this command: every
/// driver writes it down itself ([driverSource]). The output, one line per
/// test with the number of tests that failed so far, is what the test
/// runner says for itself, and the two have to agree ([DriverLog.result]).
List<String> driverCommand(List<String> command, List<String> drivers) => [
  ...command,
  '--timeout',
  '${perTestTimeoutSeconds}s',
  '--concurrency',
  '1',
  '--reporter',
  'expanded',
  ...drivers,
];

/// The library that declares `setUp` and `tearDown` for the tests of a
/// package with the package configuration [packageConfig]: of
/// `flutter_test` for a Flutter package ([flutter]), else of `test`. `null`
/// when the package has neither, or does not have `test_api`, from which a
/// driver reads how a test went.
String? testLibraryOf(String? packageConfig, {required bool flutter}) {
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
  final names = {
    if (packages is List)
      for (final package in packages) asObject(package)?['name'],
  };
  if (!names.contains('test_api')) {
    return null;
  }
  if (flutter && names.contains('flutter_test')) {
    return 'package:flutter_test/flutter_test.dart';
  }
  return names.contains('test') ? 'package:test/test.dart' : null;
}

/// The test file that runs the tests of [test] (as it imports it) on the
/// mutant [id] of [target] (as it imports it), or without a mutant for
/// [noMutant]: the driver of test file number [index] for the position
/// [position] of a plan.
///
/// The test runner gives every test file an isolate of its own, so nothing
/// of the program is shared between two mutants: the mutant is at work
/// before the first line of the tests and of the file under test runs, as
/// in a process that has just started with that mutant in the file.
///
/// **The driver writes down itself what its tests did**, one line each, at
/// the end of the file `log` in [state] (an absolute directory); see
/// [DriverLog.record] for the lines. Nothing a test prints can be taken
/// for one of them.
///
/// - `load` before the tests are declared and `declared` after: a test
///   file whose `main()` throws has the first and not the second.
/// - After every run of a test, when its `tearDown`s have run, `pass` or
///   `fail` with a number for the test. The test runner knows how the test
///   went so far, and the driver asks it (`Invoker` of `package:test_api`,
///   which is not part of its API; a version in which that is gone does
///   not compile, and then no test file of the plan is loaded).
/// - A test is not run when the file `killed/<id>` is there: a test of
///   that mutant failed, which is all there is to know about it. The
///   driver makes that file when a test fails, and takes it away when the
///   same test then passes (`retry`). A test that is not run is `skip`.
///
/// A process shares its current directory and its exit code between its
/// isolates. The first driver notes the directory in the file `cwd` in
/// [state], and every driver starts in that directory and with the exit
/// code 0.
///
/// [testLibrary] is what declares `setUp` in the package:
/// `package:test/test.dart` or `package:flutter_test/flutter_test.dart`.
String driverSource({
  required String testLibrary,
  required String target,
  required String test,
  required int position,
  required int index,
  required int id,
  required String state,
}) =>
    '''
// Written by dart_mutant for one run, and removed with it.
import 'dart:io';

import ${dartString(testLibrary)};
import 'package:test_api/src/backend/invoker.dart';

import ${dartString(target)} as target;
import ${dartString(test)} as tests;

const _state = ${dartString(state)};

void _note(String what, [int? test]) => File('\$_state/log').writeAsStringSync(
  '\$what $position $index \${test == null ? '' : '\$test '}'
  '\${DateTime.now().millisecondsSinceEpoch}\\n',
  mode: FileMode.append,
);

void main() {
  final cwd = File('\$_state/cwd');
  if (cwd.existsSync()) {
    Directory.current = cwd.readAsStringSync();
  } else {
    cwd.writeAsStringSync(Directory.current.path, flush: true);
  }
  exitCode = 0;
  target.$switchName = $id;
  _note('load');
  final numbers = Expando<int>();
  var count = 0;
  final killed = File('\$_state/killed/$id');
  Object? failed;
  Object? skipped;
  setUp(() {
    final test = Invoker.current!.liveTest;
    numbers[test] ??= count++;
    if ($id != $noMutant && !identical(failed, test) && killed.existsSync()) {
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
''';

/// The plan of the drivers for the mutants [ids]: the tests without a
/// mutant first, after every [mutantsBetweenChecks] mutants, and at the
/// end. A position of the plan is one mutant, or the tests without one.
///
/// The first run shows that the tests pass with the mutants built in, and
/// gives the time and the memory a run takes. The later ones show that the
/// tests still pass after the mutants before them: the isolates of one
/// process share nothing of the program, but the files a test writes stay.
List<int> planOf(List<int> ids) => [
  noMutant,
  for (final (index, id) in ids.indexed) ...[
    id,
    if ((index + 1) % mutantsBetweenChecks == 0 || index + 1 == ids.length)
      noMutant,
  ],
];

/// Why nothing of a test run is used when it was ended while the tests ran
/// without a mutant.
const notEndedWithoutMutant = 'the tests did not end without a mutant';

/// Why nothing of a test run is used when the test runner ended by itself
/// without saying how many tests failed, or with an exit code that says
/// something else.
const noVerdict =
    'the test runner did not say how the tests ended, or its exit code '
    'says something else';

/// A line of the test runner about a test: the time, how many tests have
/// passed, been skipped and failed so far, and then what it is about.
final _progress = RegExp(r'^\d+:\d+ \+\d+(?: ~\d+)?(?: -(\d+))?: (.*)$');

/// What is known of the drivers of a plan while their test run goes on and
/// when it has ended, from two sides that have to agree:
///
/// - what the drivers wrote down themselves ([record]): which test files
///   were loaded and declared their tests, and how each test went;
/// - what the test runner says for itself ([output]): how many tests had
///   failed when it started on a position, and at the end.
///
/// How a test went is only ever taken from the first. The second cannot be
/// taken for it: it is a count, not a test.
class DriverLog {
  DriverLog(this.plan, {required this.tests});

  /// The mutant of each position, as [planOf] made it.
  final List<int> plan;

  /// How many test files a position has.
  final int tests;

  /// The positions of which a driver was started, and when the first one
  /// was (milliseconds since the epoch, as the driver wrote it).
  final started = <int, int>{};

  final _declared = <int, Set<int>>{};
  final _loaded = <int, Set<int>>{};

  /// How the last run of each test went: `pass`, `fail` or `skip`, by
  /// position, test file and number of the test.
  final _outcomes = <(int, int, int), String>{};

  /// The time of the last line of a driver.
  var time = 0;

  /// How many tests had failed, as the test runner counts them, when it
  /// started on each position.
  final _failedBefore = <int, int>{};

  /// How many tests had failed when the test runner had run everything, or
  /// `null` while it has not said so.
  int? failedAtEnd;

  /// True when the test runner said it has run everything.
  bool get done => failedAtEnd != null;

  /// The position that is at work: the one whose first driver was started
  /// last. The test files are loaded and run one after the other.
  int? get current => started.isEmpty ? null : started.keys.last;

  /// Takes a line that a driver wrote: `load`, `declared`, `pass`, `fail`
  /// or `skip`, the position, the number of the test file, for the last
  /// three the number of the test, and the time. A line that is anything
  /// else (half written, of a position the plan does not have) is passed
  /// over.
  void record(String line) {
    final words = line.split(' ');
    final numbers = [for (final word in words.skip(1)) int.tryParse(word)];
    if (numbers.contains(null)) {
      return;
    }
    switch ((words.first, numbers)) {
      case (
            'load' || 'declared',
            [final int position, final int file, final int at],
          )
          when position >= 0 &&
              position < plan.length &&
              file >= 0 &&
              file < tests:
        time = at;
        if (words.first == 'load') {
          started.putIfAbsent(position, () => at);
          _loaded.putIfAbsent(position, () => {}).add(file);
        } else {
          _declared.putIfAbsent(position, () => {}).add(file);
        }
      case (
            'pass' || 'fail' || 'skip',
            [final int position, final int file, final int test, final int at],
          )
          when started.containsKey(position) && file >= 0 && file < tests:
        time = at;
        _outcomes[(position, file, test)] = words.first;
    }
  }

  /// Takes a line of the output of the test runner. Only what it says of
  /// its own count is read: `… -3: loading <driver>` (three tests had
  /// failed when it started on that position) and `… -5: Some tests
  /// failed.` or `…: All tests passed!` at the end.
  void output(String line) {
    final match = _progress.firstMatch(line);
    if (match == null) {
      return;
    }
    final failed = int.parse(match.group(1) ?? '0');
    final about = match.group(2)!;
    if (about == 'Some tests failed.' || about == 'All tests passed!') {
      failedAtEnd = failed;
    } else if (about.startsWith('loading ')) {
      final position = positionOf(about.substring('loading '.length));
      if (position != null && position < plan.length) {
        _failedBefore.putIfAbsent(position, () => failed);
      }
    }
  }

  /// How many tests of [position] failed as the test runner counts them,
  /// or `null` while it has not gone on to the next position or to the
  /// end.
  int? _failedByRunner(int position) {
    final before = _failedBefore[position];
    final after = position + 1 == plan.length
        ? failedAtEnd
        : _failedBefore[position + 1];
    return before == null || after == null ? null : after - before;
  }

  Iterable<String> _outcomesOf(int position) => [
    for (final MapEntry(key: (at, _, _), :value) in _outcomes.entries)
      if (at == position) value,
  ];

  /// How many tests of [position] failed as its drivers wrote it down: the
  /// tests that failed, the ones that were not run because one had failed,
  /// and a test file that could not declare its tests, which the test
  /// runner counts as one.
  int _failedByDrivers(int position) =>
      _outcomesOf(position).where((outcome) => outcome != 'pass').length +
      (_loaded[position]?.length ?? 0) -
      (_declared[position]?.length ?? 0);

  int _passed(int position) =>
      _outcomesOf(position).where((outcome) => outcome == 'pass').length;

  /// How long [position] took, in milliseconds: from the start of its
  /// first driver to the start of the next position that has one, or to
  /// the last line of a driver.
  int millisecondsOf(int position) {
    final from = started[position];
    if (from == null) {
      return 0;
    }
    final later = [
      for (final MapEntry(:key, :value) in started.entries)
        if (key > position) value,
    ];
    return (later.isEmpty ? time : later.first) - from;
  }

  /// How long the position that is at work may be at work, given how long a
  /// test run may take after one that took a given time ([limitOf]) and how
  /// long the first one may take ([first]).
  ///
  /// The first position, the tests without a mutant, takes the place of
  /// the run without a mutant of the usual way, and the compiler and the
  /// test runner start with it: it gets [first]. Every later position gets
  /// what [limitOf] makes of the time of that first one.
  Duration limit(
    Duration Function(Duration baseline) limitOf, {
    required Duration first,
  }) => started.length < 2
      ? first
      : limitOf(Duration(milliseconds: millisecondsOf(0)));

  var _memoryWithoutMutant = 0;

  /// How much memory the test run may hold now, in kilobytes, when the
  /// most it has held so far is [peak], or `null` for as much as it takes.
  ///
  /// While the first position is at work (the compiler starts, and the
  /// tests run without a mutant for the first time) there is no limit, and
  /// [peak] is what a run without a mutant takes. Every later position
  /// gets what [limitOf] makes of that.
  int? memoryLimit(int peak, int Function(int baseline) limitOf) {
    if (started.length < 2) {
      _memoryWithoutMutant = peak;
      return null;
    }
    return limitOf(_memoryWithoutMutant);
  }

  /// What is known when the test run has ended, or was ended.
  ///
  /// A position counts when the test runner has gone on from it, and only
  /// when the two sides agree on it: as many tests failed in it as its
  /// drivers wrote down. A failure that no driver saw (in a `setUpAll` or
  /// a `tearDownAll`, an error that arrives when its test has ended) is
  /// one more on the side of the test runner.
  ///
  /// - The tests without a mutant passed when every driver declared its
  ///   tests, as many tests passed as the first time, and no test failed
  ///   on either side. Anything else, and nothing of the test run is used.
  /// - A mutant is killed when a driver wrote down that a test failed on
  ///   it, the two sides agree, and the tests without a mutant passed
  ///   afterwards.
  /// - Every other mutant is not decided here: it is run the usual way
  ///   ([DriverResult.again]) or by the next test run
  ///   ([DriverResult.rest]).
  DriverResult get result {
    if (started.isEmpty) {
      return const DriverResult(
        failure: 'the file with its mutants built in cannot be loaded',
      );
    }
    final killed = <int, int>{};
    final again = <int>[];
    var open = <int>[];
    for (final (position, id) in plan.indexed) {
      final failed = _failedByRunner(position);
      if (failed == null) {
        // Where the test run was when it ended.
        if (id == noMutant) {
          return const DriverResult(failure: notEndedWithoutMutant);
        }
        final ran = {for (final position in open) plan[position]};
        return DriverResult(
          killed: killed,
          again: [...again, ...ran, id],
          rest: [
            for (final later in plan.skip(position + 1))
              if (later != noMutant) later,
          ],
        );
      }
      final declared = _declared[position]?.length == tests;
      final agreed = failed == _failedByDrivers(position);
      if (id != noMutant) {
        open.add(position);
      } else if (!declared ||
          failed != 0 ||
          !agreed ||
          _passed(0) == 0 ||
          _passed(position) != _passed(0)) {
        return const DriverResult(
          failure:
              'the tests do not pass without a mutant when the mutants are '
              'built in',
        );
      } else {
        for (final mutant in open) {
          // A test file that cannot declare its tests with a mutant at
          // work says nothing here: the usual way tells a mutant that
          // does not compile from one that fails.
          if (_outcomesOf(mutant).contains('fail') &&
              _declared[mutant]?.length == tests &&
              _failedByRunner(mutant) == _failedByDrivers(mutant)) {
            killed[plan[mutant]] = millisecondsOf(mutant);
          } else {
            again.add(plan[mutant]);
          }
        }
        open = [];
      }
    }
    return DriverResult(killed: killed, again: again);
  }
}

/// What a test run of the drivers found out.
class DriverResult {
  const DriverResult({
    this.killed = const {},
    this.again = const [],
    this.rest = const [],
    this.failure,
  });

  /// The mutants a test failed on, with how long their tests took in
  /// milliseconds: the tests without a mutant passed before and after them.
  final Map<int, int> killed;

  /// The mutants that have to be run the usual way: no test failed on
  /// them, their tests did not end or could not be declared, the test
  /// runner counted other failures than their drivers, or the test run
  /// ended before the tests without a mutant had passed after them.
  final List<int> again;

  /// The mutants the test run did not get to: for the next one.
  final List<int> rest;

  /// Why nothing the test run reported can be used, when that is so: the
  /// tests do not run this way.
  final String? failure;
}
