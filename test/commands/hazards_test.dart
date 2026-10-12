@Tags(['process'])
@Timeout(Duration(minutes: 15))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mutant/dart_mutant.dart';
import 'package:dart_mutant/src/args.dart';
import 'package:dart_mutant/src/commands/run.dart';
import 'package:test/test.dart';

/// The condition under which the mutants of a file may share one start of
/// the test runner: for a package of tests that are easy to get wrong
/// (test/fixtures/hazards), **every mutant has the status that a start of
/// the test runner of its own gives it**.
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
/// - `scales`: a top-level variable and a static field that are computed
///   once, and tests that are declared from the code under test, so that a
///   mutant changes how many there are.
/// - `pending`: a test that leaves a timer running and a future
///   unfinished, and a later test that relies on them.
/// - `lease`: a `tearDown` that throws when its `setUp` did not run.
/// - `place`: a test that changes the current directory, which the
///   isolates of a process share, and does not change it back.
/// - `pair`: a file with two test files, each with a state of its own.
void main() {
  late Directory dir;
  late ({Map<String, String> statuses, int exitCode, List<String> lines}) usual;
  late ({Map<String, String> statuses, int exitCode, List<String> lines})
  together;

  const files = [
    'registry',
    'counter',
    'background',
    'scales',
    'pending',
    'lease',
    'place',
    'pair',
  ];

  /// The mutants of the package as `file line:column Mutator replacement`,
  /// each with its status, the exit code and what the run printed.
  Future<({Map<String, String> statuses, int exitCode, List<String> lines})>
  mutate({required bool oneByOne}) async {
    final lines = <String>[];
    final exitCode = await run([
      'run',
      '--dir',
      dir.path,
      '--plan',
      '${dir.path}/plan.json',
      '--force',
      '--jobs',
      '2',
      if (oneByOne) '--one-by-one',
      '--',
      Platform.resolvedExecutable,
      'test',
    ], Io(out: lines.add, err: lines.add));
    final files =
        (jsonDecode(
                  File(
                    '${dir.path}/reports/mutation/mutation.json',
                  ).readAsStringSync(),
                )
                as Map<String, Object?>)['files']!
            as Map<String, Object?>;
    return (
      statuses: {
        for (final MapEntry(key: path, value: file) in files.entries)
          for (final mutant
              in ((file! as Map<String, Object?>)['mutants']! as List)
                  .cast<Map<String, Object?>>())
            () {
              final start =
                  (mutant['location']! as Map<String, Object?>)['start']!
                      as Map<String, Object?>;
              return '$path ${start['line']}:${start['column']} '
                  '${mutant['mutatorName']} ${mutant['replacement']}';
            }(): mutant['status']! as String,
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
    for (final name in files) {
      write('lib/$name.dart', fixture(name));
      final tests = name == 'pair'
          ? ['pair_first_test', 'pair_second_test']
          : ['${name}_test'];
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

  tearDownAll(() => dir.deleteSync(recursive: true));

  test('a start of the test runner for every mutant: the mutants that '
      'empty the clearing code survive', () {
    expect(usual.exitCode, 1);
    expect(
      usual.statuses,
      containsPair('lib/registry.dart 4:19 BlockStatement {}', 'Survived'),
    );
    expect(
      usual.statuses,
      containsPair('lib/counter.dart 4:16 BlockStatement {}', 'Survived'),
    );
    expect(
      usual.lines.where((line) => line.contains('built in')),
      isEmpty,
      reason: 'no mutant is built in with --one-by-one',
    );
  });

  test('one start of the test runner for the mutants of a file: every '
      'mutant has the status of a start of its own', () {
    expect(together.statuses.keys, usual.statuses.keys);
    expect([
      for (final MapEntry(key: mutant, value: status) in usual.statuses.entries)
        if (together.statuses[mutant] != status)
          '$mutant: $status, ${together.statuses[mutant]}',
    ], isEmpty);
    expect(together.exitCode, usual.exitCode);
  });

  test('and that is what was measured: the mutants of every file were '
      'built in, and none of the files was given up', () {
    for (final name in files) {
      expect(
        together.lines,
        contains(
          matches(
            '^  lib/$name\\.dart: [1-9]\\d* killed with the mutants built in',
          ),
        ),
        reason: together.lines.join('\n'),
      );
    }
    expect(
      together.lines.where(
        (line) => line.contains('each of its mutants gets a start'),
      ),
      isEmpty,
    );
    // In the table that is computed once as well.
    expect(
      together.lines.where((line) => line.contains('lib/scales.dart')).join(),
      isNot(contains('runs once')),
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
