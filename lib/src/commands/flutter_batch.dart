import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../driver.dart';
import '../flutter_batch.dart';
import '../io/process.dart';
import '../mutation_run.dart';
import '../schemata.dart';
import 'built_in.dart';

/// Why nothing of the wrappers of a file is used when the tests without a
/// mutant do not pass in one.
const notPassingInWrapper =
    'the tests do not pass without a mutant when another test file calls '
    'them with the mutants built in, or leave or change a file in the '
    'package';

/// Why nothing of the wrappers of a file is used when a start of the test
/// runner ended otherwise than its report says.
const notAttributable =
    'a start of the test runner for many mutants ended otherwise than its '
    'report says';

/// How often the wrappers of a working copy are started again after a
/// mutant that did not end, each time with the mutants after it. The
/// mutants that are left then get a start of their own.
const restarts = 8;

String _inPackage(String root, String relativePath) =>
    p.joinAll([root, ...relativePath.split('/')]);

/// What is in the working copy [root]: the names of its directories and
/// links, and the names, sizes and times of its files, without `.dart_tool`
/// and `build` at its top, and without the file [without] (relative to it),
/// which the run itself writes.
Set<String> _treeOf(String root, {required String without}) {
  final found = <String>{};
  for (final entity in Directory(
    root,
  ).listSync(recursive: true, followLinks: false)) {
    final path = p.relative(entity.path, from: root);
    final top = p.split(path).first;
    if (top == '.dart_tool' ||
        top == 'build' ||
        p.split(path).join('/') == without) {
      continue;
    }
    if (entity is File) {
      final stat = entity.statSync();
      found.add('$path ${stat.size} ${stat.modified.microsecondsSinceEpoch}');
    } else {
      found.add(path);
    }
  }
  return found;
}

/// Runs the tests of [path] on the mutants [ids] that are built into
/// [content], in the working copies [copies] of a Flutter package: in each,
/// every mutant gets a test file of its own that puts it to work and calls
/// the tests ([wrapperSource]), and **one start of the test runner** runs
/// these files one after the other ([batchCommand]), each in the process
/// `flutter test` gives every test file, with the tests without a mutant
/// first, in between and last ([planOf]).
///
/// Only `Killed` is taken from it, and only what the report of the test
/// runner says ([suitesOf]), when the tests without a mutant passed before
/// and after ([DriverLog]). A start that goes on for too long without a
/// test starting or ending, or holds too much memory, is ended: what its
/// report says of the wrappers before the one it was at is used, the mutant
/// it was at gets a start of its own, and the wrappers after it are
/// started again.
///
/// The copies are left as they were: the file as [original], nothing of
/// the wrappers, and a copy in which the tests left or changed a file is
/// made again ([refresh]).
Future<BuiltInRun> runFlutterBatch({
  required List<String> copies,
  required String root,
  required String path,
  required Uint8List original,
  required String content,
  required int guardAt,
  required List<int> ids,
  required String test,
  required List<String> command,
  required String testLibrary,
  required String? package,
  required String? config,
  required Duration Function(Duration baseline) limitOf,
  required int Function(int baseline) memoryLimitOf,
  required SignalWatch signals,
  required void Function(String copy) refresh,
}) async {
  final killed = <int, int>{};
  String? failure;
  String? aborted;
  var unended = 0;
  var heavy = 0;
  var dirty = 0;

  Future<void> worker(String copy, List<int> share) async {
    final state = Directory(_inPackage(copy, wrapperDirectory));
    final target = File(_inPackage(copy, path));
    Set<String>? before;
    try {
      final bytes = File(_inPackage(root, test)).readAsBytesSync();
      File(_inPackage(copy, test))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes, flush: true);
      before = _treeOf(copy, without: path);
      if (state.existsSync()) {
        state.deleteSync(recursive: true);
      }
      state.createSync(recursive: true);
      final elsewhere = File(p.join(state.path, 'elsewhere'));
      target.writeAsStringSync(
        guarded(
          content,
          at: guardAt,
          marker: dartString(elsewhere.absolute.path),
        ),
        flush: true,
      );
      final report = File(p.join(state.absolute.path, 'report.json'));

      var remaining = share;
      // The mutants a test failed on since the tests last passed without a
      // mutant, also in a start that was ended since.
      final open = <int, int>{};
      for (
        var start = 0;
        remaining.isNotEmpty &&
            start <= restarts &&
            failure == null &&
            aborted == null &&
            signals.signal == null;
        start++
      ) {
        final plan = planOf(remaining);
        final log = DriverLog(plan, tests: 1);
        for (final (position, id) in plan.indexed) {
          File(_inPackage(copy, wrapperPathOf(position))).writeAsStringSync(
            wrapperSource(
              testLibrary: testLibrary,
              target: importOf(
                path,
                directory: wrapperDirectory,
                package: package,
              ),
              test: importOf(test, directory: wrapperDirectory),
              config: config == null
                  ? null
                  : importOf(config, directory: wrapperDirectory),
              id: id,
              root: p.absolute(copy),
              state: state.absolute.path,
            ),
            flush: true,
          );
        }
        if (report.existsSync()) {
          report.deleteSync();
        }

        // How long the start may go on without a test starting or ending,
        // and how much it may hold: from the first wrapper, which has no
        // mutant, once the second one begins.
        final stop = Completer<void>();
        final quiet = Quiet(limitOf);
        int? memoryLimit;
        Timer? waiting;
        void wait() {
          waiting?.cancel();
          waiting = Timer(quiet.limit ?? baselineLimit, () {
            if (!stop.isCompleted) {
              stop.complete();
            }
          });
        }

        final memory = MemoryWatch(limit: () => memoryLimit);
        wait();
        final result = await runCommand(
          batchCommand(
            command,
            report: report.path,
            wrappers: [
              for (var position = 0; position < plan.length; position++)
                wrapperPathOf(position),
            ],
          ),
          workingDirectory: copy,
          capture: true,
          signals: signals,
          stop: stop.future,
          memory: memory,
          onLine: (line) {
            final progress = progressOf(line);
            if (progress == null) {
              return;
            }
            if (quiet.add(progress)) {
              memoryLimit = memoryLimitOf(memory.peak);
            }
            wait();
          },
        );
        waiting?.cancel();
        if (result.signal != null || signals.signal != null) {
          return;
        }
        if (result.exitCode == null && !result.limited) {
          aborted ??=
              'cannot start "${command.join(' ')}" (${result.startError})';
          return;
        }
        if (elsewhere.existsSync()) {
          failure ??= ranElsewhere;
          return;
        }
        final read = suitesOf(
          report.existsSync() ? report.readAsStringSync() : '',
        );
        if (!result.limited &&
            !attributable(
              exitCode: result.exitCode!,
              done: read.done,
              suites: read.suites,
              wrappers: plan.length,
            )) {
          failure ??= start == 0 && read.suites[0]?.outcome != Outcome.passed
              ? notPassingInWrapper
              : notAttributable;
          return;
        }
        // The wrappers the report is sure of, in their order.
        for (var position = log.next; position != null; position = log.next) {
          final suite = read.suites[position];
          if (suite == null || !suite.complete) {
            break;
          }
          if (suite.dirty && plan[position] != noMutant) {
            dirty++;
          }
          log.addOutcome(
            suite.outcome,
            tests: suite.tests,
            milliseconds: suite.milliseconds,
          );
          if (plan[position] != noMutant) {
            if (suite.outcome == Outcome.failed) {
              open[plan[position]] = suite.milliseconds;
            }
          } else if (log.failure == null) {
            killed.addAll(open);
            open.clear();
          }
        }
        if (log.failure != null) {
          failure ??= notPassingInWrapper;
          return;
        }
        final stuck = log.next;
        if (stuck == null) {
          break;
        }
        // Ended at a wrapper: the mutant of it is left, and the ones after
        // it are started again.
        if (plan[stuck] == noMutant && stuck == 0) {
          failure ??= notEndedWithoutMutant;
          return;
        }
        if (plan[stuck] != noMutant) {
          result.overMemory ? heavy++ : unended++;
        }
        remaining = [
          for (final id in plan.skip(stuck + 1))
            if (id != noMutant) id,
        ];
      }
    } on FileSystemException catch (error) {
      failure ??=
          'the mutants cannot be written into a working copy '
          '(${error.osError?.message ?? error.message})';
    } finally {
      // The copy is used again, for this file and for the next ones.
      try {
        target.writeAsBytesSync(original, flush: true);
        if (state.existsSync()) {
          state.deleteSync(recursive: true);
        }
        // What the tests of a mutant left there would be found by the
        // starts of the mutants after it.
        if (before != null) {
          final after = _treeOf(copy, without: path);
          if (after.length != before.length || !after.containsAll(before)) {
            refresh(copy);
          }
        }
      } on FileSystemException catch (error) {
        aborted ??=
            '$path: cannot take the mutants out of a working copy '
            '(${error.osError?.message ?? error.message})';
      }
    }
  }

  await Future.wait([
    for (final (index, copy) in copies.indexed)
      worker(copy, [
        for (final (position, id) in ids.indexed)
          if (position % copies.length == index) id,
      ]),
  ]);
  return BuiltInRun(
    killed: failure == null && aborted == null ? killed : const {},
    failure: failure,
    aborted: aborted,
    unended: unended,
    heavy: heavy,
    dirty: dirty,
  );
}
