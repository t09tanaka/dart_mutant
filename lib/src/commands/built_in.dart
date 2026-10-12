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

/// Why nothing of the drivers of a file is used when they do not compile:
/// compiling a driver runs its tests once, without a mutant.
const notCompiled =
    'the tests cannot be compiled as a program of their own with the '
    'mutants built in, or do not pass when they are run that way for the '
    'first time';

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

/// What the drivers of a file found out.
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

  /// Why nothing of the drivers is used: every mutant is run the usual
  /// way.
  final String? failure;

  /// Why the whole run has to stop.
  final String? aborted;

  /// How many mutants did not end within their limit.
  final int unended;

  /// How many mutants held more memory than their limit.
  final int heavy;
}

String _inPackage(String root, String relativePath) =>
    p.joinAll([root, ...relativePath.split('/')]);

/// Runs the tests of [path] on the mutants [ids] that are built into
/// [content], in the working copies [copies]: in each, the tests of the
/// file are compiled once with the mutants in them (a driver per test
/// file), and that program is started once per mutant, **each time as a
/// process of its own**, with the tests without a mutant first, in between
/// and last.
///
/// Only `Killed` is taken from the drivers, and only when the driver wrote
/// down that a test failed, its process ended with another exit code than
/// 0, and the tests without a mutant passed before and after: see
/// [outcomeOf] and [DriverLog]. A mutant that does not end within its
/// limit, or holds more memory than its limit, is ended and run the usual
/// way, which measures it by itself.
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
  required List<String> dart,
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
    final drivers = [
      for (final index in Iterable<int>.generate(tests.length))
        File(_inPackage(copy, driverPathOf(tests, index))),
    ];
    try {
      for (final test in tests) {
        final bytes = File(_inPackage(root, test)).readAsBytesSync();
        File(_inPackage(copy, test))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(bytes, flush: true);
      }
      if (state.existsSync()) {
        state.deleteSync(recursive: true);
      }
      state.createSync(recursive: true);
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
      // The tests with the mutants in them, compiled once.
      final programs = <String>[];
      for (final (index, test) in tests.indexed) {
        drivers[index].writeAsStringSync(
          driverSource(
            testLibrary: testLibrary,
            target: importOf(path, directory: directory, package: package),
            test: importOf(test, directory: directory),
            index: index,
            state: state.absolute.path,
          ),
          flush: true,
        );
        final program = p.join(state.absolute.path, 'driver_$index.jit');
        final compiled = await runCommand(
          compileCommand(dart, driverPathOf(tests, index), program),
          workingDirectory: copy,
          capture: true,
          signals: signals,
          timeout: baselineLimit,
        );
        if (compiled.signal != null || signals.signal != null) {
          return;
        }
        if (compiled.exitCode == null && !compiled.limited) {
          aborted ??=
              'cannot start "${dart.join(' ')}" (${compiled.startError})';
          return;
        }
        if (compiled.exitCode != 0) {
          failure ??= notCompiled;
          return;
        }
        programs.add(program);
      }

      final notes = File(p.join(state.path, 'log'));
      final log = DriverLog(planOf(share), tests: tests.length);
      // The limits of a mutant: from what the tests took and held without
      // one, the first time.
      Duration? limit;
      var memoryLimit = 0;
      for (
        var position = log.next;
        position != null &&
            failure == null &&
            aborted == null &&
            signals.signal == null;
        position = log.next
      ) {
        final id = log.plan[position];
        if (notes.existsSync()) {
          notes.deleteSync();
        }
        final watch = Stopwatch()..start();
        final exitCodes = <int>[];
        var ended = false;
        var held = 0;
        for (final program in programs) {
          final memory = MemoryWatch(
            limit: limit == null ? null : () => memoryLimit,
          );
          final result = await runCommand(
            driverCommand(dart, program, id),
            workingDirectory: copy,
            capture: true,
            signals: signals,
            timeout: limit ?? baselineLimit,
            memory: memory,
          );
          if (result.signal != null || signals.signal != null) {
            return;
          }
          if (result.exitCode == null && !result.limited) {
            aborted ??=
                'cannot start "${dart.join(' ')}" (${result.startError})';
            return;
          }
          if (memory.peak > held) {
            held = memory.peak;
          }
          if (result.limited) {
            ended = true;
            if (id != noMutant) {
              result.overMemory ? heavy++ : unended++;
            }
            break;
          }
          exitCodes.add(result.exitCode!);
          // A mutant is done with the first test file that fails.
          if (id != noMutant && result.exitCode != 0) {
            break;
          }
        }
        if (elsewhere.existsSync()) {
          failure ??= ranElsewhere;
          return;
        }
        log.add(
          Ran(
            exitCodes: exitCodes,
            notes: notes.existsSync() ? notes.readAsLinesSync() : const [],
            ended: ended,
          ),
          milliseconds: watch.elapsedMilliseconds,
        );
        if (limit == null) {
          limit = limitOf(watch.elapsed);
          memoryLimit = memoryLimitOf(held);
        }
      }
      if (signals.signal != null || failure != null || aborted != null) {
        return;
      }
      final found = log.result;
      if (found.failure != null) {
        failure ??= found.failure;
        return;
      }
      killed.addAll(found.killed);
    } on FileSystemException catch (error) {
      failure ??=
          'the mutants cannot be written into a working copy '
          '(${error.osError?.message ?? error.message})';
    } finally {
      // The copy is used again, for this file and for the next ones.
      try {
        for (final driver in drivers) {
          if (driver.existsSync()) {
            driver.deleteSync();
          }
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
    unended: unended,
    heavy: heavy,
  );
}
