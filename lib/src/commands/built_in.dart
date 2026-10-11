import 'dart:async';
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
  BuiltIn(this.content, this.ids, this.left);

  /// The file with a choice for every mutant of [ids], and the variable
  /// that makes it.
  final String content;

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

  Future<bool> compiles(List<Wrap> some) async =>
      await analysis.compileErrorOf(path, embed(source, some)) == null;

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
  return BuiltIn(embed(source, together), [
    for (final wrap in together) wrap.id,
  ], left);
}

/// What the drivers of a file found out.
class BuiltInRun {
  const BuiltInRun({
    this.killed = const {},
    this.failure,
    this.aborted,
    this.again = 0,
  });

  /// The mutants that are `Killed`, with the milliseconds of their tests.
  final Map<int, int> killed;

  /// Why nothing of the drivers is used: every mutant is run the usual way.
  final String? failure;

  /// Why the whole run has to stop.
  final String? aborted;

  /// How often a driver was ended because a mutant did not end, and another
  /// one started for the rest.
  final int again;
}

String _inPackage(String root, String relativePath) =>
    p.joinAll([root, ...relativePath.split('/')]);

/// How often the driver's notes are read while its tests are being declared,
/// and how often the time limit is looked at.
const _tick = Duration(milliseconds: 200);

/// Runs the tests of [path] on the mutants [ids] that are built into
/// [content], in the working copies [copies]: in each, a driver runs the
/// tests once without a mutant, then once per mutant, in one process.
///
/// Only `Killed` is taken from a driver, and only with the tests without a
/// mutant passing before and after: see [DriverLog.result]. A driver whose
/// current mutant does not end within its limit is ended, and another one
/// is started for the mutants after it.
///
/// The copies are left as they were: the file as [original], no driver.
Future<BuiltInRun> runBuiltIn({
  required List<String> copies,
  required String root,
  required String path,
  required Uint8List original,
  required String content,
  required List<int> ids,
  required List<String> tests,
  required List<String> command,
  required String testLibrary,
  required String? package,
  required Duration Function(Duration baseline) limitOf,
  required SignalWatch signals,
}) async {
  final directory = directoryOf(tests.first);
  final driver = driverPathOf(tests);
  final run = driverCommand(command, driver);
  final killed = <int, int>{};
  String? failure;
  String? aborted;
  var again = 0;

  Future<void> worker(String copy, List<int> share) async {
    final state = Directory(p.join(copy, '.dart_tool', 'dart_mutant_driver'));
    final declared = File(p.join(state.path, 'declared'));
    final target = File(_inPackage(copy, path));
    final driverFile = File(_inPackage(copy, driver));
    try {
      for (final test in tests) {
        final bytes = File(_inPackage(root, test)).readAsBytesSync();
        File(_inPackage(copy, test))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(bytes, flush: true);
      }
      target.writeAsStringSync(content, flush: true);
      driverFile.writeAsStringSync(
        driverSource(
          testLibrary: testLibrary,
          target: importOf(path, directory: directory, package: package),
          tests: [
            for (final test in tests) importOf(test, directory: directory),
          ],
          state: state.absolute.path,
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
        File(p.join(state.path, 'plan')).writeAsStringSync(plan.join('\n'));
        final log = DriverLog(plan);

        // The time limit: of the position that is at work, since it is.
        final stop = Completer<void>();
        final watch = Stopwatch()..start();
        int? at;
        final timer = Timer.periodic(_tick, (_) {
          if (log.started.isEmpty && declared.existsSync()) {
            log.declared(declared.readAsStringSync());
          }
          final current = log.current;
          if (current != at) {
            at = current;
            watch.reset();
          }
          final limit = log.limit(limitOf, first: baselineLimit);
          if (watch.elapsed > limit && !stop.isCompleted) {
            stop.complete();
          }
        });
        final CommandResult result;
        try {
          result = await runCommand(
            run,
            workingDirectory: copy,
            capture: true,
            signals: signals,
            onLine: (line) {
              final id = log.add(line);
              if (id != null) {
                File(p.join(state.path, 'killed', '$id')).createSync();
              }
            },
            stop: stop.future,
          );
        } finally {
          timer.cancel();
        }
        if (result.signal != null || signals.signal != null) {
          return;
        }
        if (result.exitCode == null && !result.timedOut) {
          aborted ??=
              'cannot start "${command.join(' ')}" (${result.startError})';
          return;
        }
        if (declared.existsSync()) {
          log.declared(declared.readAsStringSync());
        }
        final found = log.result;
        if (found.failure != null) {
          failure ??= found.failure;
          return;
        }
        killed.addAll(found.killed);
        rest = found.rest;
        if (rest.isNotEmpty) {
          again++;
        }
      }
    } on FileSystemException catch (error) {
      failure ??=
          'the driver cannot be written into a working copy '
          '(${error.osError?.message ?? error.message})';
    } finally {
      // The copy is used again, for this file and for the next ones.
      try {
        if (driverFile.existsSync()) {
          driverFile.deleteSync();
        }
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
    again: again,
  );
}
