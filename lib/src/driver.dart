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
/// inside a group of its own, once per mutant.
///
/// - `main` has to be there, take no argument and not be `async`: a group
///   cannot wait for it.
/// - An annotation on the library (`@Timeout`, `@TestOn`, `@Retry`, `@Tags`,
///   `@Skip`) is for the test runner, which would not see it on the driver.
String? driverObstacle(String test) {
  final unit = parseString(content: test, throwIfDiagnostics: false).unit;
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
/// usual way, the test files are loaded and run one after the other, in
/// this order, and the results are reported as JSON, test by test. The run
/// is not ended at the first failing test: that is the test of one mutant.
List<String> driverCommand(List<String> command, List<String> drivers) => [
  ...command,
  '--timeout',
  '${perTestTimeoutSeconds}s',
  '--concurrency',
  '1',
  '--reporter',
  'json',
  ...drivers,
];

/// The library that declares `group` and `test` for the tests of a package
/// with the package configuration [packageConfig]: of `flutter_test` for a
/// Flutter package ([flutter]), else of `test`. `null` when the package has
/// neither.
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
  if (flutter && names.contains('flutter_test')) {
    return 'package:flutter_test/flutter_test.dart';
  }
  return names.contains('test') ? 'package:test/test.dart' : null;
}

/// The test file that runs the tests of [test] (as it imports it) on the
/// mutant [id] of [target] (as it imports it), or without a mutant for
/// [noMutant].
///
/// The test runner gives every test file an isolate of its own, so nothing
/// of the program is shared between two mutants: the mutant is at work
/// before the first line of the tests and of the file under test runs, as
/// in a process that has just started with that mutant in the file.
///
/// - What a process shares between its isolates is the current directory.
///   The first driver notes it in the file `cwd` in [state] (an absolute
///   directory), and every driver starts in that directory.
/// - A test is not run when the file `killed/<id>` is there: an earlier
///   test of that mutant failed, which is all there is to know about it.
///
/// [testLibrary] is what declares `setUp` in the package:
/// `package:test/test.dart` or `package:flutter_test/flutter_test.dart`.
String driverSource({
  required String testLibrary,
  required String target,
  required String test,
  required int id,
  required String state,
}) =>
    '''
// Written by dart_mutant for one run, and removed with it.
import 'dart:io';

import ${dartString(testLibrary)};

import ${dartString(target)} as target;
import ${dartString(test)} as tests;

const _state = ${dartString(state)};

void main() {
  final cwd = File('\$_state/cwd');
  if (cwd.existsSync()) {
    Directory.current = cwd.readAsStringSync();
  } else {
    cwd.writeAsStringSync(Directory.current.path, flush: true);
  }
  target.$switchName = $id;
${id == noMutant ? '' : """
  final killed = File('\$_state/killed/$id');
  setUp(() {
    if (killed.existsSync()) {
      throw StateError('dart_mutant: not run, a test before it failed');
    }
  });
"""}  tests.main();
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

/// What the test runner has reported so far about the drivers of a plan:
/// the lines of its JSON reporter.
class DriverLog {
  DriverLog(this.plan);

  /// The mutant of each position, as [planOf] made it.
  final List<int> plan;

  final _positionOfSuite = <int, int>{};
  final _positionOfTest = <int, int>{};
  final _positionOfLoad = <int, int>{};
  final _nameOfTest = <int, String>{};

  /// The first test that failed without a mutant at work.
  String? failedWithoutMutant;

  /// The positions of which a test file was started, and when the first
  /// one was (milliseconds since the start of the test runner).
  final started = <int, int>{};

  /// The positions with a test that failed.
  final failed = <int>{};

  /// The positions with a test file that could not be loaded.
  final unloaded = <int>{};

  /// How many tests of each position have passed.
  final passed = <int, int>{};

  /// True when the test runner said it has run everything.
  var done = false;

  /// True when something failed that is no test of a position: nothing of
  /// this run can be told apart then.
  var loadFailed = false;

  /// The time of the last line (milliseconds since the start of the test
  /// runner).
  var time = 0;

  /// The position that is at work: the one whose test file was started
  /// last. The test files are loaded and run one after the other.
  int? get current => started.isEmpty ? null : started.keys.last;

  /// Takes a line of the output. Returns the mutant whose first failing
  /// test this line reports, else `null`.
  int? add(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return null;
    }
    final event = asObject(decoded);
    if (event == null) {
      return null;
    }
    final at = event['time'];
    if (at is int) {
      time = at;
    }
    switch (event['type']) {
      case 'suite':
        final suite = asObject(event['suite']);
        final id = suite?['id'];
        final path = suite?['path'];
        final position = path is String ? positionOf(path) : null;
        if (id is int && position != null && position < plan.length) {
          _positionOfSuite[id] = position;
          started.putIfAbsent(position, () => time);
        }
      case 'testStart':
        final test = asObject(event['test']);
        final id = test?['id'];
        final name = test?['name'];
        final groups = test?['groupIDs'];
        final position = _positionOfSuite[test?['suiteID']];
        if (id is int && position != null) {
          // The test that loads a test file is in no group; a test of the
          // file is at least in the one of the file itself.
          if (groups is List && groups.isNotEmpty) {
            _positionOfTest[id] = position;
            _nameOfTest[id] = '$name';
          } else {
            _positionOfLoad[id] = position;
          }
        }
      case 'testDone':
        final position = _positionOfTest[event['testID']];
        final load = _positionOfLoad[event['testID']];
        if (event['result'] == 'success') {
          if (position != null) {
            passed.update(position, (count) => count + 1, ifAbsent: () => 1);
          }
          return null;
        }
        if (load != null) {
          unloaded.add(load);
        } else if (position == null) {
          loadFailed = true;
        } else if (failed.add(position)) {
          if (plan[position] != noMutant) {
            return plan[position];
          }
          failedWithoutMutant ??= _nameOfTest[event['testID']];
        }
      case 'done':
        // A test runner that is told to end says so without a verdict.
        done = event['success'] != null;
    }
    return null;
  }

  /// How long [position] took, in milliseconds: from the start of its
  /// first test file to the start of the next position that has one, or to
  /// the last line.
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

  /// Takes it that the test run was ended before it had run everything: a
  /// test runner that is told to end still says that it is done.
  void ended() {
    done = false;
  }

  /// What is known when the test run has ended, or was ended.
  ///
  /// A mutant counts as killed when a test failed on it and the tests
  /// without a mutant passed afterwards. Everything else is not decided
  /// here: it is run the usual way ([DriverResult.again]) or by the next
  /// test run ([DriverResult.rest]).
  DriverResult get result {
    final reached = current;
    if (loadFailed || reached == null) {
      return const DriverResult(
        failure: 'the file with its mutants built in cannot be loaded',
      );
    }
    final killed = <int, int>{};
    final again = <int>[];
    var open = <int>[];
    for (final (position, id) in plan.indexed) {
      if (!done && position >= reached) {
        // Where the test run was when it ended.
        break;
      }
      if (id != noMutant) {
        open.add(position);
      } else if (failed.contains(position) ||
          unloaded.contains(position) ||
          passed[0] == null ||
          passed[position] != passed[0]) {
        // A test failed, or other tests were run than the first time: not
        // all of them, or none.
        return DriverResult(
          failure:
              'the tests do not pass without a mutant when the mutants are '
              'built in'
              '${failedWithoutMutant == null ? '' : ' ("$failedWithoutMutant" fails)'}',
        );
      } else {
        for (final passed in open) {
          // A test file that cannot be loaded with a mutant at work says
          // nothing here: the usual way tells a mutant that does not
          // compile from one that fails.
          if (failed.contains(passed) && !unloaded.contains(passed)) {
            killed[plan[passed]] = millisecondsOf(passed);
          } else {
            again.add(plan[passed]);
          }
        }
        open = [];
      }
    }
    if (done) {
      return DriverResult(
        killed: killed,
        again: [...again, for (final position in open) plan[position]],
      );
    }
    if (plan[reached] == noMutant) {
      return const DriverResult(failure: notEndedWithoutMutant);
    }
    final ran = {for (final position in open) plan[position]};
    return DriverResult(
      killed: killed,
      again: [...again, ...ran, plan[reached]],
      rest: [
        for (final (position, id) in plan.indexed)
          if (id != noMutant &&
              position != reached &&
              !killed.containsKey(id) &&
              !again.contains(id) &&
              !ran.contains(id))
            id,
      ],
    );
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
  /// them, their tests did not end or could not be loaded, or the test run
  /// ended before the tests without a mutant had passed after them.
  final List<int> again;

  /// The mutants the test run did not get to: for the next one.
  final List<int> rest;

  /// Why nothing the test run reported can be used, when that is so: the
  /// tests do not run this way.
  final String? failure;
}
