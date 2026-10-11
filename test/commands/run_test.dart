@Tags(['process'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mutant/dart_mutant.dart';
import 'package:dart_mutant/src/args.dart';
import 'package:dart_mutant/src/commands/run.dart';
import 'package:test/test.dart';

import '../support/package_fixture.dart';

// One mutant: `+` → `-`.
const sourceA = 'int a(int x, int y) => x + y;\n';
// Two mutants: `*` → `/`, `-` → `+`.
const sourceB = 'num b(num x, num y) => x * y - x;';

const backup = '$stateDir/backup';
const placed = '$stateDir/placed';

void main() {
  late PackageFixture package;

  setUp(() {
    package = PackageFixture();
    package.write('lib/a.dart', sourceA);
    package.write('lib/b.dart', sourceB);
  });

  tearDown(() => package.delete());

  String shown(String test) =>
      '"${package.fake.join(' ')} --fail-fast --timeout 10s $test"';

  Future<int> mutate([
    List<String> arguments = const ['lib/a.dart', 'lib/b.dart'],
  ]) => run([
    'run',
    '--jobs',
    '1',
    '--root',
    package.path,
    ...arguments,
    '--',
    ...package.fake,
  ], package.io);

  void expectFilesUntouched() {
    expect(package.read('lib/a.dart'), sourceA);
    expect(package.read('lib/b.dart'), sourceB);
    for (final kept in [backup, placed]) {
      final directory = Directory('${package.path}/$kept');
      expect(
        directory.existsSync()
            ? directory.listSync(recursive: true).whereType<File>()
            : const <File>[],
        isEmpty,
      );
    }
  }

  Map<String, Object?> report([
    String path = 'reports/mutation/mutation.json',
  ]) => jsonDecode(package.read(path)) as Map<String, Object?>;

  List<Map<String, Object?>> mutantsOf(
    String file, [
    String path = 'reports/mutation/mutation.json',
  ]) =>
      (((report(path)['files']! as Map<String, Object?>)[file]!
                  as Map<String, Object?>)['mutants']!
              as List)
          .cast<Map<String, Object?>>();

  List<String> statusesOf(String file) => [
    for (final mutant in mutantsOf(file)) mutant['status']! as String,
  ];

  void killEverything() {
    package.fakeTest('lib/a.dart', ['expect: x + y']);
    package.fakeTest('lib/b.dart', ['expect: x * y - x']);
  }

  group('exit code 0', () {
    test('every mutant is killed; the files are put back and the report is '
        'written', () async {
      killEverything();
      expect(await mutate(), 0);
      expect(package.err, isEmpty);
      expect(package.out, [
        '  lib/a.dart: 1 of 1 mutant(s) with ${shown('lib/a_test.dart')}',
        matches(
          r'^  lib/a\.dart: 1 mutants / killed 1 / survived 0 / timeout 0 '
          r'/ compile error 0 \(\d+\.\ds\)$',
        ),
        '  lib/b.dart: 2 of 2 mutant(s) with ${shown('lib/b_test.dart')}',
        matches(
          r'^  lib/b\.dart: 2 mutants / killed 2 / survived 0 / timeout 0 '
          r'/ compile error 0 \(\d+\.\ds\)$',
        ),
        'dart_mutant: OK (3 mutants / killed 3 / survived 0 / timeout 0 / '
            'compile error 0)',
      ]);
      expectFilesUntouched();
      // One run without a mutant and one per mutant, for each file.
      expect(package.runs, hasLength(5));
      final json = report();
      expect(json['schemaVersion'], '2');
      expect(json['framework'], {'name': 'dart_mutant', 'version': '0.1.0'});
      final files = json['files']! as Map<String, Object?>;
      expect(files.keys, ['lib/a.dart', 'lib/b.dart']);
      expect((files['lib/a.dart']! as Map)['source'], sourceA);
      expect((files['lib/a.dart']! as Map)['language'], 'dart');
      expect(mutantsOf('lib/b.dart'), [
        {
          'id': 'lib/b.dart#0',
          'mutatorName': 'ArithmeticOperator',
          'replacement': '/',
          'status': 'Killed',
          'duration': isA<int>(),
          'location': {
            'start': {'line': 1, 'column': 26},
            'end': {'line': 1, 'column': 27},
          },
        },
        {
          'id': 'lib/b.dart#1',
          'mutatorName': 'ArithmeticOperator',
          'replacement': '+',
          'status': 'Killed',
          'duration': isA<int>(),
          'location': {
            'start': {'line': 1, 'column': 30},
            'end': {'line': 1, 'column': 31},
          },
        },
      ]);
    });

    test('a mutant that does not compile is found before the tests run: no '
        'test is run on it, and the report says why', () async {
      // `*` → `/` gives a double where an int is returned. The syntax
      // mutants come first, then the typed ones.
      package.write('lib/a.dart', 'int a(int x, int y) => x * y;\n');
      package.fakeTest('lib/a.dart', ['expect: x * y']);
      expect(await mutate(['lib/a.dart']), 0);
      expect(mutantsOf('lib/a.dart'), [
        {
          'id': 'lib/a.dart#0',
          'mutatorName': 'ArithmeticOperator',
          'replacement': '/',
          'status': 'CompileError',
          'statusReason': contains("'double'"),
          'duration': 0,
          'location': anything,
        },
      ]);
      expect(package.out.last, contains('compile error 1 (1 found before'));
      // Nothing to run: not even the tests without a mutant.
      expect(package.runs, isEmpty);
    });

    test('typed mutants are numbered after the syntax mutants', () async {
      package.write('lib/a.dart', 'int a(int x) => 2 + x.abs();\n');
      package.fakeTest('lib/a.dart', ['expect: 2 + x.abs()']);
      expect(await mutate(['lib/a.dart']), 0);
      expect(
        [
          for (final mutant in mutantsOf('lib/a.dart'))
            '${mutant['id']} ${mutant['mutatorName']} '
                '${mutant['replacement']}',
        ],
        [
          'lib/a.dart#0 ArithmeticOperator -',
          'lib/a.dart#1 NumberLiteral 3',
          'lib/a.dart#2 NumberLiteral 1',
          'lib/a.dart#3 MethodExpression ',
        ],
      );
      expect(statusesOf('lib/a.dart'), everyElement('Killed'));
    });

    test('a mutant that only fails to compile in the test run is counted '
        'apart', () async {
      killEverything();
      package.fakeTest('lib/b.dart', [
        'compile-error-if: x / y',
        'expect: x * y - x',
      ]);
      expect(await mutate(), 0);
      expect(statusesOf('lib/b.dart'), ['CompileError', 'Killed']);
      expect(mutantsOf('lib/b.dart').first.containsKey('statusReason'), false);
      expect(
        package.out.last,
        'dart_mutant: OK (3 mutants / killed 2 / survived 0 / timeout 0 / '
        'compile error 1)',
      );
    });

    test('the test under test/, a glob, and --report', () async {
      package.fakeTest('lib/a.dart', ['expect: x + y'], at: 'test/a_test.dart');
      package.fakeTest('lib/b.dart', ['expect: x * y - x']);
      final out = '${package.path}/out/m.json';
      expect(await mutate(['lib/*.dart', '--report', out]), 0);
      expect(
        package.out[0],
        '  lib/a.dart: 1 of 1 mutant(s) with ${shown('test/a_test.dart')}',
      );
      // lib/b_test.dart matches the glob and is not mutated.
      expect(
        ((jsonDecode(File(out).readAsStringSync()) as Map)['files'] as Map)
            .keys,
        ['lib/a.dart', 'lib/b.dart'],
      );
      expect(
        package.file('reports/mutation/mutation.json').existsSync(),
        isFalse,
      );
    });

    test('both the test next to the file and the one under test/ are '
        'run', () async {
      package.fakeTest('lib/a.dart', []);
      package.fakeTest('lib/a.dart', ['expect: x + y'], at: 'test/a_test.dart');
      expect(await mutate(['lib/a.dart']), 0);
      expect(package.runs.first, endsWith('lib/a_test.dart test/a_test.dart'));
    });

    test('a file whose name reads like a glob is a file', () async {
      package.write('lib/[id]/page.dart', sourceA);
      package.fakeTest('lib/[id]/page.dart', ['expect: x + y']);
      expect(await mutate(['lib/[id]/page.dart']), 0);
      expect((report()['files']! as Map).keys, ['lib/[id]/page.dart']);
    });

    test('a file without anything to mutate', () async {
      package.write('lib/a.dart', 'class A {}\n');
      package.fakeTest('lib/a.dart', []);
      expect(await mutate(['lib/a.dart']), 0);
      expect(mutantsOf('lib/a.dart'), isEmpty);
      expect(package.runs, isEmpty);
    });
  });

  group('a plan', () {
    Future<int> planned(Object? plan, [List<String> more = const []]) {
      package.write('plan.json', plan is String ? plan : jsonEncode(plan));
      return mutate(['--plan', '${package.path}/plan.json', ...more]);
    }

    test('names the files and the tests of each', () async {
      package.fakeTest('lib/a.dart', [
        'expect: x + y',
      ], at: 'checks/a_test.dart');
      package.fakeTest('lib/a.dart', [], at: 'lib/a_test.dart');
      package.write('checks/b_test.dart', '// file: lib/b.dart\n');
      expect(
        await planned({
          'version': 1,
          'targets': [
            {
              'file': 'lib/b.dart',
              'tests': ['checks/b_test.dart'],
            },
            {
              'file': 'lib/a.dart',
              'tests': ['checks/a_test.dart'],
            },
          ],
        }),
        1,
      );
      // In the order of the plan, with the tests of the plan only.
      expect(package.out.first, contains('checks/b_test.dart"'));
      expect(package.runs.first, endsWith('--timeout 10s checks/b_test.dart'));
      expect(package.runs.last, endsWith('--timeout 10s checks/a_test.dart'));
      expect(statusesOf('lib/b.dart'), ['Survived', 'Survived']);
      expect(statusesOf('lib/a.dart'), ['Killed']);
      expect((report()['files']! as Map).keys, ['lib/b.dart', 'lib/a.dart']);
    });

    test('a test that is not there, and no test: the file fails, the '
        'others are run', () async {
      killEverything();
      expect(
        await planned({
          'version': 1,
          'targets': [
            {
              'file': 'lib/a.dart',
              'tests': ['test/gone_test.dart'],
            },
            {'file': 'lib/b.dart', 'tests': <String>[]},
            {
              'file': 'lib/c.dart',
              'tests': ['lib/a_test.dart'],
            },
          ],
        }),
        1,
      );
      expect(package.err, [
        'Could not be mutation tested:',
        '  - lib/a.dart: test file not found: test/gone_test.dart (the check '
            'is case-sensitive)',
        '  - lib/b.dart: the plan lists no test for this file',
        '  - lib/c.dart: file not found (the check is case-sensitive)',
        'dart_mutant: FAILED (0 mutants / killed 0 / survived 0 / timeout 0 '
            '/ compile error 0 / 3 file(s) not tested)',
      ]);
    });

    for (final (name, plan, message) in [
      ('not JSON', '{', 'is not valid JSON'),
      ('not an object', '[]', 'must be a JSON object'),
      ('no version', '{"targets": []}', '"version" must be 1'),
      (
        'no targets',
        '{"version": 1, "targets": []}',
        '"targets" must be a list with at least one entry',
      ),
      (
        'a path outside the package',
        '{"version": 1, "targets": [{"file": "../a.dart", "tests": []}]}',
        'targets[0]: "../a.dart" must be a path inside the package',
      ),
    ]) {
      test('$name is wrong usage, and nothing is run', () async {
        killEverything();
        expect(await planned(plan), 2);
        expect(package.err.first, contains(message));
        expect(package.runs, isEmpty);
      });
    }

    test('a plan and files together are wrong usage', () async {
      expect(await planned({'version': 1}, ['lib/a.dart']), 2);
      expect(package.err.first, contains('either --plan or files'));
    });

    test('a plan that cannot be read is wrong usage', () async {
      expect(await mutate(['--plan', '${package.path}/none.json']), 2);
      expect(package.err.first, contains('cannot read the plan'));
    });
  });

  group('exit code 1', () {
    test('a survivor is listed with its place, its mutator and the '
        'change', () async {
      package.fakeTest('lib/a.dart', []);
      package.fakeTest('lib/b.dart', ['expect: y - x']);
      expect(await mutate(), 1);
      expect(package.out.sublist(4), [
        'Survived:',
        '  lib/a.dart:1:26 ArithmeticOperator: + → -',
        '  lib/b.dart:1:26 ArithmeticOperator: * → /',
      ]);
      expect(package.err, [
        'dart_mutant: FAILED (3 mutants / killed 1 / survived 2 / timeout 0 '
            '/ compile error 0)',
      ]);
      expectFilesUntouched();
      expect(statusesOf('lib/b.dart'), ['Survived', 'Killed']);
    });

    test('the tests fail without a mutant: the file is not measured, the '
        'others are', () async {
      killEverything();
      package.fakeTest('lib/a.dart', ['fail']);
      expect(await mutate(), 1);
      expect(package.err, [
        '      00:00 +0 -1: Some tests failed.',
        'Could not be mutation tested:',
        '  - lib/a.dart: the tests fail without a mutant (exit 1; a test '
            'gets 10s). Nothing was measured',
        'dart_mutant: FAILED (2 mutants / killed 2 / survived 0 / timeout 0 '
            '/ compile error 0 / 1 file(s) not tested)',
      ]);
      expect((report()['files']! as Map).keys, ['lib/b.dart']);
      expectFilesUntouched();
    });

    test('a file without a test, a file that is gone, a file that is not '
        'Dart', () async {
      package.write('lib/c.dart', 'int c( => 1;');
      package.fakeTest('lib/c.dart', []);
      expect(await mutate(['lib/a.dart', 'lib/gone.dart', 'lib/c.dart']), 1);
      expect(package.err, [
        'Could not be mutation tested:',
        '  - lib/a.dart: no test found (looked for lib/a_test.dart, '
            'test/a_test.dart). Name the tests in a plan (--plan) when they '
            'are somewhere else',
        '  - lib/gone.dart: file not found (the check is case-sensitive)',
        '  - lib/c.dart: cannot be read as Dart (syntax error)',
        'dart_mutant: FAILED (0 mutants / killed 0 / survived 0 / timeout 0 '
            '/ compile error 0 / 3 file(s) not tested)',
      ]);
      expect(package.runs, isEmpty);
    });

    test('a file the analyzer cannot take (its name is no URI) fails '
        'alone, and is not touched', () async {
      killEverything();
      package.write('lib/a#b%20c.dart', sourceA);
      package.fakeTest('lib/a#b%20c.dart', []);
      expect(await mutate(['lib/a#b%20c.dart', 'lib/a.dart']), 1);
      expect(package.err, [
        'Could not be mutation tested:',
        startsWith('  - lib/a#b%20c.dart: cannot be analyzed ('),
        'dart_mutant: FAILED (1 mutants / killed 1 / survived 0 / timeout 0 '
            '/ compile error 0 / 1 file(s) not tested)',
      ]);
      expect(package.read('lib/a#b%20c.dart'), sourceA);
      expectFilesUntouched();
    });

    test('the command cannot be started', () async {
      killEverything();
      final code = await run([
        'run',
        '--jobs',
        '1',
        '--root',
        package.path,
        'lib/a.dart',
        '--',
        'no-such-program-dart-mutant',
      ], package.io);
      expect(code, 1);
      expect(package.err, [
        startsWith('dart_mutant: cannot start "no-such-program-dart-mutant" ('),
        'dart_mutant: FAILED (the run was stopped)',
      ]);
      expectFilesUntouched();
    });

    test('the packages are not resolved', () async {
      killEverything();
      package.file('.dart_tool/package_config.json').deleteSync();
      expect(await mutate(), 1);
      expect(package.err, [
        'dart_mutant: .dart_tool/package_config.json not found. Run "dart '
            'pub get" (or "flutter pub get") in the package first',
        'dart_mutant: FAILED (the run was stopped)',
      ]);
      expect(package.runs, isEmpty);
    });

    test('a report of an earlier run is not left behind', () async {
      killEverything();
      expect(await mutate(), 0);
      package.file('.dart_tool/package_config.json').deleteSync();
      package.write('lib/a.dart', '$sourceA// changed\n');
      expect(await mutate(), 1);
      expect(
        package.file('reports/mutation/mutation.json').existsSync(),
        isFalse,
      );
    });
  });

  group('exit code 2', () {
    for (final (name, arguments, message) in [
      ('no command', <String>[], 'no command given'),
      ('an unknown command', ['mutate'], 'unknown command "mutate"'),
      ('an unknown option', ['run', '--fast'], 'unknown option "--fast"'),
      ('nothing to mutate', ['run'], 'nothing to mutate'),
      ('an option without its value', ['run', '--root'], '--root needs a'),
      ('-- without a command', ['run', 'lib/a.dart', '--'], '"--" must be'),
      (
        'a root that is not there',
        ['run', '--root', '/no/such/dir', 'lib/a.dart'],
        'is not a directory',
      ),
    ]) {
      test(name, () async {
        expect(await run(arguments, package.io), 2);
        expect(package.err, [
          contains(message),
          'Run "dart_mutant --help" for the usage.',
        ]);
      });
    }

    test('a glob that matches nothing, an absolute path, --only with a '
        'file that is not of the run', () async {
      killEverything();
      expect(await mutate(['lib/none*.dart']), 2);
      expect(package.err.first, contains('matches no .dart file'));
      package.err.clear();
      expect(await mutate(['${package.path}/lib/a.dart']), 2);
      expect(package.err.first, contains('must be a .dart file inside'));
      package.err.clear();
      expect(await mutate(['lib/a.dart', '--only', 'lib/b.dart']), 2);
      expect(
        package.err.first,
        'dart_mutant: --only lib/b.dart: not a file of this run',
      );
      expect(package.runs, isEmpty);
    });

    test('a glob that cannot be read', () async {
      expect(await mutate(['lib/[.dart']), 2);
      expect(package.err.first, contains('is not a glob'));
    });

    test('--report with the path of a file that is no report: the file is '
        'kept, and nothing is run', () async {
      killEverything();
      expect(
        await mutate(['lib/a.dart', '--report', '${package.path}/lib/b.dart']),
        2,
      );
      expect(
        package.err.first,
        contains('exists and is not a mutation report'),
      );
      expect(package.read('lib/b.dart'), sourceB);
      expect(package.runs, isEmpty);
    });

    test('--help and --version', () async {
      expect(await run(['--help'], package.io), 0);
      expect(package.out.single, startsWith('dart_mutant: mutation testing'));
      package.out.clear();
      expect(await run(['--version'], package.io), 0);
      expect(package.out, ['0.1.0']);
    });
  });

  group('timeouts', () {
    Future<int> quick([bool force = false]) => runMutation(
      RunArgs(
        root: package.path,
        targets: const ['lib/a.dart', 'lib/b.dart'],
        command: package.fake,
        force: force,
        jobs: 1,
      ),
      package.io,
      limitOf: (_) => const Duration(seconds: 2),
    );

    setUp(() {
      package.fakeTest('lib/a.dart', ['expect: x + y']);
      package.fakeTest('lib/b.dart', ['hang-if: x / y', 'expect: x * y - x']);
    });

    test('a run that does not end within the limit is ended, with what it '
        'started; a timeout is not a survivor', () async {
      expect(await quick(), 0);
      expect(
        package.out[3],
        startsWith(
          '  lib/b.dart: 2 mutants / killed 1 / survived 0 / timeout 1 '
          '/ compile error 0 (',
        ),
      );
      expect(statusesOf('lib/b.dart'), ['Timeout', 'Killed']);
      expectFilesUntouched();
      if (!Platform.isWindows) {
        final child = package.read('started');
        expect(
          Process.runSync('kill', ['-0', child]).exitCode,
          isNot(0),
          reason: 'the test run is still there',
        );
      }
    });

    test('the next run measures only the timeout again', () async {
      expect(await quick(), 0);
      final before = package.runs.length;
      package.out.clear();
      expect(await quick(), 0);
      expect(package.out, [
        '  lib/a.dart: 1 mutants / killed 1 / survived 0 / timeout 0 '
            '/ compile error 0 (1 from the last run, 0.0s)',
        '  lib/b.dart: 1 of 2 mutant(s) with ${shown('lib/b_test.dart')}',
        startsWith(
          '  lib/b.dart: 2 mutants / killed 1 / survived 0 / timeout 1 '
          '/ compile error 0 (1 from the last run, ',
        ),
        'dart_mutant: OK (3 mutants / killed 2 / survived 0 / timeout 1 / '
            'compile error 0)',
      ]);
      // lib/b.dart: the tests without a mutant, and the one mutant.
      expect(package.runs, hasLength(before + 2));
    });
  });

  group('results of the last run', () {
    setUp(killEverything);

    test('an unchanged file is not run again, and is still in the '
        'report', () async {
      expect(await mutate(), 0);
      final first = report();
      package.out.clear();
      // Not even analyzed: the mutants are those of the last run.
      package.file('.dart_tool/package_config.json').deleteSync();
      expect(await mutate(), 0);
      expect(package.out, [
        '  lib/a.dart: 1 mutants / killed 1 / survived 0 / timeout 0 '
            '/ compile error 0 (1 from the last run, 0.0s)',
        '  lib/b.dart: 2 mutants / killed 2 / survived 0 / timeout 0 '
            '/ compile error 0 (2 from the last run, 0.0s)',
        'dart_mutant: OK (3 mutants / killed 3 / survived 0 / timeout 0 / '
            'compile error 0)',
      ]);
      expect(package.runs, hasLength(5));
      String withoutDurations(Object? json) => jsonEncode(
        json,
      ).replaceAll(RegExp(r'"duration":\d+'), '"duration":0');
      expect(withoutDurations(report()), withoutDurations(first));
    });

    test('a survivor and a compile error of the last run are still '
        'there', () async {
      package.write('lib/a.dart', 'int a(int x, int y) => x * y;\n');
      package.fakeTest('lib/a.dart', []);
      package.fakeTest('lib/b.dart', []);
      expect(await mutate(), 1);
      final first = jsonEncode(report());
      final runs = package.runs.length;
      expect(await mutate(), 1);
      expect(package.runs, hasLength(runs));
      expect(
        jsonEncode(report()),
        first.replaceAll(RegExp(r'"duration":\d+'), '"duration":0'),
      );
      expect(package.out.last, '  lib/b.dart:1:30 ArithmeticOperator: - → +');
    });

    test('a changed file or a changed test is run again, the other file is '
        'not', () async {
      expect(await mutate(), 0);
      package.fakeTest('lib/b.dart', ['expect: x * y - x', 'expect: num b']);
      expect(await mutate(), 0);
      expect(package.runs, hasLength(5 + 3));
      package.write('lib/a.dart', '$sourceA// a comment\n');
      expect(await mutate(), 0);
      expect(package.runs, hasLength(5 + 3 + 2));
    });

    test('another test command is another run', () async {
      expect(await mutate(), 0);
      expect(
        await run([
          'run',
          '--jobs',
          '1',
          '--root',
          package.path,
          'lib/a.dart',
          '--',
          ...package.fake,
          '--reporter',
          'compact',
        ], package.io),
        0,
      );
      expect(package.runs, hasLength(5 + 2));
    });

    test('--force forgets the last results at once: a run that is stopped '
        'does not leave them to be reused', () async {
      expect(await mutate(), 0);
      // The run is stopped before it has a result.
      expect(
        await run([
          'run',
          '--jobs',
          '1',
          '--root',
          package.path,
          'lib/a.dart',
          'lib/b.dart',
          '--force',
          '--',
          'no-such-program-dart-mutant',
        ], package.io),
        1,
      );
      expect(await mutate(), 0);
      expect(package.runs, hasLength(10));
    });

    test('--force runs everything', () async {
      expect(await mutate(), 0);
      expect(await mutate(['lib/a.dart', 'lib/b.dart', '--force']), 0);
      expect(package.runs, hasLength(10));
    });

    test('a broken file of results is ignored', () async {
      expect(await mutate(), 0);
      package.write('$stateDir/incremental.json', '{"files": {"lib/a.dart": 1');
      expect(await mutate(), 0);
      expect(package.runs, hasLength(10));
      package.write(
        '$stateDir/incremental.json',
        jsonEncode({
          'files': {
            'lib/a.dart': {'input': 1, 'mutants': 2},
            'lib/b.dart': 3,
          },
        }),
      );
      expect(await mutate(), 0);
      expect(package.runs, hasLength(15));
    });
  });

  group('--only', () {
    setUp(killEverything);

    test('only that file is run; the report keeps what it says about the '
        'others', () async {
      package.fakeTest('lib/a.dart', []);
      expect(await mutate(), 1);
      package.fakeTest('lib/a.dart', ['expect: x + y']);
      package.out.clear();
      package.err.clear();
      expect(
        await mutate(['lib/a.dart', 'lib/b.dart', '--only', './lib/a.dart']),
        0,
      );
      expect(package.out, [
        '  lib/a.dart: 1 of 1 mutant(s) with ${shown('lib/a_test.dart')}',
        startsWith('  lib/a.dart: 1 mutants / killed 1 '),
        'dart_mutant: OK (1 mutants / killed 1 / survived 0 / timeout 0 / '
            'compile error 0)',
      ]);
      expect((report()['files']! as Map).keys, ['lib/b.dart', 'lib/a.dart']);
      expect(statusesOf('lib/a.dart'), ['Killed']);
      expect(statusesOf('lib/b.dart'), ['Killed', 'Killed']);
    });

    test('a run that is stopped leaves the other files in the report, and '
        'not the old result of its own', () async {
      expect(await mutate(), 0);
      package.write('lib/a.dart', '$sourceA// changed\n');
      package.file('.dart_tool/package_config.json').deleteSync();
      expect(
        await mutate(['lib/a.dart', 'lib/b.dart', '--only', 'lib/a.dart']),
        1,
      );
      expect((report()['files']! as Map).keys, ['lib/b.dart']);
    });

    test('--force forgets the last result of the file, and keeps those of '
        'the others', () async {
      expect(await mutate(), 0);
      expect(
        await mutate([
          'lib/a.dart',
          'lib/b.dart',
          '--force',
          '--only',
          'lib/a.dart',
        ]),
        0,
      );
      expect(package.runs, hasLength(5 + 2));
      expect(await mutate(), 0);
      expect(package.runs, hasLength(5 + 2));
    });
  });

  group('what a killed run left behind', () {
    setUp(killEverything);

    const mutant = 'int a(int x, int y) => x - y;\n';

    test('a mutant in a file is taken out before anything else', () async {
      package.write('$backup/lib/a.dart', sourceA);
      package.write('$placed/lib/a.dart', mutant);
      package.write('lib/a.dart', mutant);
      package.write('$stateDir/staging', 'half');
      expect(await mutate(), 0);
      expect(package.err, [
        'dart_mutant: put back lib/a.dart, which an interrupted run left '
            'with a mutant in it',
      ]);
      expectFilesUntouched();
      expect(package.file('$stateDir/staging').existsSync(), isFalse);
    });

    test('a backup of a file that is as it was is removed silently', () async {
      package.write('$backup/lib/a.dart', sourceA);
      package.write('$placed/lib/a.dart', mutant);
      expect(await mutate(), 0);
      expect(package.err, isEmpty);
      expectFilesUntouched();
    });

    test('a file that was edited since is not overwritten, and nothing is '
        'run', () async {
      package.write('$backup/lib/a.dart', sourceA);
      package.write('$placed/lib/a.dart', mutant);
      package.write('lib/a.dart', '$mutant// my edit\n');
      expect(await mutate(), 1);
      expect(package.err, [
        'dart_mutant: lib/a.dart: an interrupted run left a mutant in this '
            'file, and the file was changed since. It was left as it is. The '
            'content of before that run is in $backup/lib/a.dart; delete '
            'that file when you have compared the two',
        'dart_mutant: FAILED (nothing was run)',
      ]);
      expect(package.read('lib/a.dart'), '$mutant// my edit\n');
      expect(package.read('$backup/lib/a.dart'), sourceA);
      expect(package.runs, isEmpty);
    });

    test('a file that differs from its backup without a note of the mutant '
        'is not overwritten', () async {
      package.write('$backup/lib/a.dart', sourceA);
      package.write('lib/a.dart', mutant);
      expect(await mutate(), 1);
      expect(package.read('lib/a.dart'), mutant);
    });

    test('the report of an earlier run does not outlive a run that could '
        'not start', () async {
      expect(await mutate(), 0);
      package.write('$backup/lib/old.dart', 'int old() => 1;\n');
      expect(await mutate(), 1);
      expect(
        package.file('reports/mutation/mutation.json').existsSync(),
        isFalse,
      );
    });

    test('a backup of a file that is gone', () async {
      package.write('$backup/lib/old.dart', 'int old() => 1;\n');
      expect(await mutate(), 1);
      expect(package.err, [
        'dart_mutant: lib/old.dart: an interrupted run left a backup of this '
            'file, and the file is gone. The content of before that run is '
            'in $backup/lib/old.dart; delete that file when you have '
            'compared the two',
        'dart_mutant: FAILED (nothing was run)',
      ]);
    });
  });

  group('your files during the run', () {
    test('a file that is saved while its mutant is tested is left as it '
        'is, and the run stops', () async {
      // The "test run" edits the file, as an editor would.
      package.fakeFromSource('''
import 'dart:io';

void main(List<String> arguments) {
  final file = File('lib/a.dart');
  if (file.readAsStringSync().contains('x - y')) {
    file.writeAsStringSync('// saved by somebody\\n');
  }
}
''');
      package.fakeTest('lib/a.dart', []);
      expect(await mutate(['lib/a.dart']), 1);
      expect(package.err, [
        'dart_mutant: lib/a.dart changed during the run. It was left as it '
            'is, possibly with a mutant in it. The content of before the run '
            'is in $backup/lib/a.dart',
        'dart_mutant: FAILED (the run was stopped)',
      ]);
      expect(package.read('lib/a.dart'), '// saved by somebody\n');
      expect(package.read('$backup/lib/a.dart'), sourceA);
    });

    test('a file that is saved while its tests run without a mutant is not '
        'written to', () async {
      package.fakeFromSource('''
import 'dart:io';

void main(List<String> arguments) {
  File('lib/a.dart').writeAsStringSync('// saved by somebody\\n');
}
''');
      package.fakeTest('lib/a.dart', []);
      expect(await mutate(['lib/a.dart']), 1);
      expect(package.err, [
        'dart_mutant: lib/a.dart changed while its tests ran. Nothing was '
            'written to it; run again',
        'dart_mutant: FAILED (the run was stopped)',
      ]);
      expect(package.read('lib/a.dart'), '// saved by somebody\n');
      expect(package.file('$backup/lib/a.dart').existsSync(), isFalse);
    });

    test('the bytes of a file are put back as they were (CRLF, byte order '
        'mark), and the places count the mark', () async {
      const source = '﻿int a(int x, int y) =>\r\n    x + y.abs();\r\n';
      package.write('lib/a.dart', source);
      package.fakeTest('lib/a.dart', ['expect: x + y.abs()']);
      expect(await mutate(['lib/a.dart']), 0);
      expect(package.file('lib/a.dart').readAsBytesSync(), utf8.encode(source));
      expect(
        [
          for (final mutant in mutantsOf('lib/a.dart'))
            '${mutant['mutatorName']} '
                '${(mutant['location']! as Map)['start']} ${mutant['status']}',
        ],
        [
          'ArithmeticOperator {line: 2, column: 7} Killed',
          'MethodExpression {line: 2, column: 10} Killed',
        ],
      );
    });

    test('a file that is not UTF-8 is not touched', () async {
      package.file('lib/a.dart').writeAsBytesSync([0x2f, 0x2f, 0xff, 0x0a]);
      package.fakeTest('lib/a.dart', []);
      expect(await mutate(['lib/a.dart']), 1);
      expect(
        package.err[1],
        '  - lib/a.dart: is not valid UTF-8, so it cannot be written back',
      );
      expect(package.file('lib/a.dart').readAsBytesSync(), [
        0x2f,
        0x2f,
        0xff,
        0x0a,
      ]);
    });
  });

  group('--html', () {
    /// The report that is in the page.
    Object? inPage(String path) => jsonDecode(
      RegExp(
        r'^  app\.report = (.*);$',
        multiLine: true,
      ).firstMatch(File(path).readAsStringSync())![1]!,
    );

    test('the page holds the report that is written as JSON', () async {
      package.fakeTest('lib/a.dart', []);
      package.fakeTest('lib/b.dart', ['expect: x * y - x']);
      final page = '${package.path}/out/pages/m.html';
      expect(await mutate(['lib/a.dart', 'lib/b.dart', '--html', page]), 1);
      expect(inPage(page), report());
      expect(statusesOf('lib/a.dart'), ['Survived']);
      expect(
        File(page).readAsStringSync(),
        contains('<mutation-test-report-app'),
      );
    });

    test('without it no page is written', () async {
      killEverything();
      expect(await mutate(), 0);
      expect(
        Directory(package.path)
            .listSync(recursive: true)
            .where((entity) => entity.path.endsWith('.html')),
        isEmpty,
      );
    });

    test('the page of an earlier run is not left behind by a run that '
        'writes none', () async {
      killEverything();
      final page = '${package.path}/m.html';
      expect(await mutate(['lib/a.dart', 'lib/b.dart', '--html', page]), 0);
      expect(File(page).existsSync(), isTrue);
      package.file('.dart_tool/package_config.json').deleteSync();
      package.write('lib/a.dart', '$sourceA// changed\n');
      expect(await mutate(['lib/a.dart', 'lib/b.dart', '--html', page]), 1);
      expect(File(page).existsSync(), isFalse);
    });

    test('a page without a report next to it is removed as well', () async {
      killEverything();
      final page = '${package.path}/m.html';
      expect(await mutate(['lib/a.dart', 'lib/b.dart', '--html', page]), 0);
      package.file('reports/mutation/mutation.json').deleteSync();
      package.file('.dart_tool/package_config.json').deleteSync();
      package.write('lib/a.dart', '$sourceA// changed\n');
      expect(await mutate(['lib/a.dart', 'lib/b.dart', '--html', page]), 1);
      expect(File(page).existsSync(), isFalse);
    });

    test('with --only the page keeps what it says about the other files, '
        'also when the run is stopped', () async {
      killEverything();
      final page = '${package.path}/m.html';
      final arguments = ['lib/a.dart', 'lib/b.dart', '--html', page];
      expect(await mutate(arguments), 0);
      expect(await mutate([...arguments, '--only', 'lib/a.dart']), 0);
      expect(inPage(page), report());
      expect((report()['files']! as Map).keys, ['lib/b.dart', 'lib/a.dart']);

      package.write('lib/a.dart', '$sourceA// changed\n');
      package.file('.dart_tool/package_config.json').deleteSync();
      expect(await mutate([...arguments, '--only', 'lib/a.dart']), 1);
      expect(inPage(page), report());
      expect((report()['files']! as Map).keys, ['lib/b.dart']);
    });

    test('the path of a file that is no page of this tool: the file is '
        'kept, and nothing is run', () async {
      killEverything();
      package.write('notes.html', '<html><body>mine</body></html>\n');
      expect(
        await mutate(['lib/a.dart', '--html', '${package.path}/notes.html']),
        2,
      );
      expect(
        package.err.first,
        'dart_mutant: ${package.path}/notes.html exists and is not a report '
        'page of dart_mutant. It is not overwritten; give another --html, or '
        'delete the file',
      );
      expect(package.read('notes.html'), '<html><body>mine</body></html>\n');
      expect(package.runs, isEmpty);
    });

    test('the same file as --report is wrong usage', () async {
      killEverything();
      final path = '${package.path}/out/m.html';
      expect(
        await mutate([
          'lib/a.dart',
          '--report',
          path,
          '--html',
          '${package.path}/out/../out/m.html',
        ]),
        2,
      );
      expect(package.err.first, contains('--html and --report name the same'));
      expect(File(path).existsSync(), isFalse);
      expect(package.runs, isEmpty);
    });

    test('a path that is no .html file, and a directory, are wrong '
        'usage', () async {
      killEverything();
      expect(
        await mutate([
          'lib/a.dart',
          '--html',
          '${package.path}/reports/mutation/mutation.json',
        ]),
        2,
      );
      expect(package.err.first, contains('--html needs the path of an .html'));
      package.err.clear();
      Directory('${package.path}/pages.html').createSync();
      expect(
        await mutate(['lib/a.dart', '--html', '${package.path}/pages.html']),
        2,
      );
      expect(
        package.err.first,
        'dart_mutant: --html ${package.path}/pages.html is a directory',
      );
      expect(package.runs, isEmpty);
    });

    test('a page that cannot be written fails the run, which still writes '
        'the report and says what it found', () async {
      killEverything();
      // A file where the directory of the page would be.
      package.write('blocked', '');
      final page = '${package.path}/blocked/m.html';
      expect(await mutate(['lib/a.dart', '--html', page]), 1);
      expect(statusesOf('lib/a.dart'), ['Killed']);
      expect(package.err, [
        startsWith('dart_mutant: cannot write the page $page ('),
        'dart_mutant: FAILED (1 mutants / killed 1 / survived 0 / timeout 0 '
            '/ compile error 0)',
      ]);
      expect(
        package.err.first,
        endsWith(
          'The report is in '
          '${package.path}/reports/mutation/mutation.json',
        ),
      );
    });
  });
}
