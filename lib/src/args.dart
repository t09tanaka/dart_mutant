/// Whether the mutants of a file are built into one program when neither
/// `--schemata` nor `--no-schemata` is given.
const schemataByDefault = false;

/// The command line of `dart_mutant run`.
class RunArgs {
  const RunArgs({
    this.root = '.',
    this.plan,
    this.report,
    this.html,
    this.force = false,
    this.jobs,
    this.schemata,
    this.only = const [],
    this.targets = const [],
    this.command = const [],
  });

  /// `--root`: the package to mutate.
  final String root;

  /// `--plan`: the plan file.
  final String? plan;

  /// `--report`: where the report is written.
  final String? report;

  /// `--html`: where the report is written as a page for a browser, when
  /// that is wanted.
  final String? html;

  /// `--force`: no result of an earlier run is reused.
  final bool force;

  /// `--jobs`: how many test runs are started at a time. `null` when it is
  /// not given: the number then depends on the machine.
  final int? jobs;

  /// `--schemata` (true) or `--no-schemata` (false): whether the mutants of
  /// a file are built into one program. `null` when neither is given.
  final bool? schemata;

  /// `--only`, once per file: the run is limited to these targets.
  final List<String> only;

  /// The files and globs given as arguments.
  final List<String> targets;

  /// What follows `--`: the command that runs test files.
  final List<String> command;
}

/// What the command line asks for.
sealed class ParsedArgs {
  const ParsedArgs();
}

class HelpArgs extends ParsedArgs {
  const HelpArgs();
}

class VersionArgs extends ParsedArgs {
  const VersionArgs();
}

class RunCommandArgs extends ParsedArgs {
  const RunCommandArgs(this.run);

  final RunArgs run;
}

class UsageError implements Exception {
  UsageError(this.message);

  final String message;

  @override
  String toString() => message;
}

const _valueOptions = [
  '--root',
  '--plan',
  '--report',
  '--html',
  '--only',
  '--jobs',
];

/// Reads the command line. Throws [UsageError] for anything it does not
/// know: a misspelled option must not become a run of something else.
ParsedArgs parseArgs(List<String> argv) {
  // What is in front of the first `--` is for this tool; the rest is the
  // `--` and the test command behind it, or nothing.
  final own = argv.takeWhile((argument) => argument != '--').toList();
  final rest = argv.skip(own.length).toList();
  final command = rest.skip(1).toList();
  if (own.contains('--help') || own.contains('-h')) {
    return const HelpArgs();
  }
  if (own.contains('--version')) {
    return const VersionArgs();
  }
  if (own.isEmpty) {
    throw UsageError('no command given');
  }
  if (own.first != 'run') {
    throw UsageError('unknown command "${own.first}"');
  }
  if (rest.isNotEmpty && command.isEmpty) {
    throw UsageError('"--" must be followed by the command that runs tests');
  }

  var root = '.';
  String? plan;
  String? report;
  String? html;
  var force = false;
  int? jobs;
  bool? schemata;
  final only = <String>[];
  final targets = <String>[];
  final seen = <String>{};
  for (var index = 1; index < own.length; index++) {
    final argument = own[index];
    if (!argument.startsWith('-')) {
      targets.add(argument);
      continue;
    }
    // `--name=value`: the value is what follows the first `=`.
    final parts = argument.split('=');
    final name = parts.first;
    final inline = parts.length > 1;
    if (name == '--force') {
      if (inline) {
        throw UsageError('--force takes no value');
      }
      force = true;
      continue;
    }
    if (name == '--schemata' || name == '--no-schemata') {
      if (inline) {
        throw UsageError('$name takes no value');
      }
      if (schemata != null) {
        throw UsageError('--schemata or --no-schemata is given twice');
      }
      schemata = name == '--schemata';
      continue;
    }
    if (!_valueOptions.contains(name)) {
      throw UsageError('unknown option "$name"');
    }
    final String value;
    if (inline) {
      value = parts.skip(1).join('=');
    } else {
      if (index + 1 >= own.length) {
        throw UsageError('$name needs a value');
      }
      value = own[++index];
    }
    if (value.isEmpty) {
      throw UsageError('$name needs a value');
    }
    if (name != '--only' && !seen.add(name)) {
      throw UsageError('$name is given twice');
    }
    switch (name) {
      case '--root':
        root = value;
      case '--plan':
        plan = value;
      case '--report':
        report = value;
      case '--html':
        // Also so that it can never be the file of --report by another
        // spelling, or a source file.
        if (!value.toLowerCase().endsWith('.html')) {
          throw UsageError('--html needs the path of an .html file ("$value")');
        }
        html = value;
      case '--only':
        only.add(value);
      case '--jobs':
        jobs = RegExp(r'^\d+$').hasMatch(value) ? int.tryParse(value) : null;
        if (jobs == null || jobs < 1) {
          throw UsageError('--jobs needs a number from 1 ("$value")');
        }
    }
  }
  if (plan != null && targets.isNotEmpty) {
    throw UsageError(
      'give either --plan or files, not both: the plan says which files '
      'are mutated',
    );
  }
  if (plan == null && targets.isEmpty) {
    throw UsageError('nothing to mutate: give files or globs, or --plan');
  }
  return RunCommandArgs(
    RunArgs(
      root: root,
      plan: plan,
      report: report,
      html: html,
      force: force,
      jobs: jobs,
      schemata: schemata,
      only: only,
      targets: targets,
      command: command,
    ),
  );
}

const help = '''
dart_mutant: mutation testing for Dart and Flutter.

Usage:
  dart_mutant run [options] <file or glob>... [-- <test command>]
  dart_mutant run [options] --plan <plan.json> [-- <test command>]
  dart_mutant --version | --help

Each file is changed in one place at a time (a mutant) and its tests are run
on it. A mutant the tests do not notice survived.

With more than one job the mutants are put into copies of the package (in
.dart_tool/dart_mutant/work) and your files are not written. With one job
the files are changed in place and put back.

Options:
  --root <dir>     The package to mutate (default: the current directory).
                   The files and globs, and the paths inside a plan, are
                   relative to it.
  --plan <file>    A JSON file (a path as your shell sees it) that lists the
                   files to mutate and, for each, the test files to run:
                     {"version": 1, "targets": [
                       {"file": "lib/a.dart", "tests": ["test/a_test.dart"]}]}
                   Without it the tests of lib/a.dart are lib/a_test.dart and
                   test/a_test.dart, whichever exist.
  --only <file>    Limit the run to this file of the plan or of the arguments.
                   May be given more than once. The report keeps what it says
                   about the other files.
  --report <path>  Where the report is written (a path as your shell sees it;
                   default: reports/mutation/mutation.json in the package),
                   in the mutation-testing-elements JSON schema.
  --html <path>    Also write the report as a page for a browser (a path as
                   your shell sees it, ending in .html). The report is in
                   the page; the viewer
                   (mutation-testing-elements) is loaded from a CDN when the
                   page is opened.
  --force          Run every mutant again. Without it the results of a file
                   are reused while the file, its tests, the test command
                   and the version of this tool are the same.
  --jobs <n>       How many test runs are started at a time (default: a
                   quarter of the processors, at least 1 and at most 4).
                   1 changes the files in place, one mutant at a time.
  -h, --help       This text.
  --version        The version of this tool.
  -- <command>     The command that runs test files (default:
                   "flutter test --no-pub" for a Flutter package, "dart test"
                   otherwise). "--fail-fast --timeout 10s" and the test files
                   are appended to it.

Exit code:
  0    no mutant survived
  1    a mutant survived, or a file could not be mutation tested, or
       another run is at work in the package (nothing is changed then)
  2    wrong usage
  130 / 143 / 129   interrupted (SIGINT / SIGTERM / SIGHUP); the working
                   copies were removed, or the files were put back''';
