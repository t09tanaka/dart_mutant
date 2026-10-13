@Tags(['process', 'hazards'])
@Timeout(Duration(minutes: 15))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mutant/dart_mutant.dart';
import 'package:dart_mutant/src/args.dart';
import 'package:dart_mutant/src/commands/run.dart';
import 'package:dart_mutant/src/driver.dart';
import 'package:test/test.dart';

/// The condition under which a mutant may be run in another way than by a
/// start of the test runner of its own: for a package of tests that are
/// easy to get wrong (test/fixtures/hazards), **every mutant has the status
/// that a start of the test runner of its own gives it**.
///
/// By default the tests of a file are compiled once with its mutants built
/// in, and every mutant is run by a process of its own.
///
/// The files, and what each is there for:
///
/// - `registry`, `counter`: the tests leave something behind in their
///   isolate, and the code under test is what clears it. `--schemata` of
///   0.1.0 ran every mutant in one isolate, where the mutant that empties
///   the clearing code failed on what the round before had left, and was
///   reported as killed. It was withdrawn in 0.1.1 for that.
/// - `background`: code that runs in another isolate, where no mutant is
///   at work.
/// - `codec`: a test that compares what the code under test says here and
///   in another isolate, which a file starts that is neither the file
///   under test nor its test. `shout`: the same with another process. A
///   mutant that is written into the file is at work on both sides; one
///   that is built in would be at work on one, and fail the test.
/// - `cli`: a test that leaves the exit code of the process behind when it
///   fails, and a later one that puts it back.
/// - `gate`: a `setUpAll` that fails with a mutant.
/// - `scales`: a top-level variable and a static field that are computed
///   once, and tests that are declared from the code under test, so that a
///   mutant changes how many there are.
/// - `pending`: a test that leaves a timer running and a future
///   unfinished, and a later test that relies on them.
/// - `lease`: a `tearDown` that throws when its `setUp` did not run.
/// - `place`: a test that changes the current directory, which the
///   isolates of a process share, and does not change it back.
/// - `pair`: a file with two test files, each with a state of its own.
///   `share`: two test files of which one changes the current directory,
///   which the other then sees in the process they share under the test
///   runner. With a process each, the mutant that makes the second one look
///   there fails it. A file with more than one test file is not run by
///   processes of its own for that.
/// - `diag`: a test that prints the form of a compiler error when it
///   fails, which a start of the test runner is read as a mutant that does
///   not compile. A failure with such output is not believed.
/// - `whoami`: code that asks for the name of its isolate, which is another
///   one in a program of its own than under the test runner.
/// - `outside`: what fails outside the body of a test, each by a mutant of
///   its own: while the tests are declared, in a `tearDownAll`, in a
///   future nobody waits for, when the test has ended, a callback that is
///   never called (the test waits until its time is up), and a test that
///   passes when it is tried again (`retry`).
/// - `halt`: a mutant that ends the process of its tests.
/// - `ledger`: what the tests leave behind is in a file that belongs to
///   their process (its id is in the name), and the code under test is
///   what clears it. Mutants that share a process, each in an isolate of
///   its own, share that file: the mutant that empties the clearing code
///   was killed there by what the mutant before it had left.
/// - `spool`: what is not run after a test failed, and leaves a file in the
///   package when it is: a `tearDown` that writes a note when its `setUp`
///   did not run, and the `setUpAll` of a later group, whose test takes
///   away what it puts there. The mutants that count such a file fail on
///   it, and on nothing a start of the test runner with `--fail-fast`
///   leaves.
typedef _Run = ({
  Map<String, List<String>> mutants,
  int exitCode,
  List<String> lines,
});

void main() {
  late Directory dir;
  late _Run usual;
  late _Run together;

  /// How many test runs each of the two runs starts at a time: 2, or what
  /// `HAZARDS_JOBS` says (tool/quick_check.sh and CI, where there are cores
  /// to spare).
  final jobs = Platform.environment['HAZARDS_JOBS'] ?? '2';

  const files = [
    'registry',
    'counter',
    'background',
    'scales',
    'pending',
    'lease',
    'place',
    'pair',
    'codec',
    'shout',
    'cli',
    'gate',
    'outside',
    'halt',
    'ledger',
    'spool',
    'share',
    'diag',
    'whoami',
  ];

  /// The files with more than one test file, and their test files.
  const several = {
    'pair': ['pair_first_test', 'pair_second_test'],
    'share': ['share_first_test', 'share_second_test'],
  };

  /// How the mutants of each file that are built in have to go: how many
  /// there are, how many of them are killed by a process of their own, and
  /// how many are left for a start of the test runner, as the run says it.
  /// A file that is given up has no such line, and says why.
  ///
  /// Both directions are held: a file that should be given up is, and a
  /// file that need not be is not run with a start per mutant after all.
  const shared = <String, String>{
    'registry': '2 of 2 built in, 1 killed there, 1 left',
    'counter': '6 of 6 built in, 4 killed there, 2 left',
    // Two of them never end: they are ended, and left.
    'scales': '55 of 59 built in, 45 killed there, 10 left',
    'pending': '12 of 13 built in, 9 killed there, 3 left',
    'lease': '14 of 14 built in, 13 killed there, 1 left',
    'place': '2 of 2 built in, 2 killed there, 0 left',
    'cli': '17 of 17 built in, 12 killed there, 5 left',
    // Its setUpAll fails with two of them: the process fails, and no test
    // of it was written down as failed.
    'gate': '4 of 5 built in, 2 killed there, 2 left',
    // Killed there: the error nobody waits for, and the count that goes
    // down. Left: what fails while the tests are declared, in the
    // tearDownAll and when its test has ended, the callback that is never
    // called (its test waits longer than the process may take), and the
    // one survivor.
    'outside': '12 of 12 built in, 3 killed there, 9 left',
    // The mutants that end the process end it with 0: no test failed.
    'halt': '8 of 9 built in, 2 killed there, 6 left',
    'ledger': '7 of 7 built in, 4 killed there, 3 left',
    // Left: the two that are the same program as the original, and the six
    // that would fail on a file that is not left.
    'spool': '40 of 40 built in, 32 killed there, 8 left',
    // Every failure of it is printed in the form of a compiler error.
    'diag': '4 of 4 built in, 0 killed there, 4 left',
  };

  /// Files with fewer mutants than are built in ([mutantsToBuildIn]), and how
  /// many of each compile: without the 0 of the run above they are run as
  /// with `--one-by-one`.
  const fewMutants = {'registry': 2, 'place': 2, 'gate': 4};
  final givenUp = {
    for (final name in ['background', 'codec', 'shout'])
      name:
          'dart_mutant run: lib/$name.dart: code of the file ran in another '
          'isolate or process than the tests, where no mutant is at work; '
          'each of its mutants gets a start of the test runner of its own',
    for (final name in several.keys)
      name:
          'dart_mutant run: lib/$name.dart has more than one test file, which '
          'share a process when the test runner runs them; each of its '
          'mutants gets a start of the test runner of its own',
    'whoami':
        'dart_mutant run: lib/whoami.dart asks which program runs it '
        '(debugName); each of its mutants gets a start of the test runner of '
        'its own',
  };

  /// The mutants that would be killed by mistake if they shared an isolate
  /// or a process, or were at work on one side only, each for the reason
  /// its file is there for. A start of their own lets them
  /// survive, and that is the result.
  const survivors = [
    // Empties the code that clears what the tests leave behind.
    'lib/registry.dart#0 BlockStatement {} 4:19-6:2',
    'lib/counter.dart#0 BlockStatement {} 4:16-6:4',
    // At work on both sides of a comparison across isolates, and across
    // processes.
    'lib/codec.dart#? NumberLiteral 4 1:33-1:34',
    'lib/codec.dart#? NumberLiteral 2 1:33-1:34',
    'lib/shout.dart#? MethodExpression toLowerCase 1:35-1:46',
    // No test calls it: it can only fail on what another mutant left.
    'lib/cli.dart#? NumberLiteral 8 14:16-14:17',
    // Empty or switch off the code that removes the file of the process.
    'lib/ledger.dart#1 BlockStatement {} 6:14-10:2',
    'lib/ledger.dart#3 ConditionalExpression false 7:7-7:29',
    'lib/ledger.dart#4 BlockStatement {} 7:31-9:4',
    // Makes the second test file look where the first one left the
    // process they share.
    'lib/share.dart#? ConditionalExpression true 4:5-4:13',
    // Asks for the name of the isolate, which is not `main` under the test
    // runner.
    'lib/whoami.dart#? BooleanLiteral true 3:24-3:29',
  ];

  /// The mutants of the package, by file, each as `id mutator replacement
  /// place: status`, with the exit code and what the run printed.
  ///
  /// [buildInFrom] is the number of mutants from which those of a file are
  /// built into it: 0 for the run that is compared, so that every file goes
  /// that way, however few mutants it has. [only] limits the run to these
  /// files.
  Future<_Run> mutate({
    required bool oneByOne,
    int buildInFrom = 0,
    List<String> only = const [],
  }) async {
    final lines = <String>[];
    final parsed = parseArgs([
      'run',
      '--dir',
      dir.path,
      '--plan',
      '${dir.path}/plan.json',
      '--force',
      '--jobs',
      jobs,
      if (oneByOne) '--one-by-one',
      for (final name in only) ...['--only', 'lib/$name.dart'],
      '--',
      Platform.resolvedExecutable,
      'test',
    ]);
    final exitCode = await runMutation(
      (parsed as RunCommandArgs).run,
      Io(out: lines.add, err: lines.add),
      buildInFrom: buildInFrom,
    );
    final report =
        (jsonDecode(
                  File(
                    '${dir.path}/reports/mutation/mutation.json',
                  ).readAsStringSync(),
                )
                as Map<String, Object?>)['files']!
            as Map<String, Object?>;
    String place(Object? location) {
      final at = location! as Map<String, Object?>;
      final start = at['start']! as Map<String, Object?>;
      final end = at['end']! as Map<String, Object?>;
      return '${start['line']}:${start['column']}-'
          '${end['line']}:${end['column']}';
    }

    return (
      mutants: {
        for (final MapEntry(key: path, value: file) in report.entries)
          path: [
            for (final mutant
                in ((file! as Map<String, Object?>)['mutants']! as List)
                    .cast<Map<String, Object?>>())
              '${mutant['id']} ${mutant['mutatorName']} '
                  '${mutant['replacement']} ${place(mutant['location'])}: '
                  '${mutant['status']}',
          ],
      },
      exitCode: exitCode,
      lines: lines,
    );
  }

  setUpAll(() async {
    dir = Directory(
      Directory.systemTemp
          .createTempSync('dart_mutant_hazards_')
          .resolveSymbolicLinksSync(),
    );
    void write(String path, String content) => File('${dir.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    String fixture(String name) =>
        File('test/fixtures/hazards/$name.dart.txt').readAsStringSync();

    write('pubspec.yaml', '''
name: hazard_fixture
publish_to: none
environment:
  sdk: ^3.11.0
dev_dependencies:
  test: ^1.27.0
''');
    final targets = <Map<String, Object?>>[];
    write('lib/elsewhere.dart', fixture('elsewhere'));
    write('bin/shout.dart', fixture('shout_bin'));
    for (final name in files) {
      write('lib/$name.dart', fixture(name));
      final tests = several[name] ?? ['${name}_test'];
      for (final test in tests) {
        write('test/$test.dart', fixture(test));
      }
      targets.add({
        'file': 'lib/$name.dart',
        'tests': [for (final test in tests) 'test/$test.dart'],
      });
    }
    write('plan.json', jsonEncode({'version': 1, 'targets': targets}));
    // The packages are in the cache: this package depends on `test` too.
    final pubGet = Process.runSync(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: dir.path);
    expect(pubGet.exitCode, 0, reason: '${pubGet.stdout}${pubGet.stderr}');

    usual = await mutate(oneByOne: true);
    together = await mutate(oneByOne: false);
  });

  tearDownAll(() {
    dir.deleteSync(recursive: true);
    // What the tests of `ledger` left, one file per process.
    for (final entity in Directory.systemTemp.listSync()) {
      if (entity is File &&
          entity.uri.pathSegments.last.startsWith('hazard_ledger_')) {
        entity.deleteSync();
      }
    }
  });

  test('every file of the package is in both reports, and the run with a '
      'start per mutant builds nothing in', () {
    final paths = [for (final name in files) 'lib/$name.dart'];
    expect(usual.mutants.keys, paths);
    expect(together.mutants.keys, paths);
    expect(usual.lines.where((line) => line.contains('built in')), isEmpty);
    expect(shared.keys.toSet().union(givenUp.keys.toSet()), files.toSet());
  });

  for (final name in files) {
    test('lib/$name.dart: every mutant has the id, the mutator, the '
        'replacement, the place and the status that a start of the test '
        'runner of its own gives it', () {
      final own = usual.mutants['lib/$name.dart']!;
      expect(own, isNotEmpty);
      expect(together.mutants['lib/$name.dart'], own);
    });
  }

  test('and so the two runs end with the same exit code', () {
    expect(usual.exitCode, 1);
    expect(together.exitCode, 1);
  });

  test('the mutants that sharing would kill by mistake survive a start of '
      'the test runner of their own', () {
    final all = [for (final mutants in usual.mutants.values) ...mutants];
    for (final survivor in survivors) {
      final pattern = RegExp(
        '^${RegExp.escape(survivor).replaceFirst(r'#\?', r'#\d+')}: Survived\$',
      );
      expect(
        all.where(pattern.hasMatch),
        hasLength(1),
        reason: '$survivor\n${all.join('\n')}',
      );
    }
  });

  test('how the mutants that were built in went: how many there were, how '
      'many were killed by a process of their own, and how many were left '
      'for a start of the test runner', () {
    final went = <String, String>{};
    for (final name in files) {
      final builtIn = RegExp(
        '^  lib/$name\\.dart: (\\d+) of (\\d+) mutant\\(s\\) built in,',
      );
      final killed = RegExp(
        '^  lib/$name\\.dart: (\\d+) killed with the mutants built in'
        '(?:; (\\d+) cannot be built in \\([^)]*\\))?'
        '(?:; (\\d+) not killed that way get a start of their own)?(?:;|\$)',
      );
      final first = together.lines.map(builtIn.firstMatch).nonNulls;
      final second = together.lines.map(killed.firstMatch).nonNulls;
      if (first.isNotEmpty && second.isNotEmpty) {
        went[name] =
            '${first.single.group(1)} of ${first.single.group(2)} built in, '
            '${second.single.group(1)} killed there, '
            '${second.single.group(3) ?? 0} left';
      }
    }
    expect(went, shared, reason: together.lines.join('\n'));
  });

  test('the files that cannot be judged by processes of their own are given '
      'up, and say why: code that runs where no mutant is at work, more '
      'than one test file, code that asks which program runs it; no other '
      'file is', () {
    for (final MapEntry(key: name, value: line) in givenUp.entries) {
      expect(together.lines, contains(line), reason: name);
      expect(
        together.lines.where(
          (line) =>
              line.startsWith('  lib/$name.dart: ') &&
              line.contains('killed with the mutants built in'),
        ),
        isEmpty,
      );
    }
    expect(
      together.lines.where(
        (line) => line.contains('each of its mutants gets a start'),
      ),
      hasLength(givenUp.length),
      reason: together.lines.join('\n'),
    );
  });

  test('a file with few mutants is not built in: each of its mutants gets a '
      'start of the test runner from the beginning, the run says so, and '
      'the statuses are those of --one-by-one', () async {
    // After the tests above: the report of this run has these files only.
    final few = await mutate(
      oneByOne: false,
      buildInFrom: mutantsToBuildIn,
      only: fewMutants.keys.toList(),
    );
    for (final MapEntry(key: name, value: count) in fewMutants.entries) {
      final path = 'lib/$name.dart';
      expect(few.mutants[path], usual.mutants[path], reason: path);
      expect(
        few.lines,
        contains(
          '  $path: $count mutant(s) to run, fewer than $mutantsToBuildIn: '
          'not built in, a start of the test runner for each',
        ),
        reason: few.lines.join('\n'),
      );
    }
    expect(
      few.lines.where((line) => line.contains('mutant(s) built in,')),
      isEmpty,
      reason: few.lines.join('\n'),
    );
  });

  test('--schemata is still wrong usage, and nothing is run', () async {
    final report = File('${dir.path}/reports/mutation/mutation.json');
    final before = report.readAsStringSync();
    final err = <String>[];
    final out = <String>[];
    expect(
      await run([
        'run',
        '--dir',
        dir.path,
        '--force',
        '--schemata',
        'lib/registry.dart',
      ], Io(out: out.add, err: err.add)),
      2,
    );
    expect(err.first, 'dart_mutant: $schemataWithdrawn\n');
    expect(out, isEmpty);
    expect(report.readAsStringSync(), before);
    expect(Directory('${dir.path}/$stateDir/work').existsSync(), isFalse);
  });
}
