@Tags(['process'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mutant/dart_mutant.dart';
import 'package:dart_mutant/src/args.dart';
import 'package:dart_mutant/src/commands/run.dart';
import 'package:dart_mutant/src/io/lock.dart';
import 'package:test/test.dart';

import '../support/package_fixture.dart';

// Mutants of every kind of result: some the stand-in for the tests kills,
// some it lets through, one it cannot compile, and one (`y / 2`, a double
// where an int is returned) that the analyzer refuses before a test is run.
const source = '''
int f(int x, int y) {
  if (x > y) {
    return x - y;
  }
  return x + y * 2;
}
''';
const rules = [
  'expect: x > y',
  'expect: x - y',
  'compile-error-if: y * 3',
  'expect: x + y',
];

// Two mutants: `*` → `/`, `-` → `+`.
const sourceB = 'num b(num x, num y) => x * y - x;\n';

const work = '$stateDir/work';

/// `dart_mutant run --jobs N` with N above one: the mutants are put into
/// copies of the package.
void main() {
  late PackageFixture package;

  setUp(() {
    package = PackageFixture();
    package.write('lib/a.dart', source);
    package.fakeTest('lib/a.dart', rules);
  });

  tearDown(() => package.delete());

  Future<int> mutate(
    int jobs, {
    List<String> arguments = const ['lib/a.dart'],
    bool force = true,
  }) => run([
    'run',
    '--dir',
    package.path,
    '--jobs',
    '$jobs',
    if (force) '--force',
    ...arguments,
    '--',
    ...package.sharedFake,
  ], package.io);

  /// The report without what depends on the clock.
  Object? report([String path = 'reports/mutation/mutation.json']) {
    final json = jsonDecode(package.read(path)) as Map<String, Object?>;
    for (final file in (json['files']! as Map<String, Object?>).values) {
      for (final mutant
          in (file! as Map<String, Object?>)['mutants']! as List) {
        (mutant as Map<String, Object?>).remove('duration');
      }
    }
    return json;
  }

  List<String> statuses(String file) => [
    for (final mutant
        in (((report() as Map<String, Object?>)['files']!
                    as Map<String, Object?>)[file]!
                as Map<String, Object?>)['mutants']!
            as List)
      (mutant as Map<String, Object?>)['status']! as String,
  ];

  /// Nothing of a run with working copies is left in the package.
  void expectPackageUntouched() {
    expect(package.read('lib/a.dart'), source);
    expect(
      package.sharedRunDirectories,
      everyElement(startsWith('${package.path}/$work/')),
      reason: 'a test was run outside the working copies',
    );
    for (final kept in ['$stateDir/backup', '$stateDir/placed', work]) {
      expect(Directory('${package.path}/$kept').existsSync(), isFalse);
    }
  }

  test('the result is the one of a run in place, mutant by mutant, for any '
      'number of jobs', () async {
    expect(await mutate(1), 1);
    final inPlace = report();
    final printed = package.out.toList();
    expect(statuses('lib/a.dart').toSet(), {
      'Killed',
      'Survived',
      'CompileError',
    });
    final runsInPlace = package.sharedRuns.length;

    for (final jobs in [2, 3, 16]) {
      package.out.clear();
      package.err.clear();
      package.clearShared();
      expect(await mutate(jobs), 1, reason: '--jobs $jobs');
      expect(report(), inPlace, reason: '--jobs $jobs');
      // The lines are the same but for the times and the number of jobs.
      String timeless(String line) => line
          .replaceAll(RegExp(r'\(\d+\.\ds\)'), '')
          .replaceAll(RegExp(r', \d+ at a time'), '');
      expect(package.out.map(timeless), printed.map(timeless));
      final mutants = runsInPlace - 1;
      final workers = jobs < mutants ? jobs : mutants;
      expect(package.out.first, contains('", $workers at a time ('));
      // One run without a mutant in every copy, and one per mutant.
      expect(package.sharedRuns, hasLength(workers + mutants));
      expect(package.err.last, startsWith('dart_mutant: FAILED'));
    }
  });

  test(
    'no file of the package is written, and the copies are removed',
    () async {
      final stamp = package.file('lib/a.dart').lastModifiedSync();
      final test = package.file('lib/a_test.dart').lastModifiedSync();
      expect(await mutate(2), 1);
      expectPackageUntouched();
      expect(package.file('lib/a.dart').lastModifiedSync(), stamp);
      expect(package.file('lib/a_test.dart').lastModifiedSync(), test);
      expect(package.sharedRuns, isNotEmpty);
    },
  );

  test('the results are reused whatever the number of jobs, and --only and '
      'a plan work as in place', () async {
    package.write('lib/b.dart', sourceB);
    package.fakeTest('lib/b.dart', [
      'expect: x * y - x',
    ], at: 'checks/b_test.dart');
    package.write(
      'plan.json',
      jsonEncode({
        'version': 1,
        'targets': [
          {
            'file': 'lib/b.dart',
            'tests': ['checks/b_test.dart'],
          },
          {
            'file': 'lib/a.dart',
            'tests': ['lib/a_test.dart'],
          },
        ],
      }),
    );
    final plan = ['--plan', '${package.path}/plan.json'];
    expect(await mutate(2, arguments: plan), 1);
    final both = report() as Map<String, Object?>;
    expect((both['files']! as Map).keys, ['lib/b.dart', 'lib/a.dart']);
    expect(statuses('lib/b.dart'), ['Killed', 'Killed']);
    final runs = package.sharedRuns.length;

    // Nothing changed: no test is run, with any number of jobs.
    for (final jobs in [1, 2, 3]) {
      expect(await mutate(jobs, arguments: plan, force: false), 1);
      expect(package.sharedRuns, hasLength(runs));
      expect(report(), both);
    }

    // Only the file that is asked for is run again.
    expect(await mutate(2, arguments: [...plan, '--only', 'lib/b.dart']), 0);
    expect(package.sharedRuns, hasLength(runs + 2 + 2));
    expect(report(), both);
    expectPackageUntouched();
  });

  test('a file that is not in a copy (below build/) is put there', () async {
    package.write('build/gen/c.dart', sourceB);
    package.fakeTest('build/gen/c.dart', ['expect: x * y']);
    expect(await mutate(2, arguments: ['build/gen/c.dart']), 1);
    expect(statuses('build/gen/c.dart'), ['Killed', 'Survived']);
    expect(package.read('build/gen/c.dart'), sourceB);
    expectPackageUntouched();
  });

  test('no mutant of a file is left in a copy when the next file is run: '
      'its tests can read the first', () async {
    package.write('lib/b.dart', sourceB);
    // Every line of lib/a.dart that a mutant changes.
    package.fakeTest('lib/b.dart', [
      'expect: x * y - x',
      for (final line in source.trim().split('\n').skip(1).take(4))
        'expect-in: lib/a.dart::$line',
    ]);
    expect(await mutate(2, arguments: ['lib/a.dart', 'lib/b.dart']), 1);
    expect(package.err, [startsWith('dart_mutant: FAILED')]);
    expect(package.out[2], contains('lib/b.dart: 2 of 2 mutant(s)'));
    expect(package.out[2], contains(', 2 at a time'));
    expect(statuses('lib/b.dart'), ['Killed', 'Killed']);
    expectPackageUntouched();
  });

  test('a file and its tests are taken from the package when their turn '
      'comes, not when the copies were made', () async {
    package.write('lib/b.dart', sourceB);
    // When the copies are made, the tests of lib/b.dart let everything
    // through. The tests of lib/a.dart put stricter ones into the package.
    package.fakeTest('lib/b.dart', ['expect: num b']);
    package.fakeTest('lib/b.dart', [
      'expect: x * y - x',
    ], at: 'strict/b_test.dart');
    package.fakeTest('lib/a.dart', [
      'install: ${package.path}/strict/b_test.dart::'
          '${package.path}/lib/b_test.dart',
      ...rules,
    ]);
    expect(await mutate(2, arguments: ['lib/a.dart', 'lib/b.dart']), 1);
    expect(statuses('lib/b.dart'), ['Killed', 'Killed']);
  });

  group('memory limit', () {
    Future<int> heavy(int jobs) => runMutation(
      RunArgs(
        dir: package.path,
        targets: const ['lib/b.dart'],
        command: package.sharedFake,
        jobs: jobs,
        force: true,
      ),
      package.io,
      // Not what ends a run in these tests.
      limitOf: (_) => const Duration(seconds: 40),
      memoryLimitOf: (_) => 200 * 1024,
    );

    List<Object?> reasons() => [
      for (final mutant
          in (((report() as Map)['files'] as Map)['lib/b.dart']
                  as Map)['mutants']
              as List)
        (mutant as Map)['statusReason'],
    ];

    setUp(() => package.write('lib/b.dart', sourceB));

    test(
      'a mutant that takes more memory than the limit is ended, run '
      'again alone, and is a Timeout when it is ended then as well',
      () async {
        package.fakeTest('lib/b.dart', ['grow-if: x / y', 'expect: x * y - x']);
        expect(await heavy(2), 0);
        expect(package.out, [
          startsWith('  lib/b.dart: 2 of 2 mutant(s) with '),
          '  lib/b.dart: 1 mutant(s) used more than 200 MB of memory, were '
              'ended and run again alone: 1 reached a limit then as well '
              '(Timeout)',
          startsWith(
            '  lib/b.dart: 2 mutants / killed 1 / survived 0 / timeout 1 '
            '/ compile error 0 (',
          ),
          'dart_mutant: OK (2 mutants / killed 1 / survived 0 / timeout 1 / '
              'compile error 0)',
        ]);
        expect(statuses('lib/b.dart'), ['Timeout', 'Killed']);
        expect(reasons(), [
          'the test run used more than 200 MB of memory and was ended',
          null,
        ]);
        // Two runs without a mutant, two mutants, and one of them again.
        expect(package.sharedRuns, hasLength(5));
        // Both runs that took the memory were ended.
        final ended = package.sharedHeavy;
        expect(ended, hasLength(2));
        for (final pid in ended) {
          expect(Process.runSync('kill', ['-0', pid]).exitCode, isNot(0));
        }
        expectPackageUntouched();
      },
      testOn: '!windows',
    );

    test('a mutant that only took that much once is not a Timeout: the '
        'second run decides, and a survivor it finds fails the run', () async {
      package.fakeTest('lib/b.dart', ['grow-once-if: x / y', 'expect: y - x']);
      expect(await heavy(2), 1);
      expect(
        package.out[1],
        '  lib/b.dart: 1 mutant(s) used more than 200 MB of memory, were '
        'ended and run again alone: 0 reached a limit then as well (Timeout)',
      );
      expect(statuses('lib/b.dart'), ['Survived', 'Killed']);
      expect(reasons(), [null, null]);
      expect(package.sharedRuns, hasLength(5));
    }, testOn: '!windows');
  });

  group('time limit', () {
    Future<int> quick(int jobs) => runMutation(
      RunArgs(
        dir: package.path,
        targets: const ['lib/b.dart'],
        command: package.sharedFake,
        jobs: jobs,
        force: true,
      ),
      package.io,
      // Long enough for a run that does not hang to start on a busy
      // machine: one that is taken for hanging would be run again.
      limitOf: (_) => const Duration(seconds: 8),
    );

    setUp(() => package.write('lib/b.dart', sourceB));

    test('a mutant that does not end is run again alone, and is a Timeout '
        'when it does not end then either', () async {
      package.fakeTest('lib/b.dart', ['hang-if: x / y', 'expect: x * y - x']);
      expect(await quick(2), 0);
      expect(package.out, [
        startsWith('  lib/b.dart: 2 of 2 mutant(s) with '),
        '  lib/b.dart: 1 mutant(s) did not end within 8s and were run again '
            'alone: 1 did not end then either (Timeout)',
        startsWith(
          '  lib/b.dart: 2 mutants / killed 1 / survived 0 / timeout 1 '
          '/ compile error 0 (',
        ),
        'dart_mutant: OK (2 mutants / killed 1 / survived 0 / timeout 1 / '
            'compile error 0)',
      ]);
      expect(statuses('lib/b.dart'), ['Timeout', 'Killed']);
      // Two runs without a mutant, two mutants, and one of them again.
      expect(package.sharedRuns, hasLength(5));
      // Both runs that hung were ended.
      final hung = package.sharedHung;
      expect(hung, hasLength(2));
      if (!Platform.isWindows) {
        for (final pid in hung) {
          expect(Process.runSync('kill', ['-0', pid]).exitCode, isNot(0));
        }
      }
      expectPackageUntouched();
    });

    test('a mutant that only did not end while the others ran is not a '
        'Timeout: the second run decides', () async {
      package.fakeTest('lib/b.dart', [
        'hang-once-if: x / y',
        'expect: x * y - x',
      ]);
      expect(await quick(2), 0);
      expect(
        package.out[1],
        '  lib/b.dart: 1 mutant(s) did not end within 8s and were run again '
        'alone: 0 did not end then either (Timeout)',
      );
      expect(statuses('lib/b.dart'), ['Killed', 'Killed']);
      expect(package.sharedRuns, hasLength(5));
    });

    test('a survivor that is found by the second run fails the run', () async {
      package.fakeTest('lib/b.dart', ['hang-once-if: x / y', 'expect: y - x']);
      expect(await quick(2), 1);
      expect(statuses('lib/b.dart'), ['Survived', 'Killed']);
    });
  });

  group('what cannot be run from a copy is run in place', () {
    test('tests that only pass in the package itself', () async {
      package.fakeTest('lib/a.dart', ['fail-below: $work/', ...rules]);
      expect(await mutate(1), 1);
      final inPlace = report();
      package.err.clear();
      expect(await mutate(2), 1);
      expect(
        package.err.first,
        'dart_mutant: lib/a.dart has tests that fail in a working copy '
        '(exit 1); its mutants are run one at a time, in place',
      );
      expect(report(), inPlace);
      expect(package.read('lib/a.dart'), source);
      expect(Directory('${package.path}/$work').existsSync(), isFalse);
    });

    test('tests that fail everywhere fail the file, as in place', () async {
      package.fakeTest('lib/a.dart', ['fail']);
      expect(await mutate(2), 1);
      expect(package.err, [
        'dart_mutant: lib/a.dart has tests that fail in a working copy '
            '(exit 1); its mutants are run one at a time, in place',
        contains('Some tests failed.'),
        'Could not be mutation tested:',
        startsWith('  - lib/a.dart: the tests fail without a mutant (exit 1'),
        startsWith('dart_mutant: FAILED (0 mutants '),
      ]);
      expect(package.read('lib/a.dart'), source);
    });

    test('a dependency at a path relative to the package', () async {
      package.write(
        '.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'fixture', 'rootUri': '../', 'packageUri': 'lib/'},
            {'name': 'shared', 'rootUri': '../../shared', 'packageUri': 'lib/'},
          ],
        }),
      );
      expect(await mutate(2), 1);
      expect(
        package.err.first,
        'dart_mutant: the dependency "shared" is at a path relative to the '
        'package (../../shared), so it cannot be run from working copies. '
        'The mutants are run one at a time, in place (--jobs 1)',
      );
      expect(package.out.first, isNot(contains('at a time')));
      expect(statuses('lib/a.dart'), contains('Survived'));
      expect(package.read('lib/a.dart'), source);
      expect(Directory('${package.path}/$work').existsSync(), isFalse);
    });

    test('a file behind a symbolic link', () async {
      final outside = Directory.systemTemp.createTempSync('dart_mutant_link_');
      addTearDown(() => outside.deleteSync(recursive: true));
      File('${outside.path}/b.dart').writeAsStringSync(sourceB);
      Link('${package.path}/lib/b.dart').createSync('${outside.path}/b.dart');
      package.fakeTest('lib/b.dart', ['expect: x * y']);
      expect(await mutate(2, arguments: ['lib/a.dart', 'lib/b.dart']), 1);
      expect(
        package.err,
        contains(
          'dart_mutant: lib/b.dart is behind a symbolic link; its mutants '
          'are run one at a time, in place',
        ),
      );
      expect(package.out[0], contains(', 2 at a time'));
      expect(package.out[2], isNot(contains('at a time')));
      expect(statuses('lib/b.dart'), ['Killed', 'Survived']);
      expect(File('${outside.path}/b.dart').readAsStringSync(), sourceB);
    }, testOn: '!windows');
  });

  test('the copies a killed run left are removed by the next run, also by '
      'one in place', () async {
    package.write('$work/1/lib/a.dart', 'int f() => 0;\n');
    package.write('$work/2/pubspec.yaml', 'name: fixture\n');
    expect(await mutate(1), 1);
    expect(Directory('${package.path}/$work').existsSync(), isFalse);
  });

  group('one run at a time in a package', () {
    test('a second run changes nothing and says who is at work', () async {
      expect(await mutate(2), 1);
      final before = package.read('reports/mutation/mutation.json');
      final runs = package.sharedRuns.length;
      package.out.clear();
      package.err.clear();

      final lock = RunLock.acquire('${package.path}/$stateDir/lock');
      try {
        for (final jobs in [1, 2]) {
          expect(await mutate(jobs), 1);
        }
      } finally {
        lock.release();
      }
      expect(package.out, isEmpty);
      expect(package.err, hasLength(2));
      expect(
        package.err.first,
        matches(
          r'^dart_mutant: another dart_mutant run is at work in this package '
          r'\(pid \d+, started \d{4}-\d\d-\d\dT[\d:.]+Z\)\. Nothing was run '
          r'or changed; run again when it has ended \(the lock is '
          r'\.dart_tool/dart_mutant/lock\)$',
        ),
      );
      // Not even the report of the last run is removed.
      expect(package.read('reports/mutation/mutation.json'), before);
      expect(package.sharedRuns, hasLength(runs));
      expectPackageUntouched();

      // The lock is given back.
      expect(await mutate(2), 1);
      expect(package.sharedRuns, hasLength(2 * runs));
    });

    test('wrong usage is still wrong usage', () async {
      final lock = RunLock.acquire('${package.path}/$stateDir/lock');
      addTearDown(lock.release);
      expect(await mutate(2, arguments: ['lib/a.txt']), 2);
    });

    test('the lock is taken twice in a process only after it is given '
        'back, and the file stays', () {
      final path = '${package.path}/$stateDir/lock';
      final first = RunLock.acquire(path);
      // (Not read here: with fcntl, a process that closes any handle of
      // the file gives up its lock on it.)
      expect(
        () => RunLock.acquire(path),
        throwsA(isA<LockHeld>().having((held) => held.pid, 'pid', pid)),
      );
      first.release();
      first.release();
      expect(File(path).readAsStringSync(), isEmpty);
      RunLock.acquire(path).release();
    });
  });
}
