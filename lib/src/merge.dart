import 'json.dart';
import 'mutant.dart';
import 'mutation_run.dart';
import 'shard.dart';

/// A file that is given to `dart_mutant merge`: its [name] for the
/// messages, and its content as JSON (`null` when it is none).
typedef PartFile = ({String name, Object? content});

class _Mutant {
  _Mutant(this.identity, this.result);

  /// What says which mutant this is: everything but what a run found out.
  final JsonObject identity;

  final MutantResult result;
}

class _File {
  _File(this.source, this.mutants);

  final String source;
  final List<_Mutant> mutants;
}

class _Part {
  _Part(this.name, this.shard, this.notTested, this.writer, this.files);

  final String name;
  final Shard shard;
  final List<String> notTested;

  /// The tool and the mutators that wrote the part.
  final JsonObject writer;

  final Map<String, _File> files;

  /// `shard 2/4 (name)`.
  String get shown => 'shard ${shard.label} ($name)';
}

/// What a report says about the tool that wrote it. Two reports with the
/// same answer were made by the same mutators.
final _thisTool = writerOf(buildReport(const {}));

String _versions(JsonObject writer) {
  final framework = asObject(writer['framework']);
  return '${framework?['name']} ${framework?['version']}, mutators '
      '${writer['mutatorsVersion']}';
}

/// The offset in [source] of a `location` of the report (1-based line and
/// column), `null` when there is no such place: what `positionOf` gives,
/// the other way round.
int? _offsetOf(String source, Object? position) {
  final line = asObject(position)?['line'];
  final column = asObject(position)?['column'];
  if (line is! int || column is! int || line < 1 || column < 1) {
    return null;
  }
  var start = 0;
  for (var at = 1; at < line; at++) {
    final end = source.indexOf('\n', start);
    if (end < 0) {
      return null;
    }
    start = end + 1;
  }
  // A column past the end of its line would be a place in another line.
  final next = source.indexOf('\n', start);
  final length = (next < 0 ? source.length : next) - start;
  return column - 1 > length ? null : start + column - 1;
}

/// The statuses a mutant can have in the report of a part.
const _statuses = {killed, survived, timeout, compileError, notRun};

_Mutant? _readMutant(String source, Object? value) {
  final mutant = asObject(value);
  final mutator = mutant?['mutatorName'];
  final replacement = mutant?['replacement'];
  final status = mutant?['status'];
  final reason = mutant?['statusReason'];
  final duration = mutant?['duration'];
  final location = asObject(mutant?['location']);
  final offset = _offsetOf(source, location?['start']);
  final end = _offsetOf(source, location?['end']);
  if (mutant == null ||
      mutator is! String ||
      replacement is! String ||
      !_statuses.contains(status) ||
      (reason != null && reason is! String) ||
      duration is! int ||
      duration < 0 ||
      offset == null ||
      end == null ||
      end < offset) {
    return null;
  }
  return _Mutant(
    {
      for (final MapEntry(:key, :value) in mutant.entries)
        if (!const {'status', 'statusReason', 'duration'}.contains(key))
          key: value,
    },
    MutantResult(
      Mutant(mutator, offset, end, replacement),
      status! as String,
      milliseconds: duration,
      reason: reason as String?,
    ),
  );
}

_Part? _readPart(PartFile file) {
  final report = asObject(file.content);
  final part = partOf(report);
  final files = asObject(report?['files']);
  if (report == null || part == null || files == null) {
    return null;
  }
  final read = <String, _File>{};
  for (final MapEntry(key: path, :value) in files.entries) {
    final source = asObject(value)?['source'];
    final mutants = asObject(value)?['mutants'];
    if (source is! String || mutants is! List) {
      return null;
    }
    final found = <_Mutant>[];
    for (final item in mutants) {
      final mutant = _readMutant(source, item);
      if (mutant == null) {
        return null;
      }
      found.add(mutant);
    }
    read[path] = _File(source, found);
  }
  return _Part(file.name, part.shard, part.notTested, writerOf(report), read);
}

/// Why the [file] at [path] of [part] is not the one [first] mutated, or
/// `null` when it is, with every mutant evaluated by the part it belongs to
/// and by no other.
String? _mismatch(String path, _Part part, _File file, _Part first) {
  final expected = first.files[path]!;
  final at = '${part.shown}: $path';
  if (file.source != expected.source) {
    return '$at is not the source ${first.shown} mutated';
  }
  if (file.mutants.length != expected.mutants.length) {
    return '$at has ${file.mutants.length} mutant(s), ${first.shown} has '
        '${expected.mutants.length}';
  }
  for (final (index, mutant) in file.mutants.indexed) {
    if (!sameJson(mutant.identity, expected.mutants[index].identity)) {
      return '$at: mutant $index is not the one of ${first.shown}';
    }
    final evaluated = mutant.result.status != notRun;
    if (evaluated != part.shard.has(index)) {
      return evaluated
          ? '$at: mutant $index has a status (${mutant.result.status}), '
                'and belongs to another part'
          : '$at: mutant $index belongs to this part, and was not evaluated';
    }
  }
  return null;
}

/// How many parts that are missing are named, one line each.
const _shownMissing = 20;

/// Puts the parts of one run with `--shard` together: what the run would
/// have found without `--shard`, for the files in the order of the parts.
///
/// [files] are the files that were given, at least one. Returns the
/// [problems] instead when the parts are not all of one run,
/// each exactly once. A part that is missing must not pass for mutants
/// that were killed, so everything is checked that can be:
///
/// - every file is a part (a report of a run with `--shard`), written by
///   this version of the tool and of its mutators;
/// - all parts divide the run into the same number, and each of the parts
///   1 to that number is there once;
/// - no part names a file that could not be mutation tested;
/// - the parts have the same files, with the same source and the same
///   mutants (a part of another state of the file has others). The tests
///   and the test command of a part are not in its report, so that they
///   were the same is not checked;
/// - every mutant was evaluated by the part it belongs to, and is `Pending`
///   in all others.
({Map<String, FileRun> files, List<String> problems}) mergeParts(
  List<PartFile> files,
) {
  ({Map<String, FileRun> files, List<String> problems}) refused(
    List<String> problems,
  ) => (files: const {}, problems: problems);

  final parts = <_Part>[];
  final problems = <String>[];
  for (final file in files) {
    final part = _readPart(file);
    if (part == null) {
      problems.add(
        '${file.name} is not a part of a run: not a report that '
        'dart_mutant wrote with --shard',
      );
    } else if (!sameJson(part.writer, _thisTool)) {
      problems.add(
        '${part.shown} was written by ${_versions(part.writer)}; this is '
        '${_versions(_thisTool)}',
      );
    } else {
      parts.add(part);
    }
  }
  if (problems.isNotEmpty) {
    return refused(problems);
  }

  parts.sort((a, b) => a.shard.index - b.shard.index);
  final count = parts.first.shard.count;
  for (final part in parts) {
    if (part.shard.count != count) {
      problems.add(
        '${part.shown} is a part of another run than ${parts.first.shown}: '
        'the number of parts differs',
      );
    }
  }
  if (problems.isNotEmpty) {
    return refused(problems);
  }
  final given = <int, List<String>>{};
  for (final part in parts) {
    given.putIfAbsent(part.shard.index, () => []).add(part.name);
  }
  for (final MapEntry(key: index, value: names) in given.entries) {
    if (names.length > 1) {
      problems.add('shard $index/$count is given twice (${names.join(', ')})');
    }
  }
  // Not more lines than a reader wants, and never all of them looked at:
  // the number of parts is whatever a file says.
  final missing = Iterable<int>.generate(
    count,
    (at) => at + 1,
  ).where((index) => !given.containsKey(index));
  for (final index in missing.take(_shownMissing)) {
    problems.add('shard $index/$count is missing');
  }
  if (missing.skip(_shownMissing).isNotEmpty) {
    problems.add('more parts of the $count are missing');
  }
  if (problems.isNotEmpty) {
    return refused(problems);
  }

  final first = parts.first;
  for (final part in parts) {
    for (final path in part.notTested) {
      problems.add('${part.shown}: $path could not be mutation tested');
    }
    final paths = part.files.keys.toList();
    if (!sameJson(paths, first.files.keys.toList())) {
      problems.add(
        '${part.shown} has other files than ${first.shown} '
        '(${paths.join(', ')} / ${first.files.keys.join(', ')})',
      );
      continue;
    }
    for (final MapEntry(key: path, value: file) in part.files.entries) {
      final mismatch = _mismatch(path, part, file, first);
      if (mismatch != null) {
        problems.add(mismatch);
      }
    }
  }
  if (problems.isNotEmpty) {
    return refused(problems);
  }

  return (
    files: {
      for (final MapEntry(key: path, value: file) in first.files.entries)
        path: FileRun(
          source: file.source,
          results: [
            for (var index = 0; index < file.mutants.length; index++)
              parts
                  .singleWhere((part) => part.shard.has(index))
                  .files[path]!
                  .mutants[index]
                  .result,
          ],
        ),
    },
    problems: const [],
  );
}
