// The mutation test of this package, by this package:
//
//   dart run tool/self_mutation.dart [--gate <path>]... [--force] [--jobs <n>]
//       [--schemata | --no-schemata]
//
// 1. The gates of test-gates.json become a plan: each gate with its test.
// 2. `dart_mutant run --plan` (the code of this checkout) mutates them and
//    writes the report, and a page to look at.
// 3. `test_gates mutation-result` reads the report and judges it with the
//    allowances of test-gates.json: every survivor has to be listed there as
//    an equivalent mutant, with a reason.
//
// The exit code is the verdict of step 3, or the one of step 2 when the run
// could not be done.
import 'dart:convert';
import 'dart:io';

const _plan = 'reports/mutation/plan.json';
const _report = 'reports/mutation/mutation.json';
const _page = 'reports/mutation/mutation.html';

/// The tests of a gate beside its own (`lib/src/a.dart` → `test/a_test.dart`).
const _more = {
  // The contract with test_gates 0.1.0: the same mutants for the same source.
  'lib/src/syntax_mutators.dart': ['test/compat_test.dart'],
};

Future<int> _run(List<String> arguments) async {
  stdout.writeln('\$ dart ${arguments.join(' ')}');
  final process = await Process.start(
    Platform.resolvedExecutable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

Future<void> main(List<String> arguments) async {
  final gates = <String>[];
  final passed = <String>[];
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--gate' && index + 1 < arguments.length) {
      gates.add(arguments[++index]);
    } else if (argument == '--force' ||
        argument == '--schemata' ||
        argument == '--no-schemata') {
      passed.add(argument);
    } else if (argument == '--jobs' && index + 1 < arguments.length) {
      passed.addAll([argument, arguments[++index]]);
    } else {
      stderr.writeln(
        'usage: dart run tool/self_mutation.dart [--gate <path>]... '
        '[--force] [--jobs <n>] [--schemata | --no-schemata]',
      );
      exitCode = 2;
      return;
    }
  }

  final manifest =
      jsonDecode(File('test-gates.json').readAsStringSync())
          as Map<String, Object?>;
  final paths = [
    for (final gate in manifest['gates']! as List)
      (gate as Map<String, Object?>)['path']! as String,
  ];
  File(_plan)
    ..createSync(recursive: true)
    ..writeAsStringSync(
      jsonEncode({
        'version': 1,
        'targets': [
          for (final path in paths)
            {
              'file': path,
              'tests': [
                path
                    .replaceFirst('lib/src/', 'test/')
                    .replaceFirst(RegExp(r'\.dart$'), '_test.dart'),
                ...?_more[path],
              ],
            },
        ],
      }),
    );

  // A run that is turned away (another one is at work in the package)
  // leaves the report of an earlier run as it is. That one must not be
  // judged as if it were this run's.
  DateTime? written() =>
      File(_report).existsSync() ? File(_report).lastModifiedSync() : null;
  final before = written();
  final started = DateTime.now();

  final mutation = await _run([
    'run',
    'bin/dart_mutant.dart',
    'run',
    '--plan',
    _plan,
    '--report',
    _report,
    '--html',
    _page,
    for (final gate in gates) ...['--only', gate],
    ...passed,
  ]);
  // 0: no survivor. 1: survivors, which the next step judges, or a run that
  // wrote no report, which the next step refuses.
  if (mutation != 0 && mutation != 1) {
    exitCode = mutation;
    return;
  }
  final after = written();
  if (after != null && after == before && after.isBefore(started)) {
    stderr.writeln(
      'self_mutation: the run wrote no report ($_report is the one of an '
      'earlier run). Nothing was judged',
    );
    exitCode = 1;
    return;
  }
  exitCode = await _run([
    'run',
    'test_gates',
    'mutation-result',
    '--report',
    _report,
    for (final gate in gates) ...['--gate', gate],
  ]);
}
