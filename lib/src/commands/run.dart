import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../args.dart';
import '../driver.dart';
import '../io/analysis.dart';
import '../io/files.dart';
import '../io/lock.dart';
import '../io/process.dart';
import '../io/report_files.dart';
import '../io/work_copies.dart';
import '../json.dart';
import '../memory.dart';
import '../mutant.dart';
import '../mutation_run.dart';
import '../output.dart';
import '../parallel.dart';
import '../plan.dart';
import '../schemata.dart';
import '../shard.dart';
import '../syntax_mutators.dart';
import 'built_in.dart';

/// Where a run keeps what must survive it, below the package. `.dart_tool`
/// is ignored by git in every Dart project.
const stateDir = '.dart_tool/dart_mutant';

/// Where the report goes when `--report` does not say, below the package.
const defaultReport = 'reports/mutation/mutation.json';

String _inPackage(String root, String relativePath) =>
    p.joinAll([root, ...relativePath.split('/')]);

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) {
      return false;
    }
  }
  return true;
}

String _reason(FileSystemException error) =>
    error.osError?.message ?? error.message;

/// The files of a run below [stateDir].
class _State {
  _State(String root) : dir = _inPackage(root, stateDir);

  final String dir;

  Directory get backups => Directory(p.join(dir, 'backup'));

  /// The copy of a file as it was before the run changed it.
  File backupOf(String path) => File(_inPackage(backups.path, path));

  /// The copy of the mutant that the run put in a file last. What a killed
  /// run left behind is recognised by it.
  File placedOf(String path) => File(_inPackage(p.join(dir, 'placed'), path));

  File get incremental => File(p.join(dir, 'incremental.json'));

  /// The file whose lock keeps a second run out of the package.
  String get lock => p.join(dir, 'lock');

  /// Where the working copies of a run with more than one job are.
  String get work => p.join(dir, 'work');

  File get _staging => File(p.join(dir, 'staging'));

  /// Gives [target] the content [bytes] in one step: the content is written
  /// next to the backups and renamed over the file, so the file is never
  /// half-written, whenever the process dies.
  void put(File target, List<int> bytes) {
    _staging.parent.createSync(recursive: true);
    _staging.writeAsBytesSync(bytes, flush: true);
    _staging.renameSync(target.path);
  }

  void removeStaging() {
    if (_staging.existsSync()) {
      _staging.deleteSync();
    }
  }
}

void _delete(File file) {
  if (file.existsSync()) {
    file.deleteSync();
  }
}

/// A file while a mutant may be in it.
class _Active {
  _Active(this.path, this.file, this.original, this.backup, this.placed);

  final String path;
  final File file;
  final Uint8List original;
  final File backup;
  final File placed;

  /// What the run wrote last, when it is not [original].
  List<int>? written;
}

/// Puts back the files that a killed run (SIGKILL, power loss) left with a
/// mutant in them. Returns what could not be put back.
List<String> _recover(String root, _State state, Io io) {
  final problems = <String>[];
  state.removeStaging();
  if (!state.backups.existsSync()) {
    return problems;
  }
  for (final entity in state.backups.listSync(recursive: true)) {
    if (entity is! File) {
      continue;
    }
    final path = p
        .split(p.relative(entity.path, from: state.backups.path))
        .join('/');
    final file = File(_inPackage(root, path));
    final placed = state.placedOf(path);
    final kept =
        'The content of before that run is in $stateDir/backup/$path; '
        'delete that file when you have compared the two';
    try {
      final original = entity.readAsBytesSync();
      if (!file.existsSync()) {
        problems.add(
          '$path: an interrupted run left a backup of this file, and the file '
          'is gone. $kept',
        );
        continue;
      }
      final current = file.readAsBytesSync();
      if (_sameBytes(original, current)) {
        entity.deleteSync();
        _delete(placed);
        continue;
      }
      // Only what that run wrote itself is overwritten: anything else is
      // somebody's edit.
      if (placed.existsSync() &&
          _sameBytes(placed.readAsBytesSync(), current)) {
        state.put(File(file.resolveSymbolicLinksSync()), original);
        entity.deleteSync();
        _delete(placed);
        io.err(
          '$executable run: put back $path, which an interrupted run left with '
          'a mutant in it',
        );
        continue;
      }
      problems.add(
        '$path: an interrupted run left a mutant in this file, and the file '
        'was changed since. It was left as it is. $kept',
      );
    } on FileSystemException catch (error) {
      problems.add(
        '$path: cannot put back the file of before an interrupted run '
        '(${_reason(error)}). $kept',
      );
    }
  }
  return problems;
}

/// Takes the mutant out of [active]. Returns a message when the file is not
/// as this run left it; the backup is then kept.
String? _restore(_Active active, _State state) {
  final written = active.written;
  if (written == null) {
    return null;
  }
  final kept =
      'The content of before the run is in $stateDir/backup/${active.path}';
  try {
    final current = active.file.readAsBytesSync();
    if (_sameBytes(current, written)) {
      state.put(active.file, active.original);
      active.written = null;
      return null;
    }
    if (_sameBytes(current, active.original)) {
      active.written = null;
      return null;
    }
    return '${active.path} changed during the run. It was left as it is, '
        'possibly with a mutant in it. $kept';
  } on FileSystemException catch (error) {
    return '${active.path}: CANNOT TAKE THE MUTANT OUT (${_reason(error)}). '
        '$kept';
  }
}

JsonObject _readIncremental(_State state) {
  try {
    final decoded = jsonDecode(state.incremental.readAsStringSync());
    return asObject(asObject(decoded)?['files']) ?? {};
  } on FileSystemException {
    return {};
  } on FormatException {
    return {};
  }
}

void _writeIncremental(_State state, JsonObject files) {
  state.incremental.parent.createSync(recursive: true);
  state.incremental.writeAsStringSync(jsonEncode({'files': files}));
}

/// Writes the report of [runs] and [others] to [path], and as a page to
/// [htmlPath] when `--html` asks for one, see [writeReportFiles]. With
/// [shard] it is a part of a run, which says so in the title of the page.
String? _writeReport(
  String path,
  String? htmlPath,
  Map<String, FileRun> runs,
  JsonObject others, {
  Shard? shard,
  List<String> notTested = const [],
}) => writeReportFiles(
  path,
  htmlPath,
  buildReport(runs, others: others, shard: shard, notTested: notTested),
  title: shard == null
      ? 'Mutation report'
      : 'Mutation report, shard ${shard.label}',
);

/// The files to mutate and their tests, from the plan or from the arguments.
/// Throws [UsageError] when the arguments name nothing that can be run, and
/// [PlanError] when the plan cannot be read or is none.
List<Target> _targetsOf(RunArgs args, String root) {
  final planPath = args.plan;
  if (planPath != null) {
    final String text;
    try {
      text = readText(planPath);
    } on FileSystemException catch (error) {
      throw PlanError('cannot read the plan $planPath (${_reason(error)})');
    }
    try {
      return parsePlan(text);
    } on PlanError catch (error) {
      throw PlanError('$planPath: ${error.message}');
    }
  }
  final files = <String>[];
  for (final argument in args.targets) {
    final path = normalizePath(argument);
    // `lib/[id]/page.dart` can be a file as well.
    if (isGlob(path) &&
        !(isPlainRelativePath(path) && existsExact(root, path))) {
      final List<String> matched;
      try {
        matched = dartFilesMatching(root, path);
      } on FormatException catch (error) {
        throw UsageError('"$argument" is not a glob (${error.message})');
      }
      if (matched.isEmpty) {
        throw UsageError(
          '"$argument" matches no .dart file below $root (test files are '
          'not mutated)',
        );
      }
      files.addAll(matched);
    } else if (!isPlainRelativePath(path) || !path.endsWith('.dart')) {
      throw UsageError(
        '"$argument" must be a .dart file inside the package, relative to '
        '$root',
      );
    } else {
      files.add(path);
    }
  }
  return [
    for (final file in files.toSet())
      Target(file, [
        for (final candidate in defaultTestCandidates(file))
          if (existsExact(root, candidate)) candidate,
      ]),
  ];
}

/// The working copies of a run with more than one job: copies of the package
/// below [dir], made when the first file needs them and removed with the
/// run.
class _Copies {
  _Copies(this.root, this.dir, this.jobs);

  /// The package, without symbolic links: a link in it is told from one
  /// out of it by this path.
  final String root;
  final String dir;

  /// True when a copy could not be made. No file after that is tried.
  var failed = false;

  /// How many test runs are started at a time.
  final int jobs;

  final _made = <String>[];

  /// The first [count] copies, made now when they are not there yet.
  List<String> first(int count) {
    while (_made.length < count) {
      final copy = p.join(dir, '${_made.length + 1}');
      try {
        // Not into what a failed attempt left.
        removeDirectory(copy);
        copyPackage(root, copy);
      } on FileSystemException {
        failed = true;
        rethrow;
      }
      _made.add(copy);
    }
    return _made.sublist(0, count);
  }

  void remove() => removeDirectory(dir);
}

/// Runs the tests of [path] on its mutants [pending] (indexes into
/// [mutants]) in [workers] working copies at a time, and writes what it
/// finds into [statuses] and [milliseconds]. The package itself is not
/// written.
///
/// The run without a mutant is done in every copy that is used, at the same
/// time: it shows that the tests pass in the copy, it pays what a first run
/// in a new copy costs, and it is measured under the load the mutants will
/// run under. The slowest of them gives the time limit.
///
/// A mutant that runs into the limit is run once more when the others are
/// done, alone: only one that does not end then either is a `Timeout`.
///
/// The same goes for memory: the run without a mutant that held the most
/// gives the limit ([memoryLimitOf]), a test run that holds more is ended
/// at once, and its mutant is run once more, alone. One that is ended then
/// as well is a `Timeout`, and its entry of [reasons] says why.
///
/// Returns `aborted` when the whole run has to stop, and `inPlace` (why)
/// when the tests do not pass in a copy: the file is then for the run in
/// place, which says whether they pass in the package.
Future<({String? aborted, String? inPlace})> _runInCopies({
  required _Copies copies,
  required int workers,
  required String root,
  required String path,
  required Uint8List original,
  required String source,
  required List<String> tests,
  required List<String> run,
  required String shown,
  required List<Mutant> mutants,
  required List<int> pending,
  required List<String?> statuses,
  required List<String?> reasons,
  required List<int> milliseconds,
  required Duration Function(Duration baseline) limitOf,
  required int Function(int baseline) memoryLimitOf,
  required SignalWatch signals,
  required Io io,
}) async {
  const done = (aborted: null, inPlace: null);
  final List<String> used;
  try {
    used = copies.first(workers);
    // The copies are as old as the run: the file and its tests are taken
    // from the package as they are now.
    for (final copy in used) {
      for (final (index, name) in [path, ...tests].indexed) {
        final bytes = index == 0
            ? original
            : File(_inPackage(root, name)).readAsBytesSync();
        final target = File(_inPackage(copy, name));
        if (!target.existsSync() ||
            !_sameBytes(target.readAsBytesSync(), bytes)) {
          target.parent.createSync(recursive: true);
          target.writeAsBytesSync(bytes, flush: true);
        }
      }
    }
  } on FileSystemException catch (error) {
    return (
      aborted: null,
      inPlace: copies.failed
          ? 'and the files after it are not run from working copies: the '
                'package cannot be copied (${_reason(error)}: ${error.path})'
          : 'cannot be put into a working copy (${_reason(error)}: '
                '${error.path})',
    );
  }

  final baselines = await Future.wait([
    for (final copy in used)
      () async {
        final watch = Stopwatch()..start();
        final memory = MemoryWatch();
        final result = await runCommand(
          run,
          workingDirectory: copy,
          capture: true,
          signals: signals,
          timeout: baselineLimit,
          memory: memory,
        );
        return (result: result, elapsed: watch.elapsed, held: memory.peak);
      }(),
  ]);
  if (signals.signal != null) {
    return done;
  }
  var slowest = Duration.zero;
  var most = 0;
  for (final (:result, :elapsed, :held) in baselines) {
    if (result.exitCode == null && !result.timedOut) {
      return (
        aborted: 'cannot start "$shown" (${result.startError})',
        inPlace: null,
      );
    }
    if (result.exitCode != 0) {
      return (
        aborted: null,
        inPlace: result.timedOut
            ? 'has tests that did not end in a working copy'
            : 'has tests that fail in a working copy '
                  '(exit ${result.exitCode})',
      );
    }
    if (elapsed > slowest) {
      slowest = elapsed;
    }
    if (held > most) {
      most = held;
    }
  }
  final limit = limitOf(slowest);
  final memoryLimit = memoryLimitOf(most);

  String? aborted;
  final limited = <int>[];
  // Those of them that were ended for the memory they held.
  final heavy = <int>{};

  /// The test run on the mutant [index] in [copy]. `null` when the run was
  /// interrupted or the whole run has to stop.
  Future<CommandResult?> onMutant(int index, String copy) async {
    final target = File(_inPackage(copy, path));
    final watch = Stopwatch()..start();
    final CommandResult result;
    try {
      try {
        target.writeAsBytesSync(
          utf8.encode(mutants[index].applyTo(source)),
          flush: true,
        );
        result = await runCommand(
          run,
          workingDirectory: copy,
          capture: true,
          signals: signals,
          timeout: limit,
          memory: MemoryWatch(limit: () => memoryLimit),
        );
      } finally {
        // The next file of the run may import this one.
        target.writeAsBytesSync(original, flush: true);
      }
    } on FileSystemException catch (error) {
      aborted ??=
          '$path: cannot write the mutant into a working copy '
          '(${_reason(error)})';
      return null;
    }
    if (result.signal != null || signals.signal != null) {
      return null;
    }
    if (result.exitCode == null && !result.limited) {
      aborted ??= 'cannot start "$shown" (${result.startError})';
      return null;
    }
    milliseconds[index] = watch.elapsedMilliseconds;
    return result;
  }

  var next = 0;
  Future<void> worker(String copy) async {
    while (next < pending.length && aborted == null && signals.signal == null) {
      final index = pending[next++];
      final result = await onMutant(index, copy);
      if (result == null) {
        return;
      }
      if (result.limited) {
        limited.add(index);
        if (result.overMemory) {
          heavy.add(index);
        }
      } else {
        statuses[index] = classifyRun(
          exitCode: result.exitCode,
          output: result.output,
          timedOut: false,
        );
      }
    }
  }

  await Future.wait([for (final copy in used) worker(copy)]);
  if (signals.signal != null || aborted != null) {
    return (aborted: aborted, inPlace: null);
  }

  // The limit was measured with the other runs going, but the load of the
  // machine is not ours alone. A mutant only is a Timeout when it does not
  // end with the copies to itself either. One that held too much memory is
  // treated the same way: a second measurement, not a verdict at the first.
  var confirmed = 0;
  var confirmedHeavy = 0;
  for (final index in limited..sort()) {
    final result = await onMutant(index, used.first);
    if (result == null) {
      return (aborted: aborted, inPlace: null);
    }
    statuses[index] = classifyRun(
      exitCode: result.exitCode,
      output: result.output,
      timedOut: result.limited,
    );
    if (result.overMemory) {
      reasons[index] = overMemoryReason(memoryLimit);
    }
    if (result.limited) {
      heavy.contains(index) ? confirmedHeavy++ : confirmed++;
    }
  }
  if (limited.length > heavy.length) {
    io.out(
      '  $path: ${limited.length - heavy.length} mutant(s) did not end '
      'within ${limit.inSeconds}s and were run again alone: $confirmed did '
      'not end then either (Timeout)',
    );
  }
  if (heavy.isNotEmpty) {
    io.out(
      '  $path: ${heavy.length} mutant(s) used more than '
      '${megabytes(memoryLimit)} MB of memory, were ended and run again '
      'alone: $confirmedHeavy reached a limit then as well (Timeout)',
    );
  }
  return done;
}

/// Mutation test of the files of a plan, or of the files given as
/// arguments. For each file: the mutants are made from its syntax tree and
/// from its resolved types, the analyzer is asked which of them compile,
/// each of those is put in the file, and the tests of the file are run on
/// it.
///
/// With more than one job (`--jobs`) the mutants are put into copies of the
/// package below [stateDir], several at a time, and the package is not
/// written. With one job, and for what cannot be run from a copy, the files
/// are changed in place, one mutant at a time, and put back after every
/// mutant, on an error and on SIGINT / SIGTERM / SIGHUP. What a killed run
/// leaves behind is put back, or removed, by the next run.
///
/// One run at a time has a package: a second one returns 1 before it
/// changes anything.
///
/// A file whose source, tests, test command and tool version are those of
/// an earlier run is not run again unless `--force` is given.
///
/// [limitOf] gives the time the test run of one mutant may take, from the
/// time of the run without a mutant, and [memoryLimitOf] the memory it may
/// hold, from what the run without a mutant held. They are parameters for
/// the tests of this package only; the command line always uses
/// [processLimit] and [memoryLimit].
///
/// Returns the exit code: 0 when no mutant survived, 1 when one did or a
/// file could not be mutation tested, 130 / 143 / 129 when interrupted.
/// Throws [UsageError] for wrong usage and [PlanError] for a plan that
/// cannot be used, before anything is changed.
Future<int> runMutation(
  RunArgs args,
  Io io, {
  Duration Function(Duration baseline) limitOf = processLimit,
  int Function(int baseline) memoryLimitOf = memoryLimit,
}) async {
  if (!Directory(args.dir).existsSync()) {
    throw UsageError('--dir ${args.dir} is not a directory');
  }
  final root = p.normalize(p.absolute(args.dir));
  final targets = _targetsOf(args, root);
  final selection = selectTargets([
    for (final target in targets) target.file,
  ], args.only);
  if (selection.unknown.isNotEmpty) {
    throw UsageError(
      '--only ${selection.unknown.join(', ')}: not a file of this run',
    );
  }
  final selected = selection.selected;

  final reportPath = args.report ?? _inPackage(root, defaultReport);
  final htmlPath = args.html;
  final oldReport = checkReportTargets(reportPath, htmlPath);
  final state = _State(root);
  // Before anything is written: a second run in the package would take the
  // mutant of the first for what a killed run left behind.
  final RunLock lock;
  try {
    lock = RunLock.acquire(state.lock);
  } on LockHeld catch (held) {
    io.err(
      '$executable run: another $executable run is at work in this package'
      '${held.pid == null ? '' : ' (pid ${held.pid}'
                '${held.started == null ? '' : ', started ${held.started}'})'}'
      '. Nothing was run or changed; run again when it has ended '
      '(the lock is $stateDir/lock)',
    );
    return 1;
  }
  try {
    return await _locked(
      args,
      io,
      root: root,
      state: state,
      targets: targets,
      selected: selected,
      reportPath: reportPath,
      htmlPath: htmlPath,
      oldReport: oldReport,
      limitOf: limitOf,
      memoryLimitOf: memoryLimitOf,
    );
  } finally {
    lock.release();
  }
}

/// [runMutation] from the point where the run has the package to itself.
Future<int> _locked(
  RunArgs args,
  Io io, {
  required String root,
  required _State state,
  required List<Target> targets,
  required List<String> selected,
  required String reportPath,
  required String? htmlPath,
  required String? oldReport,
  required Duration Function(Duration baseline) limitOf,
  required int Function(int baseline) memoryLimitOf,
}) async {
  // A report of an earlier run must not be read as the result of this one
  // if this one writes none. With --only that holds for the files of this
  // run; what the report says about the others is kept.
  // A part of a run (--shard) keeps nothing: it is put together with the
  // other parts of the same run, not with an earlier one.
  final shard = args.shard;
  final others = args.only.isEmpty || shard != null
      ? const <String, Object?>{}
      : otherReportFiles(oldReport, selected);
  // The page of `--html` goes the way of the report.
  if (others.isNotEmpty) {
    _writeReport(reportPath, htmlPath, const {}, others);
  } else {
    if (oldReport != null) {
      File(reportPath).deleteSync();
    }
    if (htmlPath != null) {
      _delete(File(htmlPath));
    }
  }

  // Before anything is run: what a killed run left behind.
  removeDirectory(state.work);
  final leftovers = _recover(root, state, io);
  if (leftovers.isNotEmpty) {
    for (final problem in leftovers) {
      io.err('$executable run: $problem');
    }
    io.err('$executable run: FAILED (nothing was run)');
    return 1;
  }

  var flutter = false;
  var pubspec = '';
  try {
    pubspec = readText(_inPackage(root, 'pubspec.yaml'));
    flutter = usesFlutter(pubspec);
  } on FileSystemException {
    // No pubspec: `dart test` says what is wrong.
  }
  var jobs = args.jobs ?? defaultJobs(Platform.numberOfProcessors);
  // With the mutants built in, every test run is in a working copy, also
  // when they are run one at a time.
  var schemata = args.schemata ?? schemataByDefault;
  String? packageConfig;
  try {
    packageConfig = readText(_inPackage(root, packageConfigPath));
  } on FileSystemException {
    // The obstacle below.
  }
  if (jobs > 1 || schemata) {
    final obstacle = copyObstacle(
      root: root,
      resolvedRoot: Directory(root).resolveSymbolicLinksSync(),
      pubspec: pubspec,
      packageConfig: packageConfig,
    );
    if (obstacle != null) {
      io.err(
        '$executable run: $obstacle, so it cannot be run from working copies. '
        'The mutants are run one at a time, in place (--jobs 1)'
        '${schemata ? ', and are not built into one program' : ''}',
      );
      jobs = 1;
      schemata = false;
    }
  }
  final copies = jobs > 1 || schemata
      ? _Copies(Directory(root).resolveSymbolicLinksSync(), state.work, jobs)
      : null;
  final testLibrary = testLibraryOf(packageConfig, flutter: flutter);
  // True once a file of the package was written by this run.
  var inPlace = false;
  final command = testCommandFor(flutter: flutter, override: args.command);
  final shown = command.join(' ');
  // With --force nothing of the last run is reused for the files of this
  // run; what it found for the others stays in the file.
  final carried = carriedResults(
    _readIncremental(state),
    force: args.force,
    targets: selected,
  );
  if (args.force) {
    // Now, not after the first file: a run that is stopped before it has a
    // result must not leave the old one to be reused.
    _writeIncremental(state, carried);
  }
  final kept = <String, Object?>{};

  final runs = <String, FileRun>{};
  final failures = <String, String>{};
  String? aborted;
  PackageAnalysis? analysis;

  // From here on a signal no longer ends the process: it ends the test run,
  // and the code below puts the file back.
  final signals = SignalWatch();
  try {
    for (final target in targets) {
      final path = target.file;
      if (!selected.contains(path)) {
        continue;
      }
      if (signals.signal != null || aborted != null) {
        break;
      }
      if (!existsExact(root, path)) {
        failures[path] = 'file not found (the check is case-sensitive)';
        continue;
      }
      if (target.tests.isEmpty) {
        failures[path] = args.plan != null
            ? 'the plan lists no test for this file'
            : 'no test found (looked for '
                  '${defaultTestCandidates(path).join(', ')}). Name the '
                  'tests in a plan (--plan) when they are somewhere else';
        continue;
      }
      final missing = [
        for (final test in target.tests)
          if (!existsExact(root, test)) test,
      ];
      if (missing.isNotEmpty) {
        failures[path] =
            'test file not found: ${missing.join(', ')} (the check is '
            'case-sensitive)';
        continue;
      }

      final File file;
      final Uint8List original;
      final String source;
      final Map<String, String> testTexts;
      try {
        file = File(File(_inPackage(root, path)).resolveSymbolicLinksSync());
        original = file.readAsBytesSync();
        testTexts = {
          for (final test in target.tests)
            test: readText(_inPackage(root, test)),
        };
      } on FileSystemException catch (error) {
        failures[path] = 'cannot read the file or its test (${_reason(error)})';
        continue;
      }
      try {
        // The decoder drops a byte order mark; the file keeps it.
        final text = utf8.decode(original);
        source = hasByteOrderMark(original) && !text.startsWith('﻿')
            ? '﻿$text'
            : text;
      } on FormatException {
        failures[path] = 'is not valid UTF-8, so it cannot be written back';
        continue;
      }

      final input = FileInput(
        source: source,
        tests: testTexts,
        command: command,
      );
      final watch = Stopwatch()..start();
      final List<Mutant> mutants;
      final List<String?> statuses;
      final List<String?> reasons;
      // The mutants of the file built into it, when that is asked for and
      // can be done, or else why it is not done.
      BuiltIn? built;
      String? notBuilt;
      final reusable = reusableResults(carried[path], input);
      if (reusable != null) {
        mutants = [for (final result in reusable) result.mutant];
        statuses = [for (final result in reusable) result.status];
        reasons = [for (final result in reusable) result.reason];
      } else {
        final syntax = findSyntaxMutants(source);
        if (syntax.syntaxErrors) {
          failures[path] = 'cannot be read as Dart (syntax error)';
          continue;
        }
        try {
          analysis ??= PackageAnalysis.open(root);
        } on AnalysisUnavailable catch (error) {
          aborted = error.message;
          break;
        }
        try {
          mutants = numbered(
            source,
            syntax.mutants,
            await analysis.typedMutantsOf(path, source),
          );
          // Before a test is run: a mutant that does not compile costs a
          // few milliseconds here and a second or more in a test run.
          reasons = [];
          for (final mutant in mutants) {
            if (signals.signal != null) {
              break;
            }
            reasons.add(
              await analysis.compileErrorOf(path, mutant.applyTo(source)),
            );
          }
          // With --shard only the mutants of this part are built in.
          final compiling = [
            for (final (index, reason) in reasons.indexed)
              if (reason == null && (shard == null || shard.has(index))) index,
          ];
          if (schemata &&
              compiling.isNotEmpty &&
              reasons.length == mutants.length) {
            notBuilt = testLibrary == null
                ? 'the package has neither test nor flutter_test'
                : fileObstacle(source) ??
                      testsObstacle(
                        testTexts,
                        taken: existsExact(root, driverPathOf(target.tests)),
                      );
            if (notBuilt == null) {
              try {
                built = await buildIn(
                  analysis,
                  path,
                  source,
                  mutants,
                  compiling,
                  stopped: () => signals.signal != null,
                );
              } on AnalysisUnavailable catch (error) {
                notBuilt = 'cannot be analyzed that way (${error.message})';
              }
            }
          }
          await analysis.release(path);
          // Nothing is in the file yet: an analyzer that gives up on this
          // file (it is excluded from every context, say) fails the file,
          // not the run.
        } catch (error) {
          failures[path] = 'cannot be analyzed (${'$error'.split('\n').first})';
          continue;
        }
        if (signals.signal != null) {
          break;
        }
        statuses = [
          for (final reason in reasons) reason == null ? null : compileError,
        ];
      }
      if (signals.signal != null) {
        break;
      }

      final milliseconds = List<int>.filled(mutants.length, 0);
      // With --shard the other mutants are left to the other parts.
      final own = [
        for (var index = 0; index < mutants.length; index++)
          if (shard == null || shard.has(index)) index,
      ];
      var pending = [
        for (final index in own)
          if (statuses[index] == null) index,
      ];
      final reused = reusable == null ? 0 : own.length - pending.length;

      var remaining = pending;
      var announced = false;
      if (pending.isNotEmpty && copies != null && !copies.failed) {
        // A file behind a symbolic link is written where the link points
        // to: in a copy that could be the package's own file.
        final plain = p.join(copies.root, p.joinAll(path.split('/')));
        String? instead = file.path == plain
            ? null
            : 'is behind a symbolic link';
        if (instead == null && notBuilt != null) {
          io.err(
            '$executable run: $path $notBuilt; its mutants are not built into '
            'one program',
          );
        }
        final refused = own
            .where((index) => statuses[index] == compileError)
            .length;
        var said = reusable != null || refused == 0;
        // The mutants a driver reported as killed, while that is believed.
        var fromDriver = const <int>[];
        if (instead == null && built != null && built.ids.isEmpty) {
          io.out(
            '  $path: none of its ${built.left.length} mutant(s) that '
            'compile can be built in (${built.reasons})',
          );
        }
        if (instead == null && built != null && built.ids.isNotEmpty) {
          // One driver has to start, compile and run the tests without a
          // mutant before its first mutant: more of them only pay when
          // each has enough to do.
          final drivers = min(
            copies.jobs,
            (built.ids.length / mutantsBetweenChecks).ceil(),
          );
          List<String>? used;
          try {
            used = copies.first(drivers);
          } on FileSystemException {
            // The run from working copies below says so.
          }
          if (used != null) {
            io.out(
              '  $path: ${built.ids.length} of ${mutants.length} mutant(s) '
              'built into one program, with '
              '"${driverCommand(command, driverPathOf(target.tests)).join(' ')}"'
              '${drivers == 1 ? '' : ', $drivers at a time'}'
              '${said ? '' : ' ($refused do not compile)'}',
            );
            said = true;
            announced = true;
            final outcome = await runBuiltIn(
              copies: used,
              root: root,
              path: path,
              original: original,
              content: built.content,
              ids: built.ids,
              tests: target.tests,
              command: command,
              testLibrary: testLibrary!,
              package: packageNameOf(pubspec),
              limitOf: limitOf,
              memoryLimitOf: memoryLimitOf,
              signals: signals,
            );
            if (outcome.aborted != null) {
              aborted = outcome.aborted;
            }
            if (signals.signal != null || aborted != null) {
              break;
            }
            if (outcome.failure != null) {
              io.err(
                '$executable run: $path: ${outcome.failure}; its mutants are '
                'run the usual way',
              );
            } else {
              fromDriver = outcome.killed.keys.toList();
              for (final MapEntry(key: id, value: took)
                  in outcome.killed.entries) {
                statuses[id] = killed;
                milliseconds[id] = took;
              }
              final left = built.left.length;
              final unsettled = built.ids.length - outcome.killed.length;
              io.out(
                '  $path: ${outcome.killed.length} killed with the mutants '
                'built in'
                '${left == 0 ? '' : '; $left cannot be built in '
                          '(${built.reasons})'}'
                '${unsettled == 0 ? '' : '; $unsettled not killed that way '
                          'are measured the usual way'}'
                '${outcome.unended == 0 ? '' : '; ${outcome.unended} of '
                          'them did not end, and the driver was ended'}'
                '${outcome.heavy == 0 ? '' : '; with ${outcome.heavy} of '
                          'them the driver used too much memory, and was '
                          'ended'}',
              );
            }
            var left = [
              for (final index in pending)
                if (statuses[index] == null) index,
            ];
            if (left.isEmpty) {
              // No mutant is left for a run of its own, so the tests have
              // not been run the usual way at all: once, without a mutant.
              // Test files that only pass in one process together pass in
              // the driver, and are no tests to judge a mutant by.
              final usual = await runCommand(
                mutantCommand(command, target.tests),
                workingDirectory: used.first,
                capture: true,
                signals: signals,
                timeout: baselineLimit,
              );
              if (signals.signal != null) {
                break;
              }
              if (usual.exitCode != 0) {
                for (final id in fromDriver) {
                  statuses[id] = null;
                  milliseconds[id] = 0;
                }
                fromDriver = const [];
                left = pending;
                io.err(
                  '$executable run: $path: the tests do not pass the usual way '
                  'in a working copy; nothing of the driver is used',
                );
              }
            }
            pending = left;
            remaining = pending;
          }
        }
        if (instead == null && pending.isNotEmpty) {
          final workers = pending.length < copies.jobs
              ? pending.length
              : copies.jobs;
          final run = mutantCommand(command, target.tests);
          io.out(
            '  $path: ${pending.length} of ${mutants.length} mutant(s) with '
            '"${run.join(' ')}", $workers at a time'
            '${said ? '' : ' ($refused do not compile)'}',
          );
          announced = true;
          final outcome = await _runInCopies(
            copies: copies,
            workers: workers,
            root: root,
            path: path,
            original: original,
            source: source,
            tests: target.tests,
            run: run,
            shown: shown,
            mutants: mutants,
            pending: pending,
            statuses: statuses,
            reasons: reasons,
            milliseconds: milliseconds,
            limitOf: limitOf,
            memoryLimitOf: memoryLimitOf,
            signals: signals,
            io: io,
          );
          if (outcome.aborted != null) {
            aborted = outcome.aborted;
          }
          if (signals.signal != null || aborted != null) {
            break;
          }
          instead = outcome.inPlace;
          if (instead != null && fromDriver.isNotEmpty) {
            // The tests do not pass the usual way in a copy, where the
            // driver ran: what it reported is measured again as well.
            for (final id in fromDriver) {
              statuses[id] = null;
              milliseconds[id] = 0;
            }
            pending = [
              for (final index in own)
                if (statuses[index] == null) index,
            ];
            remaining = pending;
          }
        }
        if (instead == null) {
          remaining = const [];
        } else {
          io.err(
            '$executable run: $path $instead; its mutants are run one at a '
            'time, in place',
          );
        }
      }

      if (remaining.isNotEmpty) {
        inPlace = true;
        final run = mutantCommand(command, target.tests);
        final refused = own
            .where((index) => statuses[index] == compileError)
            .length;
        if (!announced) {
          io.out(
            '  $path: ${pending.length} of ${mutants.length} mutant(s) with '
            '"${run.join(' ')}"'
            '${reusable != null || refused == 0 ? '' : ' ($refused do not compile)'}',
          );
        }
        final baselineWatch = Stopwatch()..start();
        final baselineMemory = MemoryWatch();
        final baseline = await runCommand(
          run,
          workingDirectory: root,
          capture: true,
          signals: signals,
          timeout: baselineLimit,
          memory: baselineMemory,
        );
        if (baseline.signal != null) {
          break;
        }
        if (baseline.exitCode == null && !baseline.timedOut) {
          aborted = 'cannot start "$shown" (${baseline.startError})';
          break;
        }
        if (baseline.exitCode != 0) {
          failures[path] = baseline.timedOut
              ? 'the tests did not end within '
                    '${baselineLimit.inMinutes} minutes without a mutant. '
                    'Nothing was measured'
              : 'the tests fail without a mutant (exit ${baseline.exitCode}; '
                    'a test gets ${perTestTimeoutSeconds}s). '
                    'Nothing was measured';
          final tail = tailOf(baseline.output);
          if (tail.trim().isNotEmpty) {
            io.err(tail);
          }
          continue;
        }
        final limit = limitOf(baselineWatch.elapsed);
        final memoryLimit = memoryLimitOf(baselineMemory.peak);
        var heavy = 0;

        final active = _Active(
          path,
          file,
          original,
          state.backupOf(path),
          state.placedOf(path),
        );
        try {
          try {
            // The run without a mutant took a while: the file may have been
            // saved since it was read.
            if (!_sameBytes(file.readAsBytesSync(), original)) {
              aborted =
                  '$path changed while its tests ran. Nothing was written '
                  'to it; run again';
            }
            // In one step, like the mutants: a backup that is half-written
            // would be taken for the file of before the run.
            active.backup.parent.createSync(recursive: true);
            state.put(active.backup, original);
            active.placed.parent.createSync(recursive: true);
            for (final index in aborted == null ? pending : const <int>[]) {
              final mutantWatch = Stopwatch()..start();
              final bytes = utf8.encode(mutants[index].applyTo(source));
              // First the note of what is about to be in the file, then
              // the file: a run that is killed in between leaves the file
              // as it was.
              active.placed.writeAsBytesSync(bytes, flush: true);
              active.written = bytes;
              state.put(file, bytes);
              final result = await runCommand(
                run,
                workingDirectory: root,
                capture: true,
                signals: signals,
                timeout: limit,
                memory: MemoryWatch(limit: () => memoryLimit),
              );
              final problem = _restore(active, state);
              if (problem != null) {
                aborted = problem;
                break;
              }
              if (result.signal != null || signals.signal != null) {
                break;
              }
              if (result.exitCode == null && !result.limited) {
                aborted = 'cannot start "$shown" (${result.startError})';
                break;
              }
              statuses[index] = classifyRun(
                exitCode: result.exitCode,
                output: result.output,
                timedOut: result.limited,
              );
              if (result.overMemory) {
                reasons[index] = overMemoryReason(memoryLimit);
                heavy++;
              }
              milliseconds[index] = mutantWatch.elapsedMilliseconds;
            }
          } finally {
            // Also when the loop ended in an exception.
            final problem = _restore(active, state);
            if (problem != null) {
              aborted ??= problem;
            } else {
              _delete(active.backup);
              _delete(active.placed);
            }
          }
        } on FileSystemException catch (error) {
          aborted ??= '$path: cannot write the mutant (${_reason(error)})';
        }
        if (signals.signal != null || aborted != null) {
          break;
        }
        if (heavy > 0) {
          io.out(
            '  $path: $heavy mutant(s) used more than '
            '${megabytes(memoryLimit)} MB of memory and were ended (Timeout)',
          );
        }
      }

      // What is known of every mutant, also of those of another part: a
      // later run in this package starts from it. Every mutant of this
      // run has a status by now; only one of another part may have none.
      final known = [
        for (final (index, mutant) in mutants.indexed)
          MutantResult(
            mutant,
            shard == null || shard.has(index)
                ? statuses[index]!
                : statuses[index] ?? notRun,
            milliseconds: milliseconds[index],
            reason: reasons[index],
          ),
      ];
      final run = FileRun(
        source: source,
        results: [
          for (final (index, result) in known.indexed)
            shard == null || shard.has(index)
                ? result
                : MutantResult(result.mutant, notRun),
        ],
      );
      runs[path] = run;
      kept[path] = incrementalEntry(input, known);
      _writeIncremental(state, {...carried, ...kept});
      io.out(
        fileLine(
          path,
          run,
          reused: reused,
          milliseconds: watch.elapsedMilliseconds,
        ),
      );
    }
  } finally {
    // While the signals are still caught: a second Ctrl-C must not leave
    // half of the copies behind.
    try {
      copies?.remove();
    } on FileSystemException catch (error) {
      io.err(
        '$executable run: cannot remove the working copies in $stateDir/work '
        '(${_reason(error)}). The next run removes them',
      );
    }
    await signals.cancel();
    await analysis?.dispose();
  }

  if (signals.signal != null) {
    io.err(
      '$executable run: interrupted. '
      '${aborted ?? (inPlace ? 'The files were put back' : 'No file of the package was changed')}',
    );
    return signalExitCode(signals.signal!);
  }
  if (aborted != null) {
    io.err('$executable run: $aborted');
    io.err('$executable run: FAILED (the run was stopped)');
    return 1;
  }

  final pageProblem = _writeReport(
    reportPath,
    htmlPath,
    runs,
    others,
    shard: shard,
    notTested: failures.keys.toList(),
  );
  final survivors = survivorLines(runs);
  if (survivors.isNotEmpty) {
    io.err('$executable run: ${survivors.length} surviving mutant(s)');
    survivors.forEach(io.err);
  }
  if (failures.isNotEmpty) {
    io.err(
      '$executable run: ${failures.length} file(s) could not be mutation '
      'tested',
    );
    for (final MapEntry(key: path, value: reason) in failures.entries) {
      io.err('  - $path: $reason');
    }
  }
  // The last line of a part says that it is one.
  final summary =
      '(${shard == null ? '' : 'shard ${shard.label}: '}'
      '${totalCounts(runs.values)}'
      '${failures.isEmpty ? '' : ' / ${failures.length} file(s) not tested'})';
  if (pageProblem != null) {
    io.err('$executable run: $pageProblem');
  }
  if (survivors.isEmpty && failures.isEmpty && pageProblem == null) {
    io.out('$executable run: OK $summary');
    return 0;
  }
  io.err('$executable run: FAILED $summary');
  return 1;
}
