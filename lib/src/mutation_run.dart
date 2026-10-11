import 'dart:convert';

import 'json.dart';
import 'mutant.dart';
import 'plan.dart';
import 'shard.dart';
import 'typed_mutators.dart';
import 'version.dart';

/// The statuses of a mutant, as the report spells them.
const killed = 'Killed';
const survived = 'Survived';
const timeout = 'Timeout';
const compileError = 'CompileError';

/// The status of a mutant that a run with `--shard` left to another part.
/// The report schema has it for a mutant that is not evaluated yet; a
/// report with such a mutant is not a result.
const notRun = 'Pending';

/// The limit of one test, passed to the test runner as `--timeout`. A test
/// that waits for something a mutant no longer does then fails (Killed)
/// instead of holding the run for the 30 seconds of the runner's default.
const perTestTimeoutSeconds = 10;

/// How long the test run of one mutant may take: three times the run without
/// a mutant, plus 20 seconds. Only a mutant that keeps the process itself
/// from ending (a loop that never yields) gets this far; it is a Timeout.
Duration processLimit(Duration baseline) =>
    baseline * 3 + const Duration(seconds: 20);

/// How long the run without a mutant may take.
const baselineLimit = Duration(minutes: 10);

final _flutterSdk = RegExp(r'^\s+sdk:\s*flutter\s*(#.*)?$', multiLine: true);

/// True when the pubspec has a dependency from the Flutter SDK: the tests
/// then need `flutter test`.
bool usesFlutter(String pubspec) =>
    _flutterSdk.hasMatch(pubspec.replaceAll('\r\n', '\n'));

/// The command that runs test files, program first: [override] when given,
/// else `flutter test --no-pub` for a Flutter package and `dart test` for any
/// other.
List<String> testCommandFor({
  required bool flutter,
  List<String> override = const [],
}) => override.isNotEmpty
    ? override
    : flutter
    ? const ['flutter', 'test', '--no-pub']
    : const ['dart', 'test'];

/// [command] for the test files [tests]: the first failing test ends the
/// run, and a test gets [perTestTimeoutSeconds].
List<String> mutantCommand(List<String> command, List<String> tests) => [
  ...command,
  '--fail-fast',
  '--timeout',
  '${perTestTimeoutSeconds}s',
  ...tests,
];

/// The compiler's `file.dart:12:3: Error: ...`, and what `flutter test`
/// prints when a test file cannot be loaded.
final _compileError = RegExp(r'(\.dart:\d+:\d+: Error: |Compilation failed)');

/// The status of a mutant from the test run on it.
///
/// - the process limit was reached, of time or of memory → `Timeout`
/// - the tests passed → `Survived`
/// - the code did not compile → `CompileError` (nothing was evaluated)
/// - anything else → `Killed`
String classifyRun({
  required int? exitCode,
  required String output,
  required bool timedOut,
}) {
  if (timedOut) {
    return timeout;
  }
  if (exitCode == 0) {
    return survived;
  }
  return _compileError.hasMatch(output) ? compileError : killed;
}

/// 1-based line and column of [offset]. Lines end at `\n`; a `\r` before it
/// belongs to the line.
({int line, int column}) positionOf(String source, int offset) {
  final before = source.substring(0, offset);
  return (
    line: '\n'.allMatches(before).length + 1,
    // lastIndexOf gives -1 on the first line, whose start is 0.
    column: offset - before.lastIndexOf('\n'),
  );
}

/// The mutants of a file as a run numbers them: the syntax mutants first, as
/// test_gates 0.1.0 numbered them, then the typed ones. Each list is in the
/// order of the source.
///
/// A typed mutator added later then changes no number of a syntax mutant.
///
/// A typed mutant that makes the same program of [source] as a mutant before
/// it is left out: two mutators can arrive at the same text (the result of
/// one guard given to the next, and `return null` → `return 0`), and the
/// second test run would only repeat the first.
List<Mutant> numbered(String source, List<Mutant> syntax, List<Mutant> typed) {
  final programs = {for (final mutant in syntax) mutant.applyTo(source)};
  return [
    ...syntax,
    for (final mutant in typed)
      if (programs.add(mutant.applyTo(source))) mutant,
  ];
}

/// What a run knows about one mutant.
class MutantResult {
  const MutantResult(
    this.mutant,
    this.status, {
    this.milliseconds = 0,
    this.reason,
  });

  final Mutant mutant;
  final String status;

  /// How long the test run took. 0 when no test was run: the mutant does
  /// not compile, or the result is taken from an earlier run.
  final int milliseconds;

  /// For a `CompileError` that the analyzer found before a test was run:
  /// its message. `null` for one that only showed in the test run. For a
  /// `Timeout` of a test run that was ended for the memory it used: that.
  final String? reason;

  /// True when no test had to be run to know that this does not compile.
  bool get refusedBeforeRun => status == compileError && reason != null;
}

/// What a run found out about one file.
class FileRun {
  const FileRun({required this.source, required this.results});

  /// The file as it was mutated.
  final String source;

  /// One per mutant, as [numbered].
  final List<MutantResult> results;

  int count(String status) =>
      results.where((result) => result.status == status).length;

  int get refusedBeforeRun =>
      results.where((result) => result.refusedBeforeRun).length;
}

/// The report of a run in the mutation-testing-elements JSON schema,
/// version 2 (the schema of the Stryker tools), so that the viewers and
/// dashboards made for that schema can open it.
///
/// [others] are the files of an earlier report that this run did not touch
/// (see [otherReportFiles]). They are written as they were.
///
/// `thresholds` is required by the schema and only colours a viewer. This
/// tool has no threshold: the exit code depends on the survivors alone.
///
/// With [shard] the report is a part of a run (see [reportConfig]), and
/// [notTested] are the files of the run that are not in it because they
/// could not be mutation tested.
JsonObject buildReport(
  Map<String, FileRun> files, {
  JsonObject others = const {},
  Shard? shard,
  List<String> notTested = const [],
}) => {
  'schemaVersion': '2',
  'thresholds': {'high': 100, 'low': 100},
  'framework': {'name': 'dart_mutant', 'version': packageVersion},
  'config': reportConfig(shard: shard, notTested: notTested),
  'files': {
    ...others,
    for (final MapEntry(key: path, value: run) in files.entries)
      path: {
        'language': 'dart',
        'source': run.source,
        'mutants': [
          for (final (index, result) in run.results.indexed)
            {
              'id': '$path#$index',
              'mutatorName': result.mutant.mutator,
              'replacement': result.mutant.replacement,
              'status': result.status,
              'statusReason': ?result.reason,
              'duration': result.milliseconds,
              'location': {
                'start': _json(positionOf(run.source, result.mutant.offset)),
                'end': _json(positionOf(run.source, result.mutant.end)),
              },
            },
        ],
      },
  },
};

JsonObject _json(({int line, int column}) position) => {
  'line': position.line,
  'column': position.column,
};

/// True when [text] is a report as [buildReport] writes it, or as another
/// tool writes it in the same schema: a JSON object with `files`.
bool isReport(String text) {
  try {
    return asObject(asObject(jsonDecode(text))?['files']) != null;
  } on FormatException {
    return false;
  }
}

/// What a run that is limited to the files [selected] keeps of the report
/// that is already there ([existing], `null` when there is none): the other
/// files, as they are written. Nothing is kept of a file that is not a
/// report, and nothing of a part of a run with `--shard`: its mutants of
/// the other parts are not evaluated, and in the report of a whole run
/// nothing would say so.
JsonObject otherReportFiles(String? existing, List<String> selected) {
  if (existing == null) {
    return {};
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(existing);
  } on FormatException {
    return {};
  }
  if (partOf(decoded) != null) {
    return {};
  }
  final files = asObject(asObject(decoded)?['files']) ?? {};
  final left = selected.map(normalizePath).toSet();
  return {
    for (final MapEntry(key: path, :value) in files.entries)
      if (!left.contains(normalizePath(path))) path: value,
  };
}

/// What a run starts from in the file of the results of the last run
/// ([saved], path → entry) and writes back with its own results.
///
/// Without `--force` that is everything. With it nothing of the files of
/// this run ([targets]) may be left, also when the run does not get to them:
/// the next run must not reuse what `--force` was given to measure again.
JsonObject carriedResults(
  JsonObject saved, {
  required bool force,
  required List<String> targets,
}) => {
  for (final MapEntry(key: path, :value) in saved.entries)
    if (!force || !targets.contains(path)) path: value,
};

/// What decides the result of a file: when all of it is the same as in an
/// earlier run, that run's mutants and statuses are still true.
///
/// A file that the mutated file or its tests import is not part of it: a
/// change there is only seen by a run with `--force`.
class FileInput {
  const FileInput({
    required this.source,
    required this.tests,
    required this.command,
  });

  /// The file that is mutated.
  final String source;

  /// The test files: path → content.
  final Map<String, String> tests;

  /// The test command, without the test files.
  final List<String> command;

  JsonObject toJson() => {
    'toolVersion': packageVersion,
    'mutatorsVersion': mutatorsVersion,
    'command': command,
    'source': source,
    'tests': tests,
  };
}

/// What is kept of a file for [reusableResults] of a later run.
JsonObject incrementalEntry(FileInput input, List<MutantResult> results) => {
  'input': input.toJson(),
  'mutants': [
    for (final result in results)
      {
        'mutator': result.mutant.mutator,
        'offset': result.mutant.offset,
        'end': result.mutant.end,
        'replacement': result.mutant.replacement,
        'status': result.status,
        'reason': ?result.reason,
      },
  ],
};

/// The mutants that an earlier run ([entry], as [incrementalEntry] wrote it)
/// made of exactly [input], with what it found, or `null` when that run was
/// on something else.
///
/// The status of a `Timeout` is given as `null`, and so is its reason: it
/// can come from the load of the machine, so it is measured again. So is
/// the status of a mutant that run left to another part (`--shard`): it has
/// none yet.
List<({Mutant mutant, String? status, String? reason})>? reusableResults(
  Object? entry,
  FileInput input,
) {
  final object = asObject(entry);
  final mutants = object?['mutants'];
  if (object == null ||
      mutants is! List ||
      !sameJson(object['input'], input.toJson())) {
    return null;
  }
  final found = <({Mutant mutant, String? status, String? reason})>[];
  for (final item in mutants) {
    final mutant = asObject(item);
    final mutator = mutant?['mutator'];
    final offset = mutant?['offset'];
    final end = mutant?['end'];
    final replacement = mutant?['replacement'];
    final status = mutant?['status'];
    final reason = mutant?['reason'];
    if (mutator is! String ||
        offset is! int ||
        end is! int ||
        replacement is! String ||
        status is! String ||
        (reason != null && reason is! String) ||
        offset < 0 ||
        end < offset ||
        end > input.source.length) {
      return null;
    }
    found.add((
      mutant: Mutant(mutator, offset, end, replacement),
      status: status == timeout || status == notRun ? null : status,
      // Why a run was ended is true of that run only.
      reason: status == timeout ? null : reason as String?,
    ));
  }
  return found;
}

String _seconds(int milliseconds) => (milliseconds / 1000).toStringAsFixed(1);

String _counts(Iterable<FileRun> runs) {
  int sum(int Function(FileRun run) of) =>
      runs.fold(0, (total, run) => total + of(run));
  final refused = sum((run) => run.refusedBeforeRun);
  final all = sum((run) => run.results.length);
  // Only in a part of a run with --shard.
  final left = sum((run) => run.count(notRun));
  return '${left == 0 ? '' : '${all - left} of '}$all mutants '
      '/ killed ${sum((run) => run.count(killed))} '
      '/ survived ${sum((run) => run.count(survived))} '
      '/ timeout ${sum((run) => run.count(timeout))} '
      '/ compile error ${sum((run) => run.count(compileError))}'
      '${refused == 0 ? '' : ' ($refused found before the run)'}';
}

/// The line that says what a run found for one file. [reused] is the number
/// of mutants whose result is taken from the last run.
String fileLine(
  String path,
  FileRun run, {
  required int reused,
  required int milliseconds,
}) =>
    '  $path: ${_counts([run])} '
    '(${reused == 0 ? '' : '$reused from the last run, '}'
    '${_seconds(milliseconds)}s)';

/// The counts of a whole run, for its last line.
String totalCounts(Iterable<FileRun> runs) => _counts(runs);

String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// The mutants no test noticed, one line each:
/// `file:line:column Mutator: original → replacement`. Text that spans lines
/// is shown on one; the report has it as it is.
List<String> survivorLines(Map<String, FileRun> files) => [
  for (final MapEntry(key: path, value: run) in files.entries)
    for (final result in run.results)
      if (result.status == survived)
        () {
          final at = positionOf(run.source, result.mutant.offset);
          final original = run.source.substring(
            result.mutant.offset,
            result.mutant.end,
          );
          return '  $path:${at.line}:${at.column} ${result.mutant.mutator}: '
              '${_oneLine(original)} → ${_oneLine(result.mutant.replacement)}';
        }(),
];
