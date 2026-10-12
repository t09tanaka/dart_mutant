@Tags(['process'])
@Timeout(Duration(minutes: 8))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mutant/dart_mutant.dart';
import 'package:dart_mutant/src/args.dart';
import 'package:dart_mutant/src/commands/merge.dart';
import 'package:dart_mutant/src/commands/run.dart';
import 'package:dart_mutant/src/memory.dart';
import 'package:dart_mutant/src/mutation_run.dart';
import 'package:dart_mutant/src/shard.dart';
import 'package:test/test.dart';

import '../support/compiled.dart';

// A loop: `i++` → `i--` never ends, and nothing notices where it starts.
const sum = '''
int sumTo(int n) {
  var total = 0;
  for (var i = 0; i < n; i++) {
    total += i;
  }
  return total;
}
''';

const sumTest = '''
import 'package:built_in_fixture/sum.dart';
import 'package:test/test.dart';

void main() {
  test('nothing below one but zero', () => expect(sumTo(1), 0));
  test('the numbers below four', () => expect(sumTo(4), 6));
}
''';

// A loop that holds more with every round: `i++` → `i--` goes on until the
// machine has no memory left. Not here: it stops by itself at 1.2 GB, and
// the test then fails.
const hold = '''
Future<List<List<int>>> blocks(int wanted) async {
  final held = <List<int>>[];
  for (var i = 0; i < wanted; i++) {
    if (held.length == 150) {
      break;
    }
    // A million numbers: 8 MB.
    held.add(List.filled(1048576, i));
    await Future<void>.delayed(const Duration(milliseconds: 12));
  }
  return held;
}
''';

const holdTest = '''
import 'package:built_in_fixture/hold.dart';
import 'package:test/test.dart';

void main() {
  test('as many blocks as asked for', () async {
    expect(await blocks(3), hasLength(3));
  });
}
''';

const next = 'int next(int value) => value + 1;\n';

// Passes once in a process: a counter in the test file is never set back.
const nextTest = '''
import 'package:built_in_fixture/next.dart';
import 'package:test/test.dart';

var runs = 0;

void main() {
  test('the first run in a process', () {
    expect(++runs, 1);
    expect(next(1), 2);
  });
}
''';

const sign = 'int sign(int n) => n < 0 ? -1 : 1;\n';

/// The first test fails on most mutants; the others take a while and note
/// that they ran.
String signTest(String log) =>
    '''
import 'dart:io';

import 'package:built_in_fixture/sign.dart';
import 'package:test/test.dart';

void main() {
  test('below and above zero', () {
    expect(sign(-2), -1);
    expect(sign(2), 1);
  });
  for (var number = 1; number <= 6; number++) {
    test('a slow test \$number', () async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      File('$log').writeAsStringSync('x', mode: FileMode.append);
      expect(sign(number), 1);
    });
  }
}
''';

// A constant and an initializer that runs once, next to code that runs
// every time.
const lookup = '''
const names = ['zero', 'one'];
final limit = names.length + 1;
String nameOf(int n) => n < limit - 1 ? names[n] : 'many';
''';

const lookupTest = '''
import 'package:built_in_fixture/lookup.dart';
import 'package:test/test.dart';

void main() {
  test('a name', () {
    expect(nameOf(0), 'zero');
    expect(nameOf(1), 'one');
  });
  test('no name', () => expect(nameOf(2), 'many'));
}
''';

// Two decisions that each give `x` a value. A mutant that empties one
// block of the first is a program, and so is one that empties a block of
// the second; one of each in the same program leaves a way to `return x`
// on which `x` has no value, and that is not a program.
const either = '''
int either(bool a, bool b) {
  int x;
  if (a) {
    x = 1;
  } else {
    x = 2;
  }
  if (b) {
    x = 3;
  } else {
    x = 4;
  }
  return x;
}
''';

const eitherTest = '''
import 'package:built_in_fixture/either.dart';
import 'package:test/test.dart';

void main() {
  test('the second decision is the one that counts', () {
    expect(either(true, true), 3);
    expect(either(false, true), 3);
    expect(either(true, false), 4);
    expect(either(false, false), 4);
  });
}
''';

const twice = 'int twice(int n) => n * 2;\n';

const twiceTest = '''
import 'package:built_in_fixture/twice.dart';
import 'package:test/test.dart';

Future<void> main() async {
  test('twice', () => expect(twice(2), 4));
}
''';

// What is declared depends on the code under test.
const cases = 'List<int> cases() => [1, 2, 3];\n';

const casesTest = '''
import 'package:built_in_fixture/cases.dart';
import 'package:test/test.dart';

void main() {
  if (cases().isEmpty) {
    throw StateError('no cases');
  }
  for (final number in cases()) {
    test('case \$number', () => expect(number, lessThan(4)));
  }
}
''';

// A result that is kept for the life of the process.
const square = '''
final _known = <num, num>{};
num square(num n) => _known.putIfAbsent(n, () => n * n);
''';

const squareTest = '''
import 'package:built_in_fixture/square.dart';
import 'package:test/test.dart';

void main() {
  test('square', () => expect(square(3), 9));
}
''';

// Two test files, of which the second only passes after the first, in the
// same process.
const pair = '''
bool? ready;
int half(int n) => n ~/ 2;
''';

const pairFirstTest = '''
import 'package:built_in_fixture/pair.dart';
import 'package:test/test.dart';

void main() {
  test('half', () {
    ready = true;
    expect(half(4), 2);
  });
}
''';

const pairSecondTest = '''
import 'package:built_in_fixture/pair.dart';
import 'package:test/test.dart';

void main() {
  test('after the other file', () {
    expect(ready, isTrue);
    expect(half(8), 4);
  });
}
''';

/// A run with the mutants of a file built in, its tests compiled once and
/// each mutant run by a process of its own, with the real `dart`, on a
/// package in a temporary directory. That every mutant has the status
/// of a start of its own is the subject of test/commands/hazards_test.dart.
void main() {
  late Directory dir;
  late String slowLog;
  final out = <String>[];
  final err = <String>[];

  void write(String path, String content) => File('${dir.path}/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  setUpAll(() {
    dir = Directory(
      Directory.systemTemp
          .createTempSync('dart_mutant_built_in_')
          .resolveSymbolicLinksSync(),
    );
    slowLog = '${dir.path}/slow.log';
    write('pubspec.yaml', '''
name: built_in_fixture
publish_to: none
environment:
  sdk: ^3.11.0
dev_dependencies:
  test: ^1.27.0
''');
    write('lib/sum.dart', sum);
    write('test/sum_test.dart', sumTest);
    write('lib/hold.dart', hold);
    write('test/hold_test.dart', holdTest);
    write('lib/next.dart', next);
    write('test/next_test.dart', nextTest);
    write('lib/sign.dart', sign);
    write('test/sign_test.dart', signTest(slowLog));
    write('lib/lookup.dart', lookup);
    write('test/lookup_test.dart', lookupTest);
    write('lib/either.dart', either);
    write('test/either_test.dart', eitherTest);
    write('lib/twice.dart', twice);
    write('test/twice_test.dart', twiceTest);
    write('lib/cases.dart', cases);
    write('test/cases_test.dart', casesTest);
    write('lib/pair.dart', pair);
    write('test/pair_first_test.dart', pairFirstTest);
    write('test/pair_second_test.dart', pairSecondTest);
    write(
      'pair.json',
      jsonEncode({
        'version': 1,
        'targets': [
          {
            'file': 'lib/pair.dart',
            'tests': [
              'test/pair_first_test.dart',
              'test/pair_second_test.dart',
            ],
          },
        ],
      }),
    );
    write('lib/square.dart', square);
    write('test/square_test.dart', squareTest);
    // The packages are in the cache: this package depends on `test` too.
    final pubGet = Process.runSync(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: dir.path);
    expect(pubGet.exitCode, 0, reason: '${pubGet.stdout}${pubGet.stderr}');
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  setUp(() {
    out.clear();
    err.clear();
  });

  /// Every file of the package outside `.dart_tool` and `reports`, with its
  /// content.
  Map<String, String> tree() => {
    for (final entity in dir.listSync(recursive: true))
      if (entity is File &&
          !entity.path.contains('/.dart_tool/') &&
          !entity.path.contains('/reports/') &&
          entity.path != slowLog)
        entity.path: entity.readAsStringSync(),
  };

  /// Runs the mutation test of [file] and returns its mutants as
  /// `Mutator replacement: Status`.
  Future<List<String>> mutate(
    String file, {
    required bool schemata,
    int jobs = 2,
    bool force = true,
    Duration Function(Duration baseline)? limit,
    int Function(int baseline)? memory,
    Shard? shard,
    String? reportPath,
    String? plan,
  }) async {
    final before = tree();
    await runMutation(
      RunArgs(
        dir: dir.path,
        targets: plan == null ? [file] : const [],
        plan: plan,
        force: force,
        jobs: jobs,
        schemata: schemata,
        shard: shard,
        report: reportPath,
        command: [Platform.resolvedExecutable, 'test'],
      ),
      Io(out: out.add, err: err.add),
      limitOf: limit ?? processLimit,
      memoryLimitOf: memory ?? memoryLimit,
    );
    expect(tree(), before, reason: 'the package was changed');
    expect(Directory('${dir.path}/$stateDir/work').existsSync(), isFalse);
    final report =
        jsonDecode(
              File(
                reportPath ?? '${dir.path}/reports/mutation/mutation.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final mutants =
        ((report['files']! as Map<String, Object?>)[file]
                as Map<String, Object?>?)?['mutants']
            as List? ??
        const [];
    final found = [
      for (final mutant in mutants.cast<Map<String, Object?>>())
        '${mutant['mutatorName']} '
            '${(mutant['replacement']! as String).replaceAll(RegExp(r'\s+'), ' ')}: '
            '${mutant['status']}',
    ];
    return found;
  }

  String builtInLine(String file) => out.firstWhere(
    (line) =>
        line.contains('$file:') &&
        line.contains('killed with the mutants built in'),
    orElse: () => '',
  );

  test('a mutant that never ends does not hold the others: the test run is '
      'ended, the mutant is measured the usual way, and another one runs '
      'the rest', () async {
    // Whatever a run without a mutant takes on this machine, and a little:
    // the loop that never ends is over that as well.
    final builtIn = await mutate(
      'lib/sum.dart',
      schemata: true,
      limit: (baseline) => baseline + const Duration(seconds: 8),
    );
    expect(builtIn, [
      'ConditionalExpression false: Killed',
      'EqualityOperator <=: Killed',
      'EqualityOperator >=: Killed',
      'UpdateOperator --: Timeout',
      'BlockStatement {}: Killed',
      'AssignmentOperator -=: Killed',
      'NumberLiteral 1: Killed',
      // Where the loop starts makes no difference to the sum.
      'NumberLiteral 1: Survived',
    ]);
    expect(
      out,
      contains(
        matches(
          r'^  lib/sum\.dart: \d+ of \d+ mutant\(s\) built in, each run '
          r'by a process of its own, with ".*dart <the tests, compiled '
          r'once> <mutant>"',
        ),
      ),
    );
    expect(
      builtInLine('lib/sum.dart'),
      matches(
        r'^  lib/sum\.dart: \d+ killed with the mutants built in; \d+ not '
        r'killed that way get a start of their own; 1 of them did not '
        r'end, and were ended$',
      ),
    );
    expect(err, [
      'dart_mutant run: 1 surviving mutant(s)',
      '  - lib/sum.dart:3:16 / NumberLiteral / 0 → 1 (Survived)',
      startsWith('dart_mutant run: FAILED ('),
    ]);
  });

  test('a mutant that takes more and more memory does not take the machine: '
      'the driver is ended, the mutant is measured the usual way, where it '
      'is ended as well, and another driver runs the rest', () async {
    // Whatever a run without a mutant holds on this machine, and 400 MB:
    // the loop that never stops holding is over that within a second.
    final builtIn = await mutate(
      'lib/hold.dart',
      schemata: true,
      memory: (baseline) => baseline + 400 * 1024,
    );
    expect(builtIn.where((mutant) => !mutant.contains('NumberLiteral')), [
      'ConditionalExpression false: Killed',
      'EqualityOperator <=: Killed',
      'EqualityOperator >=: Killed',
      'UpdateOperator --: Timeout',
      'BlockStatement {}: Killed',
      'ConditionalExpression true: Killed',
      // The loop is over before it holds that much.
      'ConditionalExpression false: Survived',
      'EqualityOperator !=: Killed',
      'BlockStatement {}: Survived',
      'RemoveCall ;: Killed',
    ]);
    expect(builtIn.where((mutant) => mutant.endsWith('Timeout')), hasLength(1));
    final written = '${dir.path}/reports/mutation/mutation.json';
    final report = File(written).readAsStringSync();
    expect(
      RegExp(
        r'"status":\s*"Timeout",\s*"statusReason":\s*"the test run used more than '
        r'\d+ MB of memory and was ended"',
      ).allMatches(report),
      hasLength(1),
    );
    expect(RegExp('"statusReason"').allMatches(report), hasLength(1));
    expect(
      builtInLine('lib/hold.dart'),
      matches(
        r'^  lib/hold\.dart: \d+ killed with the mutants built in; \d+ not '
        r'killed that way get a start of their own; 1 of them used too '
        r'much memory, and were ended$',
      ),
    );
    expect(
      out,
      contains(
        matches(
          r'^  lib/hold\.dart: 1 mutant\(s\) used more than \d+ MB of '
          r'memory, were ended and run again alone: 1 reached a limit then '
          r'as well \(Timeout\)$',
        ),
      ),
    );
  }, testOn: '!windows');

  test('tests that pass only once in an isolate: every mutant has an '
      'isolate of its own, as with a start of the test runner of its '
      'own', () async {
    final builtIn = await mutate('lib/next.dart', schemata: true);
    expect(builtIn, [
      'ArithmeticOperator -: Killed',
      'NumberLiteral 2: Killed',
      'NumberLiteral 0: Killed',
    ]);
    expect(err, isEmpty);
    expect(
      builtInLine('lib/next.dart'),
      '  lib/next.dart: 3 killed with the mutants built in',
    );
  });

  test('without the option the statuses are the same', () async {
    expect(await mutate('lib/sign.dart', schemata: false), [
      'ConditionalExpression true: Killed',
      'ConditionalExpression false: Killed',
      'EqualityOperator <=: Survived',
      'EqualityOperator >=: Killed',
      'UnaryOperator 1: Killed',
      'NumberLiteral 1: Survived',
      'NumberLiteral 2: Killed',
      'NumberLiteral 0: Killed',
      'NumberLiteral 2: Killed',
      'NumberLiteral 0: Killed',
    ]);
    expect(out.where((line) => line.contains('built in')), isEmpty);
  });

  test('the tests of a mutant are not run after the first one that '
      'fails', () async {
    int slowTests() {
      final file = File(slowLog);
      final count = file.existsSync() ? file.readAsStringSync().length : 0;
      if (file.existsSync()) {
        file.deleteSync();
      }
      return count;
    }

    slowTests();
    final builtIn = await mutate('lib/sign.dart', schemata: true, jobs: 1);
    expect(builtIn, [
      'ConditionalExpression true: Killed',
      'ConditionalExpression false: Killed',
      // No test has zero.
      'EqualityOperator <=: Survived',
      'EqualityOperator >=: Killed',
      'UnaryOperator 1: Killed',
      'NumberLiteral 1: Survived',
      'NumberLiteral 2: Killed',
      'NumberLiteral 0: Killed',
      'NumberLiteral 2: Killed',
      'NumberLiteral 0: Killed',
    ]);
    final killed = int.parse(
      RegExp(
        r'(\d+) killed with',
      ).firstMatch(builtInLine('lib/sign.dart'))!.group(1)!,
    );
    expect(killed, 8);
    final measuredAgain = builtIn.length - killed;
    // The tests without a mutant twice in the driver and once in each of
    // the two runs that give the usual way its time limit, and all of them
    // once more for every mutant that is measured again. A killed mutant
    // gets to the slow test that had started before the failure was known,
    // at most.
    final most = 6 * 2 + 6 * 2 * measuredAgain + 2 * killed;
    expect(slowTests(), lessThanOrEqualTo(most));
    expect(most, lessThan(6 * 2 + 6 * builtIn.length));
  });

  test('what cannot be built in is run the usual way, and the rest is '
      'built in: also the initializer of a top-level variable, which runs '
      'once in an isolate', () async {
    final builtIn = await mutate('lib/lookup.dart', schemata: true);
    expect(builtIn, hasLength(14));
    expect(builtIn, everyElement(endsWith(': Killed')));
    expect(
      out,
      contains(startsWith('  lib/lookup.dart: 11 of 14 mutant(s) built')),
    );
    expect(
      builtInLine('lib/lookup.dart'),
      '  lib/lookup.dart: 11 killed with the mutants built in; 3 cannot be '
      'built in (3 in a constant)',
    );
  });

  test('mutants that each compile in the program, but not together, are '
      'left out of it and run the usual way', () async {
    final usual = await mutate('lib/either.dart', schemata: false);
    out.clear();
    final builtIn = await mutate('lib/either.dart', schemata: true);
    expect(builtIn, usual);
    // The emptied blocks: what the first decision gives `x` is never
    // read, and the tests notice each block of the second, which are the
    // two that are not built in.
    expect(builtIn.where((mutant) => mutant.startsWith('BlockStatement ')), [
      'BlockStatement {}: Survived',
      'BlockStatement {}: Survived',
      'BlockStatement {}: Killed',
      'BlockStatement {}: Killed',
    ]);
    expect(
      out,
      contains(startsWith('  lib/either.dart: 14 of 16 mutant(s) built')),
    );
    expect(
      builtInLine('lib/either.dart'),
      matches(
        r'^  lib/either\.dart: \d+ killed with the mutants built in; '
        r'2 cannot be built in \(2 does not compile together with the '
        r'other mutants\)',
      ),
    );
  });

  test('tests the driver cannot call are run the usual way', () async {
    final builtIn = await mutate('lib/twice.dart', schemata: true);
    expect(builtIn, [
      'ArithmeticOperator /: CompileError',
      'NumberLiteral 3: Killed',
      'NumberLiteral 1: Killed',
    ]);
    expect(
      err,
      contains(
        'dart_mutant run: lib/twice.dart has a test (test/twice_test.dart) that '
        'has a main() that is async; each of its mutants gets a start of '
        'the test runner of its own',
      ),
    );
    expect(out.where((line) => line.contains('built in')), isEmpty);
  });

  test('a mutant is at work while the tests are declared; tests that '
      'cannot be declared with it are no failing test, and that mutant is '
      'measured the usual way', () async {
    final builtIn = await mutate('lib/cases.dart', schemata: true);
    expect(builtIn, [
      // main() throws: the test file cannot be loaded.
      'ArrayDeclaration []: Killed',
      'NumberLiteral 2: Survived',
      'NumberLiteral 0: Survived',
      'NumberLiteral 3: Survived',
      'NumberLiteral 1: Survived',
      // The case 4 is declared with the mutant, and fails.
      'NumberLiteral 4: Killed',
      'NumberLiteral 2: Survived',
    ]);
    expect(
      builtInLine('lib/cases.dart'),
      '  lib/cases.dart: 1 killed with the mutants built in; 6 not killed '
      'that way get a start of their own',
    );

    // The results are those of any run: the next one takes them over.
    out.clear();
    err.clear();
    expect(
      await mutate('lib/cases.dart', schemata: true, force: false),
      builtIn,
    );
    expect(out, [
      matches(r'^  lib/cases\.dart: 7 mutants / .* \(7 from the last run, '),
    ]);
    expect(err, [
      'dart_mutant run: 5 surviving mutant(s)',
      ...List.filled(5, endsWith(' (Survived)')),
      startsWith('dart_mutant run: FAILED (7 mutants / killed 2 / survived 5 '),
    ]);
  });

  test('what an isolate keeps hides no mutant: every mutant is at work '
      'from the start of an isolate of its own', () async {
    final builtIn = await mutate('lib/square.dart', schemata: true);
    expect(builtIn, ['ArithmeticOperator /: Killed']);
    expect(
      builtInLine('lib/square.dart'),
      '  lib/square.dart: 1 killed with the mutants built in',
    );
  });

  test(
    'a file with two test files is not built in: the test runner runs '
    'them in one process, and each of its mutants gets a start of its '
    'own (here the tests only pass together, and fail that way too)',
    () async {
      final builtIn = await mutate(
        'lib/pair.dart',
        schemata: true,
        plan: '${dir.path}/pair.json',
      );
      // As with --one-by-one: the file is not in the report.
      expect(builtIn, isEmpty);
      expect(builtInLine('lib/pair.dart'), isEmpty);
      expect(
        err,
        containsAllInOrder([
          'dart_mutant run: lib/pair.dart has more than one test file, which '
              'share a process when the test runner runs them; each of its '
              'mutants gets a start of the test runner of its own',
          startsWith(
            'dart_mutant run: lib/pair.dart has tests that fail in a ',
          ),
          'dart_mutant run: 1 file(s) could not be mutation tested',
          startsWith('  - lib/pair.dart: the tests fail without a mutant'),
        ]),
      );
    },
  );

  test('with --shard each part builds in its own mutants, and the parts '
      'put together are the run that was not divided', () async {
    final whole = await mutate('lib/sign.dart', schemata: true);
    final parts = <String>[];
    for (final index in [1, 2]) {
      out.clear();
      final part = '${dir.path}/reports/part$index.json';
      parts.add(part);
      final statuses = await mutate(
        'lib/sign.dart',
        schemata: true,
        shard: Shard(index, 2),
        reportPath: part,
      );
      expect(statuses, [
        for (final (number, status) in whole.indexed)
          number % 2 == index - 1
              ? status
              : '${status.substring(0, status.lastIndexOf(': '))}: Pending',
      ]);
      // Five mutants each: all of them compile and are built in, and the
      // one no test fails on is measured the usual way.
      expect(
        out,
        contains(startsWith('  lib/sign.dart: 5 of 10 mutant(s) built in,')),
      );
      expect(
        builtInLine('lib/sign.dart'),
        '  lib/sign.dart: 4 killed with the mutants built in; 1 not killed '
        'that way get a start of their own',
      );
    }
    final merged = '${dir.path}/reports/merged.json';
    expect(
      runMerge(
        MergeArgs(parts: parts, report: merged),
        Io(out: out.add, err: err.add),
      ),
      1,
      reason: 'two mutants survive',
    );
    String statusesOf(String path) => jsonEncode([
      for (final mutant
          in (((jsonDecode(File(path).readAsStringSync())
                          as Map<String, Object?>)['files']!
                      as Map<String, Object?>)['lib/sign.dart']!
                  as Map<String, Object?>)['mutants']!
              as List)
        [
          (mutant as Map<String, Object?>)['id'],
          mutant['mutatorName'],
          mutant['replacement'],
          mutant['location'],
          mutant['status'],
        ],
    ]);
    await mutate('lib/sign.dart', schemata: false);
    expect(
      statusesOf(merged),
      statusesOf('${dir.path}/reports/mutation/mutation.json'),
    );
  });

  group('interrupted', () {
    late CompiledCommandLine compiled;

    setUpAll(() => compiled = CompiledCommandLine());
    tearDownAll(() => compiled.delete());

    test('SIGINT while a driver runs: the driver is ended, the package is '
        'as it was, the working copies are gone', () async {
      final before = tree();
      final process = await Process.start(Platform.resolvedExecutable, [
        ...compiled.arguments,
        'run',
        '--force',
        'lib/sum.dart',
      ], workingDirectory: dir.path);
      final errors = process.stderr.transform(systemEncoding.decoder).join();
      final lines = StreamIterator(
        process.stdout
            .transform(systemEncoding.decoder)
            .transform(const LineSplitter()),
      );
      while (await lines.moveNext()) {
        if (lines.current.contains('built in, each run by')) {
          break;
        }
      }
      // The driver is compiled and started, and gets to the mutant that
      // never ends.
      final driver = File(
        '${dir.path}/$stateDir/work/1/.dart_tool/dart_mutant_driver/driver_0.dart',
      );
      while (!driver.existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(tree(), before);
      process.kill(ProcessSignal.sigint);
      expect(await process.exitCode, 130);
      await lines.cancel();
      expect(
        await errors,
        contains(
          'dart_mutant run: interrupted. No file of the package was changed',
        ),
      );
      expect(tree(), before);
      expect(Directory('${dir.path}/$stateDir/work').existsSync(), isFalse);
      expect(
        File('${dir.path}/reports/mutation/mutation.json').existsSync(),
        isFalse,
      );
    }, testOn: '!windows');
  });
}
