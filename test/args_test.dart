import 'package:dart_mutant/src/args.dart';
import 'package:test/test.dart';

RunArgs runArgs(List<String> argv) => (parseArgs(argv) as RunCommandArgs).run;

void main() {
  test('files, options in either form, and the command after --', () {
    final args = runArgs([
      'run',
      '--dir',
      'app',
      'lib/a.dart',
      '--report=out.json',
      '--html',
      'out.html',
      '--force',
      '--only',
      'lib/a.dart',
      '--only=lib/b.dart',
      'lib/*.dart',
      '--',
      'fvm',
      'flutter',
      'test',
      '--force',
    ]);
    expect(args.dir, 'app');
    expect(args.plan, isNull);
    expect(args.report, 'out.json');
    expect(args.html, 'out.html');
    expect(args.force, isTrue);
    expect(args.only, ['lib/a.dart', 'lib/b.dart']);
    expect(args.targets, ['lib/a.dart', 'lib/*.dart']);
    expect(args.command, ['fvm', 'flutter', 'test', '--force']);
  });

  test('the defaults', () {
    final args = runArgs(['run', '--plan', 'plan.json']);
    expect(args.dir, '.');
    expect(args.plan, 'plan.json');
    expect(args.report, isNull);
    expect(args.html, isNull);
    expect(args.force, isFalse);
    expect(args.jobs, isNull);
    expect(args.schemata, isNull);
    expect(args.shard, isNull);
    expect(args.only, isEmpty);
    expect(args.targets, isEmpty);
    expect(args.command, isEmpty);
  });

  test('--no-schemata says what a run does anyway', () {
    expect(runArgs(['run', '--no-schemata', 'a.dart']).schemata, isFalse);
    // Not ours after --.
    expect(
      runArgs(['run', 'a.dart', '--', 'dart', 'test', '--schemata']).schemata,
      isNull,
    );
  });

  test('without either, the mutants are run one by one', () {
    expect(schemataByDefault, isFalse);
  });

  test('RunArgs without arguments is a run in the current directory that '
      'reuses results', () {
    const args = RunArgs();
    expect(args.dir, '.');
    expect(args.force, isFalse);
    expect(args.plan, isNull);
    expect(args.report, isNull);
    expect(args.html, isNull);
    expect(args.jobs, isNull);
    expect(args.schemata, isNull);
    expect(args.only, isEmpty);
    expect(args.targets, isEmpty);
    expect(args.command, isEmpty);
  });

  test('a value after = may hold = itself', () {
    final args = runArgs([
      'run',
      'a.dart',
      '--report=out=1.json',
      '--only=a=b',
    ]);
    expect(args.report, 'out=1.json');
    expect(args.only, ['a=b']);
  });

  test('only the first -- ends the arguments of this tool', () {
    final args = runArgs(['run', 'a.dart', '--', 'dart', '--', 'test']);
    expect(args.targets, ['a.dart']);
    expect(args.command, ['dart', '--', 'test']);
  });

  test('--html takes .html in any case', () {
    expect(runArgs(['run', 'a.dart', '--html=Out/M.HTML']).html, 'Out/M.HTML');
    expect(runArgs(['run', 'a.dart', '--html', '.html']).html, '.html');
  });

  test('--jobs in either form', () {
    expect(runArgs(['run', 'a.dart', '--jobs', '1']).jobs, 1);
    expect(runArgs(['run', 'a.dart', '--jobs=6']).jobs, 6);
  });

  test('--shard in either form', () {
    final shard = runArgs(['run', 'a.dart', '--shard', '2/4']).shard!;
    expect((shard.index, shard.count), (2, 4));
    expect(runArgs(['run', 'a.dart', '--shard=1/1']).shard!.label, '1/1');
    expect(const RunArgs().shard, isNull);
  });

  for (final value in ['0/2', '3/2', '2', 'a/b', '1/2/3']) {
    test('--shard $value is wrong usage', () {
      expect(
        () => parseArgs(['run', 'a.dart', '--shard=$value']),
        throwsA(
          isA<UsageError>().having(
            (error) => error.message,
            'message',
            '--shard needs <index>/<count>, with an index from 1 to the '
                'count ("$value")',
          ),
        ),
      );
    });
  }

  group('merge', () {
    MergeArgs mergeArgs(List<String> argv) =>
        (parseArgs(argv) as MergeCommandArgs).merge;

    test('the parts, the report and the page', () {
      final args = mergeArgs([
        'merge',
        'parts/1.json',
        '--report',
        'out.json',
        'parts/2.json',
        '--html=out.html',
      ]);
      expect(args.parts, ['parts/1.json', 'parts/2.json']);
      expect(args.report, 'out.json');
      expect(args.html, 'out.html');
      expect(mergeArgs(['merge', 'a.json', '--report=b.json']).html, isNull);
    });

    for (final (name, argv, message) in [
      ('no part', ['merge', '--report', 'out.json'], 'nothing to merge: give'),
      (
        'no report',
        ['merge', 'a.json'],
        'merge needs --report: where the report is written',
      ),
      (
        'a test command',
        ['merge', 'a.json', '--report', 'b.json', '--', 'dart', 'test'],
        'merge runs no tests: "--" and a command do not belong',
      ),
      (
        '-- alone',
        ['merge', 'a.json', '--report', 'b.json', '--'],
        'merge runs no tests',
      ),
      for (final option in [
        '--dir',
        '--plan',
        '--only',
        '--jobs',
        '--shard',
        '--force',
      ])
        (
          option,
          ['merge', 'a.json', '--report', 'b.json', option, '1/2'],
          'unknown argument for merge: $option',
        ),
      (
        'an option of no command',
        ['merge', 'a.json', '--report', 'b.json', '--fast=1'],
        'unknown argument for merge: --fast=1',
      ),
      (
        '--report twice',
        ['merge', 'a.json', '--report', 'b.json', '--report=c.json'],
        '--report is given twice',
      ),
      (
        '--html without .html',
        ['merge', 'a.json', '--report', 'b.json', '--html', 'c.json'],
        '--html needs the path of an .html file ("c.json")',
      ),
    ]) {
      test('$name is wrong usage', () {
        expect(
          () => parseArgs(argv),
          throwsA(
            isA<UsageError>().having(
              (error) => error.message,
              'message',
              startsWith(message),
            ),
          ),
        );
      });
    }

    test('--help wins', () {
      expect(parseArgs(['merge', '--help']), isA<HelpArgs>());
    });
  });

  test('the help names both commands and --shard', () {
    expect(help, contains('dart_mutant merge <part.json>... --report <path>'));
    expect(help, contains('  --shard <i>/<n>  '));
  });

  for (final value in ['0', '-1', '+2', '0x10', 'two', '1.5']) {
    test('--jobs $value is wrong usage', () {
      expect(
        () => parseArgs(['run', 'a.dart', '--jobs=$value']),
        throwsA(
          isA<UsageError>().having(
            (error) => error.message,
            'message',
            '--jobs needs a number from 1 ("$value")',
          ),
        ),
      );
    });
  }

  test('--help and --version win, but not after --', () {
    expect(parseArgs(['--help']), isA<HelpArgs>());
    expect(parseArgs(['run', 'a.dart', '-h']), isA<HelpArgs>());
    expect(parseArgs(['--version']), isA<VersionArgs>());
    expect(parseArgs(['-v']), isA<VersionArgs>());
    expect(parseArgs(['run', 'a.dart', '-v']), isA<VersionArgs>());
    // As test_gates reads them: the version when both are asked for.
    expect(parseArgs(['--help', '--version']), isA<VersionArgs>());
    expect(parseArgs(['-v', '-h']), isA<VersionArgs>());
    expect(
      parseArgs(['run', 'a.dart', '--', 'dart', 'test', '-v']),
      isA<RunCommandArgs>(),
    );
    expect(
      parseArgs(['run', 'a.dart', '--', 'dart', 'test', '--help']),
      isA<RunCommandArgs>(),
    );
  });

  for (final (name, argv, message) in [
    ('nothing', <String>[], 'no command given'),
    ('another command', ['test'], 'unknown command: test'),
    ('an option and no command', ['--fast'], 'unknown argument: --fast'),
    (
      'an option in front of the command',
      ['--dir', 'a', 'run', 'a.dart'],
      'unknown argument: --dir',
    ),
    ('another command and more', ['test', 'a.dart'], 'unknown command: test'),
    ('only a test command', ['--', 'dart', 'test'], 'no command given'),
    ('-- in front of run', ['--', 'run', 'a.dart'], 'no command given'),
    ('an empty value after =', ['run', 'a.dart', '--only='], '--only needs a'),
    (
      'an unknown option',
      ['run', 'a.dart', '--fast'],
      'unknown argument for run: --fast',
    ),
    (
      'an unknown option with a value',
      ['run', 'a.dart', '--fast=1'],
      'unknown argument for run: --fast=1',
    ),
    (
      'the old name of --dir',
      ['run', 'a.dart', '--root', 'a'],
      'unknown argument for run: --root',
    ),
    ('a short option', ['run', 'a.dart', '-f'], 'unknown argument for run: -f'),
    (
      '--force with a value',
      ['run', 'a.dart', '--force=1'],
      '--force does not take a value',
    ),
    (
      '--schemata, which was withdrawn',
      ['run', 'a.dart', '--schemata'],
      schemataWithdrawn,
    ),
    (
      '--schemata with a value',
      ['run', 'a.dart', '--schemata=1'],
      schemataWithdrawn,
    ),
    (
      '--schemata before the files',
      ['run', '--schemata', 'a.dart'],
      schemataWithdrawn,
    ),
    (
      '--schemata for merge, which never had it',
      ['merge', 'a.json', '--report', 'b.json', '--schemata'],
      'unknown argument for merge: --schemata',
    ),
    (
      '--no-schemata with a value',
      ['run', 'a.dart', '--no-schemata=0'],
      '--no-schemata does not take a value',
    ),
    (
      '--no-schemata twice',
      ['run', 'a.dart', '--no-schemata', '--no-schemata'],
      '--no-schemata is given twice',
    ),
    (
      '--schemata after --no-schemata',
      ['run', 'a.dart', '--no-schemata', '--schemata'],
      schemataWithdrawn,
    ),
    ('a value that is missing', ['run', 'a.dart', '--report'], 'needs a value'),
    ('an empty value', ['run', 'a.dart', '--report='], 'needs a value'),
    (
      'an option twice',
      ['run', 'a.dart', '--dir', 'a', '--dir', 'b'],
      '--dir is given twice',
    ),
    (
      '--html without .html',
      ['run', 'a.dart', '--html', 'out.json'],
      '--html needs the path of an .html file ("out.json")',
    ),
    (
      '--html with .html inside',
      ['run', 'a.dart', '--html=a.html.txt'],
      '--html needs the path of',
    ),
    ('a plan and files', ['run', '--plan', 'p', 'a.dart'], 'either --plan or'),
    ('neither a plan nor files', ['run', '--force'], 'nothing to mutate'),
    ('-- and nothing after it', ['run', 'a.dart', '--'], '"--" must be'),
  ]) {
    test('$name is wrong usage', () {
      expect(
        () => parseArgs(argv),
        throwsA(
          isA<UsageError>().having(
            (error) => '$error',
            'message',
            contains(message),
          ),
        ),
      );
    });
  }

  test('the help starts and ends as the one of test_gates does', () {
    expect(
      help,
      startsWith(
        'dart_mutant — mutation testing for Dart and Flutter\n\nUsage:\n',
      ),
    );
    expect(help, contains('\n  -h, --help       Show this help\n'));
    expect(help, contains('\n  -v, --version    Show the version\n'));
    expect(help, contains('\nExit codes:\n  0    no mutant survived\n'));
  });

  test('the help says that --schemata was withdrawn, and --schemata is '
      'answered with why', () {
    expect(
      help,
      contains('\n  --schemata       Withdrawn in 0.1.1, and refused (exit'),
    );
    expect(schemataWithdrawn, startsWith('--schemata was withdrawn in 0.1.1'));
    expect(schemataWithdrawn, contains('reported as killed'));
    expect(schemataWithdrawn, endsWith('Run without it'));
  });

  test('the help names every option', () {
    for (final option in [
      '--dir <package>',
      '--plan',
      '--only',
      '--report',
      '--html',
      '--force',
      '--jobs',
      '--schemata',
      '--no-schemata',
    ]) {
      expect(help, contains(option));
    }
  });
}
