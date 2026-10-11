import 'dart:convert';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'json.dart';
import 'mutation_run.dart';
import 'schemata.dart';

/// How many mutants are run between two runs of the tests without a mutant
/// (see [planOf]).
const mutantsBetweenChecks = 25;

/// The name of the test file that runs the tests of a file once per mutant.
const driverName = 'dart_mutant_driver_test.dart';

/// What the names of the groups of the driver start with.
const _marker = 'dart_mutant';

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

/// Why the test files [tests] (path → source) cannot be run by one driver,
/// or `null` when they can. The driver is put next to them, so that what the
/// test runner does for a directory (`flutter_test_config.dart`, the place
/// of golden files) is done for it; they have to be in one directory, in
/// which no file has the name of the driver ([taken]).
String? testsObstacle(Map<String, String> tests, {required bool taken}) {
  if ({for (final test in tests.keys) directoryOf(test)}.length != 1) {
    return 'has tests in more than one directory';
  }
  if (taken) {
    return 'has a file called $driverName next to its tests';
  }
  for (final MapEntry(key: path, value: source) in tests.entries) {
    final obstacle = driverObstacle(source);
    if (obstacle != null) {
      return 'has a test ($path) that $obstacle';
    }
  }
  return null;
}

/// Where the driver of the test files [tests] is put: next to them.
String driverPathOf(List<String> tests) {
  final directory = directoryOf(tests.first);
  return directory.isEmpty ? driverName : '$directory/$driverName';
}

/// [command] for the driver [driver]: a test gets the time it gets the
/// usual way, and the results are reported as JSON, test by test. The run
/// is not ended at the first failing test: that is the test of one mutant.
List<String> driverCommand(List<String> command, String driver) => [
  ...command,
  '--timeout',
  '${perTestTimeoutSeconds}s',
  '--reporter',
  'json',
  driver,
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

/// The test file that runs [tests] (as it imports them) once per mutant of
/// [target] (as it imports it), in one process.
///
/// It reads its plan from the file `plan` in [state] (an absolute
/// directory): one number per line, the mutant that is at work while the
/// tests are declared and run once more, [noMutant] for a run without one.
/// Every such run is a group that is called `dart_mutant#<position>#<id>`.
///
/// - Before the tests of a position are declared, the position is added to
///   the file `declared`: declaring them can already be what never ends.
/// - A test is not run when the file `killed/<id>` is there: an earlier
///   test of that mutant failed, which is all there is to know about it.
/// - Tests that cannot be declared with a mutant at work (`main()` throws)
///   are one failing test.
///
/// [testLibrary] is what declares `group` and `test` in the package:
/// `package:test/test.dart` or `package:flutter_test/flutter_test.dart`.
String driverSource({
  required String testLibrary,
  required String target,
  required List<String> tests,
  required String state,
}) =>
    '''
// Written by dart_mutant for one run, and removed with it.
import 'dart:io';

import ${dartString(testLibrary)};

import ${dartString(target)} as target;
${[for (final (index, test) in tests.indexed) 'import ${dartString(test)} as tests$index;'].join('\n')}

const _state = ${dartString(state)};

void main() {
  final plan = File('\$_state/plan').readAsLinesSync().map(int.parse).toList();
  for (final (position, id) in plan.indexed) {
    group('$_marker#\$position#\$id', () {
      setUpAll(() => target.$switchName = id);
      setUp(() {
        target.$switchName = id;
        if (id != $noMutant && File('\$_state/killed/\$id').existsSync()) {
          throw StateError('$_marker: not run, a test before it failed');
        }
      });
      tearDownAll(() => target.$switchName = $noMutant);
      File('\$_state/declared').writeAsStringSync(
        '\$position\\n',
        mode: FileMode.append,
        flush: true,
      );
      target.$switchName = id;
      try {
${[for (final index in Iterable<int>.generate(tests.length)) '        tests$index.main();'].join('\n')}
      } catch (error, stack) {
        test(
          '$_marker: the tests cannot be declared',
          () => Error.throwWithStackTrace(error, stack),
        );
      } finally {
        target.$switchName = $noMutant;
      }
    });
  }
}
''';

/// The plan of a driver for the mutants [ids]: the tests without a mutant
/// first, after every [mutantsBetweenChecks] mutants, and at the end.
///
/// The first run shows that the tests pass with the mutants built in, and
/// initializes what is initialized once in a process while no mutant is at
/// work. The later ones show that the tests still pass after the mutants
/// before them: a mutant can leave something behind in the process (a
/// variable, a cache, a timer) that fails the tests of the next ones.
List<int> planOf(List<int> ids) => [
  noMutant,
  for (final (index, id) in ids.indexed) ...[
    id,
    if ((index + 1) % mutantsBetweenChecks == 0 || index + 1 == ids.length)
      noMutant,
  ],
];

/// Why nothing of a driver is used when it was ended while the tests ran
/// without a mutant.
const notEndedWithoutMutant = 'the tests did not end without a mutant';

final _group = RegExp('^$_marker#(\\d+)#(-?\\d+)(?: |\$)');

/// What a driver has reported so far: the lines of the JSON reporter of the
/// test runner, and the positions it noted before declaring their tests.
class DriverLog {
  DriverLog(this.plan);

  /// The mutant of each position, as [planOf] made it.
  final List<int> plan;

  final _positionOfTest = <int, int>{};
  final _nameOfTest = <int, String>{};

  /// The first test that failed without a mutant at work, as the test files
  /// call it.
  String? failedWithoutMutant;

  /// The positions of which a test has started, and when the first one did
  /// (milliseconds since the start of the test runner).
  final started = <int, int>{};

  /// The positions with a test that failed.
  final failed = <int>{};

  /// How many tests of each position have passed.
  final passed = <int, int>{};

  /// True when the test runner said it has run everything.
  var done = false;

  /// True when the driver could not be loaded: it does not compile, or
  /// `main()` threw.
  var loadFailed = false;

  /// The position whose tests were being declared last, or `null` before
  /// the first.
  int? declaring;

  /// The time of the last line (milliseconds since the start of the test
  /// runner).
  var time = 0;

  /// The position that is at work: the one of the test that started last,
  /// or, while none has started, the one that is being declared.
  int? get current => started.isEmpty ? declaring : started.keys.last;

  /// Takes what the driver noted in its file `declared` ([text], all of it).
  void declared(String text) {
    final lines = text.trim().split('\n');
    declaring = int.tryParse(lines.last) ?? declaring;
  }

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
      case 'testStart':
        final test = asObject(event['test']);
        final id = test?['id'];
        final name = test?['name'];
        final match = name is String ? _group.firstMatch(name) : null;
        if (id is int && match != null) {
          final position = int.parse(match.group(1)!);
          if (position < plan.length &&
              plan[position] == int.parse(match.group(2)!)) {
            _positionOfTest[id] = position;
            _nameOfTest[id] = match.input.substring(match.end);
            started.putIfAbsent(position, () => time);
          }
        }
      case 'testDone':
        final position = _positionOfTest[event['testID']];
        if (event['result'] == 'success') {
          if (position != null) {
            passed.update(position, (count) => count + 1, ifAbsent: () => 1);
          }
          return null;
        }
        if (position == null) {
          // The test that loads the file, or one outside every group.
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

  /// How long the tests of [position] took, in milliseconds: from its first
  /// test to the first test of the next position that has one, or to the
  /// last line.
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
  /// The first run of the tests, without a mutant, takes the place of the
  /// run without a mutant of the usual way, and what comes before it is the
  /// compiler's time and the test runner's: they get [first]. Every later
  /// position gets what [limitOf] makes of the time of that first run;
  /// declaring the tests of one, which is done before any test runs, gets
  /// what it makes of nothing.
  Duration limit(
    Duration Function(Duration baseline) limitOf, {
    required Duration first,
  }) {
    if (started.isEmpty) {
      // After the last one the test runner takes the declared tests over,
      // which is its time as well.
      final at = declaring ?? 0;
      return at > 0 && at < plan.length - 1 ? limitOf(Duration.zero) : first;
    }
    return started.length < 2
        ? first
        : limitOf(Duration(milliseconds: millisecondsOf(0)));
  }

  var _memoryWithoutMutant = 0;

  /// How much memory the driver may hold now, in kilobytes, when the most
  /// it has held so far is [peak], or `null` for as much as it takes.
  ///
  /// While the first position is at work (the tests without a mutant are
  /// declared, or run, for the first time, and before that the compiler is
  /// at work) there is no limit, and [peak] is what a run without a mutant
  /// takes. Every later position gets what [limitOf] makes of that.
  int? memoryLimit(int peak, int Function(int baseline) limitOf) {
    final at = current;
    if (at == null || at == 0) {
      _memoryWithoutMutant = peak;
      return null;
    }
    return limitOf(_memoryWithoutMutant);
  }

  /// Takes it that the driver was ended before it had run everything: a
  /// test runner that is told to end still says that it is done.
  void ended() {
    done = false;
  }

  /// What is known when the driver has ended, or was ended.
  ///
  /// A mutant counts as killed when a test failed on it and the tests
  /// without a mutant passed afterwards. Everything else is not decided
  /// here: it is run the usual way ([DriverResult.again]) or by the next
  /// driver ([DriverResult.rest]).
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
        // Where the driver was when it ended.
        break;
      }
      if (started.isEmpty) {
        // Declared only. No test was run.
        continue;
      }
      if (id != noMutant) {
        open.add(position);
      } else if (failed.contains(position) ||
          passed[0] == null ||
          passed[position] != passed[0]) {
        // A test failed, or other tests were run than the first time: not
        // all of them, or none.
        return DriverResult(
          failure:
              'the tests do not pass without a mutant when they are run '
              'more than once in one process'
              '${failedWithoutMutant == null ? '' : ' ("$failedWithoutMutant" fails)'}',
        );
      } else {
        for (final passed in open) {
          if (failed.contains(passed)) {
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

/// What a driver found out.
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
  /// them, their tests did not end, or the driver ended before the tests
  /// without a mutant had passed after them.
  final List<int> again;

  /// The mutants the driver did not get to: for the next driver.
  final List<int> rest;

  /// Why nothing the driver reported can be used, when that is so: the
  /// tests do not run this way.
  final String? failure;
}
