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
//
// For the workflow (.github/workflows/mutation.yml), which runs each gate in
// a job of its own and the gates of [_shards] in several:
//
//   dart tool/self_mutation.dart --matrix
//       prints the jobs as JSON: one per gate, or one per part of a gate.
//   dart run tool/self_mutation.dart --gate <path> --shard <i>/<n> ...
//       runs that part (`dart_mutant run --shard`) and judges nothing: a
//       part is no result. With 1/1 it is the run of the whole gate, above.
//   dart run tool/self_mutation.dart --merge <directory>
//       puts the parts of every gate of [_shards] together (`dart_mutant
//       merge`, which fails when one is missing) and judges each.
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

/// The gates whose mutation test is divided into parts in the workflow, and
/// into how many. Every other gate is one job.
///
/// This is the one place that says so: the jobs (`--matrix`), the check of
/// `--shard`, and what `--merge` expects are all read from here. A path
/// that is not a gate is an error, so an entry does not outlive its gate.
///
/// What costs is the time of one test run times the mutants that compile,
/// so the number is chosen by the time a gate took in the workflow, not by
/// its number of mutants: the tests of these two open an analysis session,
/// or run two implementations side by side.
const _shards = {
  'lib/src/typed_mutators.dart': 4,
  'lib/src/syntax_mutators.dart': 2,
};

/// A name for [gate] that can be part of the name of an artifact and of a
/// file: `lib/src/a_b.dart` → `lib-src-a_b`.
String _slug(String gate) => gate
    .replaceFirst(RegExp(r'\.dart$'), '')
    .replaceAll(RegExp('[^A-Za-z0-9_]+'), '-');

/// The name of the artifact that holds part [index] of [count] of [gate].
String _partName(String gate, int index, int count) =>
    'mutation-part-${_slug(gate)}-$index-of-$count';

Future<int> _run(List<String> arguments) async {
  stdout.writeln('\$ dart ${arguments.join(' ')}');
  final process = await Process.start(
    Platform.resolvedExecutable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

Never _usage() {
  stderr.writeln(
    'usage: dart run tool/self_mutation.dart [--gate <path>]... [--force] '
    '[--jobs <n>] [--shard <i>/<n>] [--schemata | --no-schemata]\n'
    '       dart run tool/self_mutation.dart --merge <directory>\n'
    '       dart tool/self_mutation.dart --matrix',
  );
  exit(2);
}

Never _fail(String message) {
  stderr.writeln('self_mutation: $message');
  exit(1);
}

Future<void> main(List<String> arguments) async {
  final gates = <String>[];
  final passed = <String>[];
  String? shard;
  String? merge;
  var matrix = false;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    final value = index + 1 < arguments.length ? arguments[index + 1] : null;
    if (argument == '--gate' && value != null) {
      gates.add(value);
      index++;
    } else if (argument == '--force' ||
        argument == '--schemata' ||
        argument == '--no-schemata') {
      passed.add(argument);
    } else if (argument == '--jobs' && value != null) {
      passed.addAll([argument, value]);
      index++;
    } else if (argument == '--shard' && value != null) {
      shard = value;
      index++;
    } else if (argument == '--merge' && value != null) {
      merge = value;
      index++;
    } else if (argument == '--matrix') {
      matrix = true;
    } else {
      _usage();
    }
  }

  final manifest =
      jsonDecode(File('test-gates.json').readAsStringSync())
          as Map<String, Object?>;
  final paths = [
    for (final gate in manifest['gates']! as List)
      (gate as Map<String, Object?>)['path']! as String,
  ];
  for (final MapEntry(key: gate, value: count) in _shards.entries) {
    if (!paths.contains(gate) || count < 2) {
      _fail(
        '_shards names $gate with $count part(s): it has to be a gate of '
        'test-gates.json, in 2 parts or more',
      );
    }
  }

  // The names of the artifacts and of the merged reports are made of them.
  if (paths.map(_slug).toSet().length != paths.length) {
    _fail('two gates of test-gates.json have the same name without "/"');
  }

  if (matrix) {
    if (arguments.length != 1) {
      _usage();
    }
    // One line, for $GITHUB_OUTPUT.
    stdout.writeln(
      jsonEncode({
        'include': [
          for (final gate in paths)
            for (var index = 1; index <= (_shards[gate] ?? 1); index++)
              {
                'gate': gate,
                'shard': '$index/${_shards[gate] ?? 1}',
                'name': _shards.containsKey(gate)
                    ? '$gate ($index/${_shards[gate]})'
                    : gate,
                'artifact': _shards.containsKey(gate)
                    ? _partName(gate, index, _shards[gate]!)
                    : 'mutation-report-${_slug(gate)}',
              },
        ],
      }),
    );
    return;
  }

  if (merge != null) {
    if (arguments.length != 2) {
      _usage();
    }
    exitCode = await _merge(merge);
    return;
  }

  // The part of a gate: the workflow gives every job its `--shard`, and
  // only the gates of [_shards] are run in parts.
  var part = false;
  if (shard != null) {
    if (gates.length != 1) {
      _fail('--shard needs exactly one --gate');
    }
    final count = _shards[gates.single] ?? 1;
    if (![
      for (var index = 1; index <= count; index++) '$index/$count',
    ].contains(shard)) {
      _fail(
        '--shard $shard: ${gates.single} is run in $count part(s) '
        '(_shards in tool/self_mutation.dart)',
      );
    }
    part = count > 1;
  }

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
    if (part) ...['--shard', shard!],
    ...passed,
  ]);
  // 0: no survivor. 1: survivors, which the next step judges, or a run that
  // wrote no report, which the next step refuses.
  if (mutation != 0 && mutation != 1) {
    exitCode = mutation;
    return;
  }
  final after = written();
  if (after == null ||
      (after == before && after.isBefore(started)) ||
      (part && !_isPart(File(_report)))) {
    stderr.writeln(
      'self_mutation: the run wrote no report ($_report is '
      '${after == null ? 'not there' : 'the one of an earlier run'}). '
      'Nothing was judged',
    );
    exitCode = 1;
    return;
  }
  if (part) {
    // A part is no result: its survivors, and a file that could not be
    // tested (which the part names), are for `--merge`.
    stdout.writeln(
      'self_mutation: part $shard of ${gates.single} is in $_report. It is '
      'judged when the parts are put together (--merge)',
    );
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

bool _isPart(File report) {
  final config = (jsonDecode(report.readAsStringSync()) as Map)['config'];
  return config is Map && config['shard'] is Map;
}

/// Puts the parts of every gate of [_shards] together and judges each. The
/// parts are looked for in [directory], each in a directory with the name
/// of its artifact (as `actions/download-artifact` leaves them).
///
/// Which parts there have to be is not decided here: whatever is found is
/// given to `dart_mutant merge`, which refuses parts that are not all the
/// parts of one run.
Future<int> _merge(String directory) async {
  var failed = false;
  for (final MapEntry(key: gate, value: count) in _shards.entries) {
    final slug = _slug(gate);
    final parts = [
      for (var index = 1; index <= count; index++)
        File('$directory/${_partName(gate, index, count)}/mutation.json'),
    ].where((part) => part.existsSync()).toList();
    stdout.writeln('== $gate: ${parts.length} of $count part(s) found');
    if (parts.isEmpty) {
      stderr.writeln('self_mutation: no part of $gate is in $directory');
      failed = true;
      continue;
    }
    final report = 'reports/mutation/merged/$slug.json';
    final merged = await _run([
      'run',
      'bin/dart_mutant.dart',
      'merge',
      for (final part in parts) part.path,
      '--report',
      report,
      '--html',
      'reports/mutation/merged/$slug.html',
    ]);
    // 0: no survivor. 1: survivors, which the next step judges, or parts
    // that do not fit, for which no report is written.
    if ((merged != 0 && merged != 1) || !File(report).existsSync()) {
      stderr.writeln('self_mutation: the parts of $gate were not merged');
      failed = true;
      continue;
    }
    final verdict = await _run([
      'run',
      'test_gates',
      'mutation-result',
      '--report',
      report,
      '--gate',
      gate,
    ]);
    failed = failed || verdict != 0;
  }
  return failed ? 1 : 0;
}
