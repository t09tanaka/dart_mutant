import 'dart:convert';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'json.dart';
import 'schemata.dart';

/// How many mutants are run between two runs of the tests without a mutant
/// (see [planOf]).
const mutantsBetweenChecks = 25;

/// What the name of a driver starts with: the program that runs a test
/// file of a file on one of its built-in mutants.
const driverPrefix = 'dart_mutant_driver_';

/// The name of the driver of test file number [test] of a file. It is no
/// test file: the test runner does not pick it up.
String driverNameOf(int test) => '$driverPrefix$test.dart';

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

/// Why the tests in [test] (the source of a test file) cannot be run by a
/// driver, or `null` when they can: the driver calls `main()` of the file
/// from its own `main()`, with a mutant at work, in a process without the
/// test runner.
///
/// - `main` has to be there, take no argument and not be `async`.
/// - An annotation on the library (`@Timeout`, `@TestOn`, `@Retry`, `@Tags`,
///   `@Skip`) is for the test runner, which is not there.
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
/// `null` when they can. The drivers are put next to them, so that they
/// import what the test files import; they have to be in one directory, in
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

final _tagLine = RegExp(r'^(tags:|\s+[A-Za-z_][A-Za-z0-9_-]*:)\s*(#.*)?$');
final _noLine = RegExp(r'^\s*(#.*)?$');

/// Why a package whose `dart_test.yaml` is [config] (`null` when it has
/// none) is not run by drivers, or `null` when it can be. A driver runs the
/// tests without the test runner, which is what reads that file: it may
/// only name tags, which change nothing about how a test runs. Anything
/// else in it (a timeout, `retry`, a tag with settings, platforms) would be
/// in force for a mutant with a start of the test runner of its own, and
/// not here.
String? configObstacle(String? config) =>
    config == null ||
        config
            .split('\n')
            .every((line) => _tagLine.hasMatch(line) || _noLine.hasMatch(line))
    ? null
    : 'has a dart_test.yaml that says more than the names of tags, which '
          'only the test runner reads';

/// Where the driver of test file number [test] of the test files [tests]
/// is put: next to them.
String driverPathOf(List<String> tests, int test) {
  final directory = directoryOf(tests.first);
  final name = driverNameOf(test);
  return directory.isEmpty ? name : '$directory/$name';
}

/// What starts Dart programs, given the command that runs test files:
/// [command] without its `test` at the end (`dart test` → `dart`, `fvm dart
/// test` → `fvm dart`). `null` for a command of another form (`flutter test
/// --no-pub`, `dart test -p chrome`): its tests cannot be run as a program
/// of their own.
List<String>? dartOf(List<String> command) =>
    command.length > 1 && command.last == 'test'
    ? command.sublist(0, command.length - 1)
    : null;

/// The command that compiles the driver [driver] once, to [program].
List<String> compileCommand(List<String> dart, String driver, String program) =>
    [...dart, 'compile', 'kernel', driver, '-o', program];

/// The command that runs the compiled driver [program] on the mutant [id]
/// ([noMutant] for none), in a process of its own.
List<String> driverCommand(List<String> dart, String program, int id) => [
  ...dart,
  program,
  '$id',
];

/// `package:test/test.dart` when the package with the package configuration
/// [packageConfig] has `test`, and `test_api`, from which a driver reads
/// how a test went; else `null`.
String? testLibraryOf(String? packageConfig) {
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
  return names.contains('test') && names.contains('test_api')
      ? 'package:test/test.dart'
      : null;
}

/// The program that runs the tests of [test] (as it imports it) on a
/// mutant of [target] (as it imports it): the driver of test file number
/// [index]. It is compiled once and started once per mutant, with the
/// number of the mutant as its argument ([noMutant] for none), each time
/// as **a process of its own**.
///
/// So nothing is shared between two mutants that a start of the test
/// runner per mutant does not share either: not the program, and not what
/// a process has beside it (its id, its current directory, its exit code,
/// what native code keeps). The mutant is at work before the first line of
/// the tests and of the file under test runs.
///
/// The tests are run by `package:test` itself, as it runs a test file that
/// is started as a program: without the test runner, so without what only
/// the test runner reads (see [configObstacle] and [driverObstacle]).
///
/// **The driver writes down itself what its tests did**, one line each, at
/// the end of the file `log` in [state] (an absolute directory); see
/// [outcomeOf] for the lines. Nothing a test prints can be taken for one
/// of them, and nothing the process prints is read.
///
/// - `load` before the tests are declared and `declared` after: a test
///   file whose `main()` throws has the first and not the second.
/// - After every run of a test, when its `tearDown`s have run, `pass` or
///   `fail` with a number for the test. The test framework knows how the
///   test went so far, and the driver asks it (`Invoker` of
///   `package:test_api`, which is not part of its API; with a version in
///   which that is gone the driver does not compile, and no mutant is run
///   this way).
/// - After a test of a mutant failed for good, the other tests are not
///   run: that is all there is to know about the mutant. A test that is
///   not run is `skip`. (A test that fails and is tried again, `retry`,
///   has not failed for good.)
///
/// - When all tests have run and none has failed for good, the process is
///   ended with the exit code 0 a moment later. The test runner ends the
///   isolate of a test file when its tests have run; a program goes on for
///   as long as a test left a timer or a port behind. (When a test failed,
///   `package:test` ends the process itself, with another exit code. That
///   also happens within the moment when something failed that no test
///   saw.)
///
/// [testLibrary] is what declares `setUp` in the package.
String driverSource({
  required String testLibrary,
  required String target,
  required String test,
  required int index,
  required String state,
}) =>
    '''
// Written by dart_mutant for one run, and removed with it.
import 'dart:async';
import 'dart:io';

import ${dartString(testLibrary)};
import 'package:test_api/src/backend/invoker.dart';

import ${dartString(target)} as target;
import ${dartString(test)} as tests;

const _state = ${dartString(state)};

void _note(String what, [int? test]) => File('\$_state/log').writeAsStringSync(
  '\$what $index\${test == null ? '' : ' \$test'}\\n',
  mode: FileMode.append,
);

void main(List<String> arguments) {
  final id = int.parse(arguments.single);
  target.$switchName = id;
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
    if (id != $noMutant && failed != null && !identical(failed, test)) {
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
''';

/// The plan of the drivers for the mutants [ids]: the tests without a
/// mutant first, after every [mutantsBetweenChecks] mutants, and at the
/// end. A position of the plan is one mutant, or the tests without one.
///
/// The first run shows that the tests pass as a program of their own with
/// the mutants built in, and gives the time and the memory a run takes.
/// The later ones show that the tests still pass after the mutants before
/// them: the processes share nothing, but the files a test writes stay.
List<int> planOf(List<int> ids) => [
  noMutant,
  for (final (index, id) in ids.indexed) ...[
    id,
    if ((index + 1) % mutantsBetweenChecks == 0 || index + 1 == ids.length)
      noMutant,
  ],
];

/// Why nothing of the drivers of a file is used when a limit ended the
/// tests without a mutant.
const notEndedWithoutMutant = 'the tests did not end without a mutant';

/// Why nothing of the drivers of a file is used when the tests without a
/// mutant did not pass in them.
const notPassingWithoutMutant =
    'the tests do not pass without a mutant when they are run as a program '
    'of their own, with the mutants built in';

/// What the drivers of one position of a plan did: one process per test
/// file, in the order of the test files, until one of them failed.
class Ran {
  const Ran({required this.exitCodes, required this.notes, this.ended = false});

  /// The exit code of each process that was started and ended by itself.
  final List<int> exitCodes;

  /// What the drivers wrote down, line by line: `load`, `declared`, `pass`,
  /// `fail` or `skip`, the number of the test file, and for the last three
  /// the number of the test.
  final List<String> notes;

  /// True when a limit of time or of memory ended a process.
  final bool ended;
}

/// What is known of a position.
enum Outcome {
  /// Every test of every test file passed, on both sides.
  passed,

  /// A test failed, on both sides.
  failed,

  /// Neither: the two sides do not agree, a test file could not declare
  /// its tests, or a limit ended a process.
  undecided,
}

/// What [ran] says of a position with [tests] test files, and how many
/// tests were run in it, from two sides that have to agree:
///
/// - what the drivers wrote down: which test files declared their tests,
///   and how the last run of each test went;
/// - the exit code of each process: 0 when every test passed.
///
/// **A test failed** when a driver wrote down that it did, after declaring
/// its tests, and its process ended with another exit code than 0. A
/// failure that only one side has is none: a process that fails without a
/// test of it having failed (a `setUpAll` or `tearDownAll`, an error that
/// arrives when its test has ended, a test file that cannot declare its
/// tests, a test that ends the process), or a test that fails where the
/// process ends with 0.
///
/// **All tests passed** when every test file had its process, each ended
/// with 0 and declared its tests, and no test failed or was left out.
({Outcome outcome, int tests}) outcomeOf(Ran ran, {required int tests}) {
  final declared = <int>{};
  final last = <(int, int), String>{};
  for (final line in ran.notes) {
    final words = line.split(' ');
    final numbers = [for (final word in words.skip(1)) int.tryParse(word)];
    switch ((words.first, numbers)) {
      case ('declared', [final int file]):
        declared.add(file);
      case ('pass' || 'fail' || 'skip', [final int file, final int test]):
        last[(file, test)] = words.first;
    }
  }
  bool ended(int file) => file < ran.exitCodes.length;
  final failed = [
    for (final MapEntry(key: (file, _), value: how) in last.entries)
      if (how == 'fail' &&
          declared.contains(file) &&
          ended(file) &&
          ran.exitCodes[file] != 0)
        file,
  ];
  final clean =
      ran.exitCodes.length == tests &&
      ran.exitCodes.every((code) => code == 0) &&
      declared.length == tests &&
      last.values.every((how) => how == 'pass');
  return (
    outcome: ran.ended
        ? Outcome.undecided
        : failed.isNotEmpty
        ? Outcome.failed
        : clean
        ? Outcome.passed
        : Outcome.undecided,
    tests: last.length,
  );
}

/// What the drivers of a plan have shown so far, position by position.
///
/// A mutant counts as killed when a test failed on it ([Outcome.failed])
/// and the tests without a mutant passed afterwards. The tests without a
/// mutant passed when all of them did ([Outcome.passed]) and as many were
/// run as the first time. When they did not, nothing of the drivers is
/// used ([failure]). Every other mutant is run the usual way
/// ([DriverResult.again]).
class DriverLog {
  DriverLog(this.plan, {required this.tests});

  /// The mutant of each position, as [planOf] made it.
  final List<int> plan;

  /// How many test files a position has.
  final int tests;

  final _killed = <int, int>{};
  final _again = <int>[];

  /// The mutants a test failed on since the tests last passed without a
  /// mutant, with the milliseconds their tests took.
  var _open = <int, int>{};

  int? _testsWithoutMutant;
  var _next = 0;

  /// Why nothing of the drivers can be used, when that is so.
  String? failure;

  /// The position that is run next, or `null` when the plan is done or
  /// has failed.
  int? get next => failure == null && _next < plan.length ? _next : null;

  /// Takes what the drivers of the position [next] did, in
  /// [milliseconds].
  void add(Ran ran, {required int milliseconds}) {
    final id = plan[_next++];
    final (:outcome, tests: count) = outcomeOf(ran, tests: tests);
    if (id != noMutant) {
      if (outcome == Outcome.failed) {
        _open[id] = milliseconds;
      } else {
        _again.add(id);
      }
      return;
    }
    if (ran.ended) {
      failure = notEndedWithoutMutant;
    } else if (outcome != Outcome.passed ||
        count == 0 ||
        count != (_testsWithoutMutant ??= count)) {
      failure = notPassingWithoutMutant;
    } else {
      _killed.addAll(_open);
      _open = {};
    }
  }

  /// What is known when the drivers have run, or when the run was stopped:
  /// the mutants since the tests last passed without a mutant, and the
  /// ones that were not run, are for the usual way.
  DriverResult get result => failure != null
      ? DriverResult(failure: failure)
      : DriverResult(
          killed: _killed,
          again: [
            ..._again,
            ..._open.keys,
            for (final id in plan.skip(_next))
              if (id != noMutant) id,
          ],
        );
}

/// What the drivers of a file found out.
class DriverResult {
  const DriverResult({
    this.killed = const {},
    this.again = const [],
    this.failure,
  });

  /// The mutants a test failed on, with how long their tests took in
  /// milliseconds: the tests without a mutant passed before and after them.
  final Map<int, int> killed;

  /// The mutants that have to be run the usual way: no test failed on
  /// them, the two sides did not agree, a limit ended them, or the tests
  /// without a mutant had not passed after them.
  final List<int> again;

  /// Why nothing the drivers showed can be used, when that is so: the
  /// tests do not run this way.
  final String? failure;
}
