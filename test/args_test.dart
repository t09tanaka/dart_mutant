import 'package:dart_mutant/src/args.dart';
import 'package:test/test.dart';

RunArgs runArgs(List<String> argv) => (parseArgs(argv) as RunCommandArgs).run;

void main() {
  test('files, options in either form, and the command after --', () {
    final args = runArgs([
      'run',
      '--root',
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
    expect(args.root, 'app');
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
    expect(args.root, '.');
    expect(args.plan, 'plan.json');
    expect(args.report, isNull);
    expect(args.html, isNull);
    expect(args.force, isFalse);
    expect(args.jobs, isNull);
    expect(args.only, isEmpty);
    expect(args.targets, isEmpty);
    expect(args.command, isEmpty);
  });

  test('RunArgs without arguments is a run in the current directory that '
      'reuses results', () {
    const args = RunArgs();
    expect(args.root, '.');
    expect(args.force, isFalse);
    expect(args.plan, isNull);
    expect(args.report, isNull);
    expect(args.html, isNull);
    expect(args.jobs, isNull);
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
    expect(
      parseArgs(['run', 'a.dart', '--', 'dart', 'test', '--help']),
      isA<RunCommandArgs>(),
    );
  });

  for (final (name, argv, message) in [
    ('nothing', <String>[], 'no command given'),
    ('another command', ['test'], 'unknown command "test"'),
    ('another command and more', ['test', 'a.dart'], 'unknown command "test"'),
    ('only a test command', ['--', 'dart', 'test'], 'no command given'),
    ('-- in front of run', ['--', 'run', 'a.dart'], 'no command given'),
    ('an empty value after =', ['run', 'a.dart', '--only='], '--only needs a'),
    ('an unknown option', ['run', 'a.dart', '--fast'], 'unknown option'),
    ('a short option', ['run', 'a.dart', '-f'], 'unknown option "-f"'),
    ('--force with a value', ['run', 'a.dart', '--force=1'], 'takes no value'),
    ('a value that is missing', ['run', 'a.dart', '--report'], 'needs a value'),
    ('an empty value', ['run', 'a.dart', '--report='], 'needs a value'),
    (
      'an option twice',
      ['run', 'a.dart', '--root', 'a', '--root', 'b'],
      '--root is given twice',
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

  test('the help names every option', () {
    for (final option in [
      '--root',
      '--plan',
      '--only',
      '--report',
      '--html',
      '--force',
      '--jobs',
    ]) {
      expect(help, contains(option));
    }
  });
}
