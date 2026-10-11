import 'shard.dart';

/// Whether the mutants of a file are built into one program when neither
/// `--schemata` nor `--no-schemata` is given.
const schemataByDefault = false;

/// The command line of `dart_mutant run`.
class RunArgs {
  const RunArgs({
    this.dir = '.',
    this.plan,
    this.report,
    this.html,
    this.force = false,
    this.jobs,
    this.shard,
    this.schemata,
    this.only = const [],
    this.targets = const [],
    this.command = const [],
  });

  /// `--dir`: the package to mutate.
  final String dir;

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

  /// `--shard`: the part of the mutants of each file that this run takes,
  /// when the run is divided.
  final Shard? shard;

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

/// The command line of `dart_mutant merge`.
class MergeArgs {
  const MergeArgs({required this.parts, required this.report, this.html});

  /// The reports of the parts of a run with `--shard`.
  final List<String> parts;

  /// `--report`: where the report of the whole run is written.
  final String report;

  /// `--html`: where it is written as a page for a browser, when that is
  /// wanted.
  final String? html;
}

class MergeCommandArgs extends ParsedArgs {
  const MergeCommandArgs(this.merge);

  final MergeArgs merge;
}

class UsageError implements Exception {
  UsageError(this.message);

  final String message;

  @override
  String toString() => message;
}

const _valueOptions = [
  '--dir',
  '--plan',
  '--report',
  '--html',
  '--only',
  '--jobs',
  '--shard',
];

/// The options that take no value.
const _flags = ['--force', '--schemata', '--no-schemata'];

const _options = [..._valueOptions, ..._flags];

/// The options of `merge`, of those above.
const _mergeOptions = ['--report', '--html'];

/// Reads the command line. Throws [UsageError] for anything it does not
/// know: a misspelled option must not become a run of something else.
ParsedArgs parseArgs(List<String> argv) {
  // What is in front of the first `--` is for this tool; the rest is the
  // `--` and the test command behind it, or nothing.
  final own = argv.takeWhile((argument) => argument != '--').toList();
  final rest = argv.skip(own.length).toList();
  final command = rest.skip(1).toList();
  if (own.contains('--version') || own.contains('-v')) {
    return const VersionArgs();
  }
  if (own.contains('--help') || own.contains('-h')) {
    return const HelpArgs();
  }
  if (own.isEmpty) {
    throw UsageError('no command given');
  }
  final merge = own.first == 'merge';
  if (own.first != 'run' && !merge) {
    throw UsageError('unknown command: ${own.first}');
  }
  if (merge && rest.isNotEmpty) {
    throw UsageError('merge runs no tests: "--" and a command do not belong');
  }
  if (rest.isNotEmpty && command.isEmpty) {
    throw UsageError('"--" must be followed by the command that runs tests');
  }

  var dir = '.';
  String? plan;
  String? report;
  String? html;
  var force = false;
  int? jobs;
  Shard? shard;
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
    if (!_options.contains(name) || (merge && !_mergeOptions.contains(name))) {
      throw UsageError(
        'unknown argument for ${merge ? 'merge' : 'run'}: $argument',
      );
    }
    if (!_valueOptions.contains(name)) {
      if (inline) {
        throw UsageError('$name does not take a value');
      }
      if (name == '--force') {
        force = true;
        continue;
      }
      if (schemata != null) {
        throw UsageError('--schemata or --no-schemata is given twice');
      }
      schemata = name == '--schemata';
      continue;
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
      case '--dir':
        dir = value;
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
      case '--shard':
        shard = parseShard(value);
        if (shard == null) {
          throw UsageError(
            '--shard needs <index>/<count>, with an index from 1 to the '
            'count ("$value")',
          );
        }
    }
  }
  if (merge) {
    if (targets.isEmpty) {
      throw UsageError(
        'nothing to merge: give the reports of the parts of a run with '
        '--shard',
      );
    }
    if (report == null) {
      throw UsageError('merge needs --report: where the report is written');
    }
    return MergeCommandArgs(
      MergeArgs(parts: targets, report: report, html: html),
    );
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
      dir: dir,
      plan: plan,
      report: report,
      html: html,
      force: force,
      jobs: jobs,
      shard: shard,
      schemata: schemata,
      only: only,
      targets: targets,
      command: command,
    ),
  );
}

const help = '''
dart_mutant — mutation testing for Dart and Flutter

Usage:
  dart_mutant run [options] <file or glob>... [-- <test command>]
  dart_mutant run [options] --plan <plan.json> [-- <test command>]
  dart_mutant merge <part.json>... --report <path> [--html <path>]
  dart_mutant --version | --help

Each file is changed in one place at a time (a mutant) and its tests are run
on it. A mutant the tests do not notice survived.

With more than one job the mutants are put into copies of the package (in
.dart_tool/dart_mutant/work) and your files are not written. With one job
the files are changed in place and put back.

Options:
  --dir <package>  The package to mutate (default: .). The files and
                   globs, and the paths inside a plan, are relative to it.
  --plan <file>    A JSON file (a path as your shell sees it) that lists the
                   files to mutate and, for each, the test files to run:
                     {"version": 1, "targets": [
                       {"file": "lib/a.dart", "tests": ["test/a_test.dart"]}]}
                   A key it does not know is wrong usage. Without a plan the
                   tests of lib/a.dart are lib/a_test.dart and
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
  --shard <i>/<n>  Run part i of n of the mutants of each file (mutant
                   number modulo n), for a run that is divided over several
                   machines. The report is then a part: the other mutants
                   are in it as Pending.
  --schemata       Experimental. Build the mutants of a file into one
                   program and run its tests on all of them in one process,
                   instead of one start of the test runner per mutant. Only
                   "killed" is taken from that; every other mutant is run
                   the usual way, and so is what cannot be built in. Always
                   in working copies. "--reporter json" is appended to the
                   test command as well.
  --no-schemata    One start of the test runner per mutant (the default).
  -h, --help       Show this help
  -v, --version    Show the version
  -- <command>     The command that runs test files (default:
                   "flutter test --no-pub" for a Flutter package, "dart test"
                   otherwise). "--fail-fast --timeout 10s" and the test files
                   are appended to it.

merge puts the reports of the parts 1 to n of one run with --shard together
and writes the report of the whole run to --report (and to --html as a
page). It fails when a part is missing or given twice, or when the parts
are not of the same run: another number of parts, other sources or
mutants, another version of this tool.

Exit codes:
  0    no mutant survived
  1    a mutant survived, or a file could not be mutation tested, or
       another run is at work in the package (nothing is changed then),
       or the parts given to merge are not the parts of one run (no
       report is written then)
  2    wrong usage, or a plan file that cannot be used
  130 / 143 / 129   interrupted (SIGINT / SIGTERM / SIGHUP); the working
                   copies were removed, or the files were put back''';
