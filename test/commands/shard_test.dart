@Tags(['process'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mutant/dart_mutant.dart';
import 'package:test/test.dart';

import '../support/package_fixture.dart';

// Mutants of every kind of result: some the stand-in for the tests kills,
// some it lets through, one it cannot compile, and one (`y / 2`, a double
// where an int is returned) that the analyzer refuses before a test is run.
const sourceA = '''
int f(int x, int y) {
  if (x > y) {
    return x - y;
  }
  return x + y * 2;
}
''';
const rulesA = [
  'expect: x > y',
  'expect: x - y',
  'compile-error-if: y * 3',
  'expect: x + y',
];

// Two mutants: `*` → `/`, `-` → `+`.
const sourceB = 'num b(num x, num y) => x * y - x;\n';

typedef Json = Map<String, Object?>;

/// `dart_mutant run --shard` and `dart_mutant merge`.
void main() {
  late PackageFixture package;

  setUp(() {
    package = PackageFixture();
    package.write('lib/a.dart', sourceA);
    package.fakeTest('lib/a.dart', rulesA);
    package.write('lib/b.dart', sourceB);
    package.fakeTest('lib/b.dart', ['expect: x * y']);
  });

  tearDown(() => package.delete());

  String at(String name) => '${package.path}/$name';

  Future<int> mutate(
    List<String> arguments, {
    int jobs = 1,
    bool force = true,
    List<String> files = const ['lib/a.dart', 'lib/b.dart'],
  }) => run([
    'run',
    '--dir',
    package.path,
    '--jobs',
    '$jobs',
    if (force) '--force',
    ...files,
    ...arguments,
    '--',
    ...package.fake,
  ], package.io);

  Future<int> merge(List<String> arguments) =>
      run(['merge', ...arguments], package.io);

  Json read(String name) => jsonDecode(package.read(name)) as Json;

  /// A report without what depends on the clock.
  Json timeless(Json report) =>
      jsonDecode(
            jsonEncode(
              report,
            ).replaceAll(RegExp(r'"duration":\d+'), '"duration":0'),
          )
          as Json;

  List<Json> mutantsOf(Json report, String file) =>
      (((report['files']! as Json)[file]! as Json)['mutants']! as List)
          .cast<Json>();

  List<String> statusesOf(Json report, String file) => [
    for (final mutant in mutantsOf(report, file)) mutant['status']! as String,
  ];

  /// Runs the parts 1 to [count] and returns the names of their reports.
  Future<List<String>> runParts(int count, {int jobs = 1}) async {
    final names = <String>[];
    for (var index = 1; index <= count; index++) {
      final name = 'parts/$index-of-$count.json';
      await mutate([
        '--shard',
        '$index/$count',
        '--report',
        at(name),
      ], jobs: jobs);
      names.add(name);
    }
    return names;
  }

  group('the parts of a run', () {
    for (final (count, jobs) in [(2, 1), (4, 1), (3, 2), (9, 1)]) {
      test('$count part(s) with --jobs $jobs, put together, are the report '
          'of the run without --shard', () async {
        expect(await mutate(['--report', at('whole.json')]), 1);
        final whole = read('whole.json');
        expect(statusesOf(whole, 'lib/a.dart').toSet(), {
          'Killed',
          'Survived',
          'CompileError',
        });
        expect(whole['config'], {'mutatorsVersion': 2});

        final names = await runParts(count, jobs: jobs);
        final total = mutantsOf(whole, 'lib/a.dart').length;
        for (final (index, name) in names.indexed) {
          final part = read(name);
          expect(part['config'], {
            'mutatorsVersion': 2,
            'shard': {
              'index': index + 1,
              'count': count,
              'notTested': <String>[],
            },
          });
          // The mutants are those of the whole run, each with its number;
          // the ones of the other parts are not evaluated.
          final mutants = mutantsOf(part, 'lib/a.dart');
          expect(mutants, hasLength(total));
          for (final (number, mutant) in mutants.indexed) {
            final expected = mutantsOf(whole, 'lib/a.dart')[number];
            expect(mutant['id'], expected['id']);
            expect(mutant['location'], expected['location']);
            if (number % count == index) {
              expect(mutant['status'], expected['status'], reason: name);
              expect(mutant['statusReason'], expected['statusReason']);
            } else {
              expect(mutant['status'], 'Pending', reason: name);
              expect(mutant.containsKey('statusReason'), isFalse);
              expect(mutant['duration'], 0);
            }
          }
        }

        package.out.clear();
        package.err.clear();
        expect(
          await merge([
            for (final name in names.reversed) at(name),
            '--report',
            at('merged.json'),
          ]),
          1,
        );
        expect(timeless(read('merged.json')), timeless(whole));
        // Key for key in the same order, too.
        expect(
          jsonEncode(timeless(read('merged.json'))),
          jsonEncode(timeless(whole)),
        );
      });
    }

    test('what a part prints: its share of the mutants, and that it is a '
        'part in the last line', () async {
      package.fakeTest('lib/b.dart', ['expect: x * y - x']);
      expect(
        await mutate(
          ['--shard', '2/2', '--report', at('part.json')],
          files: ['lib/b.dart'],
        ),
        0,
      );
      expect(package.err, isEmpty);
      expect(package.out, [
        startsWith('  lib/b.dart: 1 of 2 mutant(s) with "'),
        matches(
          r'^  lib/b\.dart: 1 of 2 mutants / killed 1 / survived 0 / '
          r'timeout 0 / compile error 0 \(\d+\.\ds\)$',
        ),
        'dart_mutant run: OK (shard 2/2: 1 of 2 mutants / killed 1 / survived 0 '
            '/ timeout 0 / compile error 0)',
      ]);
      // One run without a mutant, and one for the one mutant of the part.
      expect(package.runs, hasLength(2));
      expect(statusesOf(read('part.json'), 'lib/b.dart'), [
        'Pending',
        'Killed',
      ]);
    });

    test('the first line of a file counts the mutants of the part: those '
        'to run, and those of them that do not compile', () async {
      // Of the ten mutants of the file one is refused by the analyzer.
      var refused = 0;
      for (final index in [1, 2]) {
        package.out.clear();
        await mutate(['--shard', '$index/2'], files: ['lib/a.dart']);
        final line = RegExp(
          r'^  lib/a\.dart: (\d) of 10 mutant\(s\) with ".*"( \((\d) do not '
          r'compile\))?$',
        ).firstMatch(package.out.first)!;
        final own = int.parse(line[3] ?? '0');
        expect(int.parse(line[1]!) + own, 5, reason: package.out.first);
        refused += own;
      }
      expect(refused, 1);
    });

    test('a survivor of a part fails the part, and only that one', () async {
      // `-` → `+` survives: the second mutant.
      expect(await mutate(['--shard', '1/2'], files: ['lib/b.dart']), 0);
      expect(await mutate(['--shard', '2/2'], files: ['lib/b.dart']), 1);
      expect(package.err, hasLength(3));
      expect(package.err.first, 'dart_mutant run: 1 surviving mutant(s)');
      expect(
        package.err.last,
        'dart_mutant run: FAILED (shard 2/2: 1 of 2 mutants / killed 0 / '
        'survived 1 / timeout 0 / compile error 0)',
      );
    });

    test('--shard 1/1 is the whole run, and still a part', () async {
      expect(await mutate(['--report', at('whole.json')]), 1);
      expect(await mutate(['--shard', '1/1', '--report', at('part.json')]), 1);
      expect(
        package.err.last,
        startsWith('dart_mutant run: FAILED (shard 1/1: 12 mutants / '),
        reason: '${package.err}',
      );
      expect((read('part.json')['config']! as Json)['shard'], {
        'index': 1,
        'count': 1,
        'notTested': <String>[],
      });
      expect(await merge([at('part.json'), '--report', at('merged.json')]), 1);
      expect(timeless(read('merged.json')), timeless(read('whole.json')));
    });

    test('a file that cannot be tested is named in the part, and the parts '
        'are not put together', () async {
      package.file('lib/b_test.dart').deleteSync();
      for (final index in [1, 2]) {
        expect(
          await mutate(['--shard', '$index/2', '--report', at('p$index.json')]),
          1,
        );
        expect(
          ((read('p$index.json')['config']! as Json)['shard']!
              as Json)['notTested'],
          ['lib/b.dart'],
        );
      }
      package.err.clear();
      expect(
        await merge([at('p1.json'), at('p2.json'), '--report', at('m.json')]),
        1,
      );
      expect(package.err, [
        'dart_mutant merge: the parts are not the parts of one run',
        '  - shard 1/2 (${at('p1.json')}): lib/b.dart could not be mutation '
            'tested',
        '  - shard 2/2 (${at('p2.json')}): lib/b.dart could not be mutation '
            'tested',
        'dart_mutant merge: FAILED (nothing was merged)',
      ]);
      expect(File(at('m.json')).existsSync(), isFalse);
    });
  });

  group('--shard with the other options', () {
    test('--plan and --only: the part has the files of this run and '
        'nothing of an earlier report', () async {
      package.write(
        'plan.json',
        jsonEncode({
          'version': 1,
          'targets': [
            {
              'file': 'lib/b.dart',
              'tests': ['lib/b_test.dart'],
            },
            {
              'file': 'lib/a.dart',
              'tests': ['lib/a_test.dart'],
            },
          ],
        }),
      );
      Future<int> planned(List<String> arguments) =>
          mutate(['--plan', at('plan.json'), ...arguments], files: const []);

      // The report of a whole run is there.
      expect(await planned([]), 1);
      expect((read('reports/mutation/mutation.json')['files']! as Json).keys, [
        'lib/b.dart',
        'lib/a.dart',
      ]);
      // The survivor of the file is a mutant of the other part.
      expect(await planned(['--only', 'lib/a.dart', '--shard', '1/2']), 0);
      final part = read('reports/mutation/mutation.json');
      expect((part['files']! as Json).keys, ['lib/a.dart']);
      expect(statusesOf(part, 'lib/a.dart'), contains('Pending'));

      // And a run of the other file without --shard keeps nothing of the
      // part: its mutants of the other part have no result.
      expect(await planned(['--only', 'lib/b.dart']), 1);
      final whole = read('reports/mutation/mutation.json');
      expect((whole['files']! as Json).keys, ['lib/b.dart']);
      expect((whole['config']! as Json).containsKey('shard'), isFalse);

      // The parts of a plan are put together in the order of the plan.
      for (final index in [1, 2]) {
        await planned(['--shard', '$index/2', '--report', at('p$index.json')]);
      }
      expect(
        await merge([at('p1.json'), at('p2.json'), '--report', at('m.json')]),
        1,
      );
      expect((read('m.json')['files']! as Json).keys, [
        'lib/b.dart',
        'lib/a.dart',
      ]);
    });

    test('the results of the last run: a part runs what it does not know '
        'yet, and a whole run after the parts runs nothing', () async {
      expect(await mutate(['--report', at('whole.json')]), 1);
      final whole = timeless(read('whole.json'));
      final runsOfWhole = package.runs.length;
      // Every result is known: no part has anything to run.
      for (final index in [1, 2]) {
        expect(
          await mutate([
            '--shard',
            '$index/2',
            '--report',
            at('p$index.json'),
          ], force: false),
          // Both survivors are mutants of the second part.
          index - 1,
        );
      }
      expect(package.runs, hasLength(runsOfWhole));
      expect(
        await merge([at('p1.json'), at('p2.json'), '--report', at('m.json')]),
        1,
      );
      expect(timeless(read('m.json')), whole);

      // From nothing: the first part (with --force) leaves the mutants of
      // the second without a result, the second runs those and no others,
      // and the whole run after them has nothing left to run.
      File(at('runs.log')).deleteSync();
      await mutate(['--shard', '1/2', '--report', at('p1.json')]);
      final runsOfFirst = package.runs.length;
      expect(runsOfFirst, lessThan(runsOfWhole));
      await mutate(['--shard', '2/2', '--report', at('p2.json')], force: false);
      // The run without a mutant is done once per file and run; the
      // mutants are each run once.
      expect(package.runs, hasLength(runsOfWhole + 2));
      package.out.clear();
      expect(await mutate(['--report', at('again.json')], force: false), 1);
      expect(package.runs, hasLength(runsOfWhole + 2));
      expect(timeless(read('again.json')), whole);
      expect(package.out, contains(contains('(10 from the last run, ')));
    });

    test('a part says how many of its own results are from the last '
        'run', () async {
      expect(await mutate([], files: ['lib/b.dart']), 1);
      package.out.clear();
      expect(
        await mutate(['--shard', '1/2'], files: ['lib/b.dart'], force: false),
        0,
      );
      expect(package.out, [
        startsWith(
          '  lib/b.dart: 1 of 2 mutants / killed 1 / survived 0 / timeout 0 / '
          'compile error 0 (1 from the last run, ',
        ),
        'dart_mutant run: OK (shard 1/2: 1 of 2 mutants / killed 1 / survived 0 '
            '/ timeout 0 / compile error 0)',
      ]);
    });

    test('--html: the page of a part holds the part, and says which one '
        'it is', () async {
      final page = at('part.html');
      expect(
        await mutate([
          '--shard',
          '2/3',
          '--html',
          page,
          '--report',
          at('p.json'),
        ]),
        anyOf(0, 1),
      );
      final text = File(page).readAsStringSync();
      expect(text, contains('<title>Mutation report, shard 2/3</title>'));
      final inPage = jsonDecode(
        RegExp(
          r'^  app\.report = (.*);$',
          multiLine: true,
        ).firstMatch(text)![1]!,
      );
      expect(inPage, read('p.json'));
      // Without --shard the title is the plain one.
      await mutate(['--html', page, '--report', at('p.json')]);
      expect(
        File(page).readAsStringSync(),
        contains('<title>Mutation report</title>'),
      );
    });
  });

  group('merge', () {
    late List<String> names;

    setUp(() async {
      names = await runParts(3);
      package.out.clear();
      package.err.clear();
    });

    test('prints the files, the survivors and the totals, like a run', () async {
      expect(
        await merge([
          for (final name in names) at(name),
          '--report',
          at('out/merged.json'),
        ]),
        1,
      );
      expect(package.out, [
        '  lib/a.dart: 10 mutants / killed 7 / survived 1 / timeout 0 / '
            'compile error 2 (1 found before the run)',
        '  lib/b.dart: 2 mutants / killed 1 / survived 1 / timeout 0 / '
            'compile error 0',
      ]);
      expect(package.err, [
        'dart_mutant merge: 2 surviving mutant(s)',
        '  - lib/a.dart:5:18 / NumberLiteral / 2 → 1 (Survived)',
        '  - lib/b.dart:1:30 / ArithmeticOperator / - → + (Survived)',
        'dart_mutant merge: FAILED (3 part(s) merged: 12 mutants / killed 8 / '
            'survived 2 / timeout 0 / compile error 2 (1 found before the '
            'run))',
      ]);
    });

    test('no survivor: exit code 0', () async {
      package.write('lib/c.dart', 'int c(int x) => x + 1;\n');
      package.fakeTest('lib/c.dart', ['expect: x + 1']);
      for (final index in [1, 2]) {
        expect(
          await mutate(
            ['--shard', '$index/2', '--report', at('c$index.json')],
            files: ['lib/c.dart'],
          ),
          0,
        );
      }
      package.out.clear();
      expect(
        await merge([at('c1.json'), at('c2.json'), '--report', at('c.json')]),
        0,
      );
      expect(package.err, isEmpty);
      expect(
        package.out.last,
        startsWith('dart_mutant merge: OK (2 part(s) merged: '),
      );
      expect(read('c.json')['config'], {'mutatorsVersion': 2});
    });

    test('--html: the page holds the merged report', () async {
      final page = at('out/merged.html');
      await merge([
        for (final name in names) at(name),
        '--report',
        at('merged.json'),
        '--html',
        page,
      ]);
      final text = File(page).readAsStringSync();
      expect(text, contains('<title>Mutation report</title>'));
      expect(
        jsonDecode(
          RegExp(
            r'^  app\.report = (.*);$',
            multiLine: true,
          ).firstMatch(text)![1]!,
        ),
        read('merged.json'),
      );
    });

    test('a part that is missing: exit code 1, no report, and the report '
        'and the page of an earlier merge are gone', () async {
      final arguments = ['--report', at('merged.json'), '--html', at('m.html')];
      await merge([for (final name in names) at(name), ...arguments]);
      expect(File(at('merged.json')).existsSync(), isTrue);
      expect(File(at('m.html')).existsSync(), isTrue);
      package.out.clear();
      package.err.clear();
      expect(await merge([at(names[0]), at(names[2]), ...arguments]), 1);
      expect(package.out, isEmpty);
      expect(package.err, [
        'dart_mutant merge: the parts are not the parts of one run',
        '  - shard 2/3 is missing',
        'dart_mutant merge: FAILED (nothing was merged)',
      ]);
      expect(File(at('merged.json')).existsSync(), isFalse);
      expect(File(at('m.html')).existsSync(), isFalse);
    });

    test('a part of another source', () async {
      package.write('lib/a.dart', '$sourceA// changed\n');
      await mutate(['--shard', '2/3', '--report', at('other.json')]);
      package.err.clear();
      expect(
        await merge([
          at(names[0]),
          at('other.json'),
          at(names[2]),
          '--report',
          at('merged.json'),
        ]),
        1,
      );
      expect(package.err, [
        'dart_mutant merge: the parts are not the parts of one run',
        '  - shard 2/3 (${at('other.json')}): lib/a.dart is not the source '
            'shard 1/3 (${at(names[0])}) mutated',
        'dart_mutant merge: FAILED (nothing was merged)',
      ]);
    });

    test('a file that is no JSON is no part', () async {
      package.write('text.json', 'not JSON');
      expect(
        await merge([at(names[0]), at('text.json'), '--report', at('m.json')]),
        1,
      );
      expect(package.err, [
        'dart_mutant merge: the parts are not the parts of one run',
        '  - ${at('text.json')} is not a part of a run: not a report that '
            'dart_mutant wrote with --shard',
        'dart_mutant merge: FAILED (nothing was merged)',
      ]);
    });

    group('wrong usage: exit code 2, and nothing is written or removed', () {
      test('a part that cannot be read', () async {
        expect(
          await merge([
            at(names[0]),
            at('none.json'),
            '--report',
            at('m.json'),
          ]),
          2,
        );
        expect(
          package.err.first,
          startsWith('dart_mutant: cannot read the part ${at('none.json')} ('),
        );
      });

      test('--report names one of the parts', () async {
        final before = package.read(names[1]);
        expect(
          await merge([
            for (final name in names) at(name),
            '--report',
            '${package.path}/parts/../${names[1]}',
          ]),
          2,
        );
        expect(
          package.err.first,
          startsWith('dart_mutant: --report names one of the parts ('),
        );
        expect(package.read(names[1]), before);
      });

      test('--report or --html would replace a file of another kind', () async {
        package.write('notes.json', '{"notes": 1}');
        package.write('notes.html', '<p>notes</p>');
        expect(
          await merge([
            for (final name in names) at(name),
            '--report',
            at('notes.json'),
          ]),
          2,
        );
        expect(package.err.first, contains('is not a mutation report'));
        expect(
          await merge([
            for (final name in names) at(name),
            '--report',
            at('m.json'),
            '--html',
            at('notes.html'),
          ]),
          2,
        );
        expect(package.read('notes.json'), '{"notes": 1}');
        expect(package.read('notes.html'), '<p>notes</p>');
        expect(File(at('m.json')).existsSync(), isFalse);
      });
    });
  });
}
