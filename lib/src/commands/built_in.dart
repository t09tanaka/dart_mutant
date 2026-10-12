import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../driver.dart';
import '../io/analysis.dart';
import '../io/process.dart';
import '../mutant.dart';
import '../mutation_run.dart';
import '../schemata.dart';

/// The mutants of a file, built into it.
class BuiltIn {
  BuiltIn(this.content, this.ids, this.left, {required this.guardAt});

  /// The file with a choice for every mutant of [ids], and the variable
  /// that makes it.
  final String content;

  /// Where the guard goes in [content], see [guarded].
  final int guardAt;

  /// The mutants that are built in.
  final List<int> ids;

  /// The mutants that are not, and why.
  final Map<int, String> left;

  /// How many mutants are left out for each reason, as a text.
  String get reasons {
    final counts = <String, int>{};
    for (final reason in left.values) {
      counts.update(reason, (count) => count + 1, ifAbsent: () => 1);
    }
    return [
      for (final MapEntry(key: reason, value: count) in counts.entries)
        '$count $reason',
    ].join(', ');
  }
}

/// Why nothing of the test runs of a file is used when its code ran in an
/// isolate or a process that no test file of a mutant started.
const ranElsewhere =
    'code of the file ran in another isolate or process than the tests, '
    'where no mutant is at work';

/// Why a mutant with a place was not built in.
const changesProgram =
    'the program does not compile, or has other types, with a choice there';
const notTogether = 'does not compile together with the other mutants';

/// Builds the mutants [pending] (indexes into [mutants]) of [path] into
/// [source], as far as that can be done without changing what the program
/// is: every one of them compiles in place ([analysis] has been asked).
///
/// A mutant is built in at the smallest expression or statement around it
/// for which three things hold: the file compiles with the choice there;
/// outside of it every expression has the static type it has in the file as
/// it is (so the program without a mutant at work is the one that was
/// there); and the same is true of the file with the mutant in place (so the
/// program with the mutant at work is the mutant).
Future<BuiltIn> buildIn(
  PackageAnalysis analysis,
  String path,
  String source,
  List<Mutant> mutants,
  List<int> pending, {
  required bool Function() stopped,
}) async {
  final original = await analysis.resolved(path, source);
  final types = typesOf(original.unit);
  final wraps = <Wrap>[];
  final left = <int, String>{};
  for (final id in pending) {
    if (stopped()) {
      break;
    }
    final mutant = mutants[id];
    final mutated = await analysis.resolved(path, mutant.applyTo(source));
    final mutatedTypes = typesOf(mutated.unit);
    final places = placesOf(original.unit, source, id, mutant, mutated.unit);
    Wrap? found;
    for (final wrap in places.wraps) {
      if (!sameTypesOutside(
        types,
        mutatedTypes,
        from: wrap.offset,
        to: wrap.end,
        growth: mutant.replacement.length - (mutant.end - mutant.offset),
      )) {
        continue;
      }
      final alone = await analysis.resolved(path, embed(source, [wrap]));
      if (alone.error == null &&
          sameTypesOutside(
            types,
            typesOf(alone.unit),
            from: wrap.offset,
            to: wrap.end,
            growth: wrap.growth,
            lead: wrap.lead,
          )) {
        found = wrap;
        break;
      }
    }
    if (found != null) {
      wraps.add(found);
    } else {
      left[id] = places.wraps.isEmpty ? places.reason : changesProgram;
    }
  }

  // With the guard, as the tests are run on it.
  final guardAt = guardOffsetOf(source);
  Future<bool> compiles(List<Wrap> some) async =>
      await analysis.compileErrorOf(
        path,
        guarded(embed(source, some), at: guardAt, marker: "''"),
      ) ==
      null;

  var together = wraps;
  if (!stopped() && !await compiles(wraps)) {
    // Each compiles alone. They are put together a few at a time, and one
    // at a time where a few do not go in.
    together = [];
    const step = 16;
    for (var from = 0; from < wraps.length && !stopped(); from += step) {
      final some = wraps.skip(from).take(step).toList();
      if (await compiles([...together, ...some])) {
        together.addAll(some);
        continue;
      }
      for (final wrap in some) {
        if (await compiles([...together, wrap])) {
          together.add(wrap);
        } else {
          left[wrap.id] = notTogether;
        }
      }
    }
  }
  return BuiltIn(
    embed(source, together),
    [for (final wrap in together) wrap.id],
    left,
    guardAt: guardAt,
  );
}

/// What the test runs with the mutants of a file built in found out.
class BuiltInRun {
  const BuiltInRun({
    this.killed = const {},
    this.failure,
    this.aborted,
    this.unended = 0,
    this.heavy = 0,
  });

  /// The mutants that are `Killed`, with the milliseconds of their tests.
  final Map<int, int> killed;

  /// Why nothing of these test runs is used: every mutant is run the usual
  /// way.
  final String? failure;

  /// Why the whole run has to stop.
  final String? aborted;

  /// How many test runs were ended because a mutant did not end within its
  /// limit.
  final int unended;

  /// How many test runs were ended because they held more memory than
  /// their limit with a mutant at work.
  final int heavy;
}

String _inPackage(String root, String relativePath) =>
    p.joinAll([root, ...relativePath.split('/')]);

/// How often the time limit is looked at.
const _tick = Duration(milliseconds: 200);

/// Runs the tests of [path] on the mutants [ids] that are built into
/// [content], in the working copies [copies]: in each, one start of the
/// test runner runs a test file per mutant (a driver), one after the
/// other, each in an isolate of its own, with the tests without a mutant
/// first, in between and last.
///
/// Only `Killed` is taken from such a test run, and only with the tests
/// without a mutant passing before and after: see [DriverLog.result]. A
/// test run whose current mutant does not end within its limit is ended,
/// and another one is started for the mutants after it. So is one that
/// holds more memory than its limit with a mutant at work
/// ([DriverLog.memoryLimit]): that mutant is run the usual way, which
/// measures it by itself.
///
/// The copies are left as they were: the file as [original], no driver.
Future<BuiltInRun> runBuiltIn({
  required List<String> copies,
  required String root,
  required String path,
  required Uint8List original,
  required String content,
  required int guardAt,
  required List<int> ids,
  required List<String> tests,
  required List<String> command,
  required String testLibrary,
  required String? package,
  required Duration Function(Duration baseline) limitOf,
  required int Function(int baseline) memoryLimitOf,
  required SignalWatch signals,
}) async {
  final directory = directoryOf(tests.first);
  final killed = <int, int>{};
  String? failure;
  String? aborted;
  var unended = 0;
  var heavy = 0;

  Future<void> worker(String copy, List<int> share) async {
    final state = Directory(p.join(copy, '.dart_tool', 'dart_mutant_driver'));
    final target = File(_inPackage(copy, path));
    final written = <File>[];
    void removeDrivers() {
      for (final file in written) {
        if (file.existsSync()) {
          file.deleteSync();
        }
      }
      written.clear();
    }

    try {
      for (final test in tests) {
        final bytes = File(_inPackage(root, test)).readAsBytesSync();
        File(_inPackage(copy, test))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(bytes, flush: true);
      }
      // Left behind by code of the file that runs where no mutant is at
      // work: in another isolate, or in another process.
      final elsewhere = File(p.join(state.path, 'elsewhere'));
      target.writeAsStringSync(
        guarded(
          content,
          at: guardAt,
          marker: dartString(elsewhere.absolute.path),
        ),
        flush: true,
      );
      var rest = share;
      while (rest.isNotEmpty &&
          failure == null &&
          aborted == null &&
          signals.signal == null) {
        if (state.existsSync()) {
          state.deleteSync(recursive: true);
        }
        Directory(p.join(state.path, 'killed')).createSync(recursive: true);
        final plan = planOf(rest);
        final drivers = <String>[];
        for (final (position, id) in plan.indexed) {
          for (final (index, test) in tests.indexed) {
            final driver = driverPathOf(tests, position, index);
            drivers.add(driver);
            written.add(
              File(_inPackage(copy, driver))..writeAsStringSync(
                driverSource(
                  testLibrary: testLibrary,
                  target: importOf(
                    path,
                    directory: directory,
                    package: package,
                  ),
                  test: importOf(test, directory: directory),
                  position: position,
                  index: index,
                  id: id,
                  state: state.absolute.path,
                ),
                flush: true,
              ),
            );
          }
        }
        final log = DriverLog(plan, tests: tests.length);
        // What the drivers wrote down since it was last looked at.
        final notes = File(p.join(state.path, 'log'));
        var read = 0;
        var partial = '';
        void readNotes() {
          if (!notes.existsSync()) {
            return;
          }
          final file = notes.openSync();
          try {
            final length = file.lengthSync();
            if (length <= read) {
              return;
            }
            file.setPositionSync(read);
            final text =
                partial +
                utf8.decode(file.readSync(length - read), allowMalformed: true);
            read = length;
            final lines = text.split('\n');
            // A line that is not written to its end yet.
            partial = lines.removeLast();
            lines.forEach(log.record);
          } finally {
            file.closeSync();
          }
        }

        // The time limit: of the position that is at work, since it is.
        final stop = Completer<void>();
        final watch = Stopwatch()..start();
        int? at;
        // The memory limit: of every position but the first, from what
        // the first one held.
        late final MemoryWatch memory;
        memory = MemoryWatch(
          limit: () {
            readNotes();
            return log.memoryLimit(memory.peak, memoryLimitOf);
          },
        );
        final timer = Timer.periodic(_tick, (_) {
          readNotes();
          final current = log.current;
          if (current != at) {
            at = current;
            watch.reset();
          }
          final limit = log.limit(limitOf, first: baselineLimit);
          // Also when another test run of the file has found that nothing
          // of them will be used.
          if ((watch.elapsed > limit || failure != null || aborted != null) &&
              !stop.isCompleted) {
            stop.complete();
          }
        });
        // A line that comes after the test run was given up belongs to no
        // test run: it must not reach the files of the next one.
        var running = true;
        final CommandResult result;
        try {
          result = await runCommand(
            driverCommand(command, drivers),
            workingDirectory: copy,
            capture: true,
            signals: signals,
            // Only what the test runner says of its own count is read.
            onLine: (line) {
              if (running) {
                log.output(line);
              }
            },
            stop: stop.future,
            memory: memory,
          );
        } finally {
          running = false;
          timer.cancel();
        }
        removeDrivers();
        if (result.signal != null ||
            signals.signal != null ||
            failure != null ||
            aborted != null) {
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
        readNotes();
        if (result.limited) {
          result.overMemory ? heavy++ : unended++;
        } else if (!log.done ||
            (result.exitCode == 0) != (log.failedAtEnd == 0)) {
          // It ended by itself: then it has to say how, and its exit code
          // has to say the same.
          failure ??= noVerdict;
          return;
        }
        final found = log.result;
        if (found.failure != null) {
          failure ??=
              result.overMemory && found.failure == notEndedWithoutMutant
              ? 'the test run used too much memory while the tests ran '
                    'without a mutant'
              : found.failure;
          return;
        }
        killed.addAll(found.killed);
        rest = found.rest;
      }
    } on FileSystemException catch (error) {
      failure ??=
          'the mutants cannot be written into a working copy '
          '(${error.osError?.message ?? error.message})';
    } finally {
      // The copy is used again, for this file and for the next ones.
      try {
        removeDrivers();
        target.writeAsBytesSync(original, flush: true);
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
  );
}
