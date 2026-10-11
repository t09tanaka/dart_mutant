import 'json.dart';
import 'typed_mutators.dart';

/// One part of a run that `--shard` divides: part [index] of [count],
/// counted from 1.
class Shard {
  const Shard(this.index, this.count);

  final int index;
  final int count;

  /// True when the mutant with the number [mutant] of its file (0, 1, …)
  /// belongs to this part.
  ///
  /// The numbers are dealt out in turn: 0 to the first part, 1 to the
  /// second, and so on. A number is the same in every run of the same
  /// source, whatever the jobs, the order of the files and the results of
  /// the last run are, so every mutant belongs to exactly one part. The
  /// syntax mutants come first and the typed ones after them, both in the
  /// order of the source, so each part gets its share of every region of
  /// the file and of both kinds.
  bool has(int mutant) => mutant % count == index - 1;

  /// `2/4`, as it is given to `--shard` and printed.
  String get label => '$index/$count';
}

final _shard = RegExp(r'^(\d+)/(\d+)$');

/// The value of `--shard`: `<index>/<count>` with an index from 1 to the
/// count. `null` for anything else.
Shard? parseShard(String value) {
  final match = _shard.firstMatch(value);
  if (match == null) {
    return null;
  }
  // Digits only, but they can be more than a number holds.
  final index = int.tryParse(match[1]!);
  final count = int.tryParse(match[2]!);
  if (index == null || count == null || index < 1 || index > count) {
    return null;
  }
  return Shard(index, count);
}

/// The `config` of a report: the version of the mutators, and for a run
/// with `--shard` which part the report is.
///
/// `config` is the place the report schema leaves to the tool. A report
/// with `shard` in it is a part: its other mutants are `Pending`, and only
/// all parts together (`dart_mutant merge`) are the report of the run.
///
/// [notTested] are the files of the run that could not be mutation tested
/// (no test, tests that fail without a mutant, …). They are not in the
/// report, so a part has to name them: otherwise the parts of a run in
/// which a file failed everywhere would fit together.
JsonObject reportConfig({Shard? shard, List<String> notTested = const []}) => {
  'mutatorsVersion': mutatorsVersion,
  if (shard != null)
    'shard': {
      'index': shard.index,
      'count': shard.count,
      'notTested': notTested,
    },
};

/// Which part of a run the decoded [report] is, and the files that could
/// not be tested in it, as [reportConfig] wrote them. `null` when it is no
/// part: a report of a whole run, or anything else.
({Shard shard, List<String> notTested})? partOf(Object? report) {
  final part = asObject(asObject(asObject(report)?['config'])?['shard']);
  final index = part?['index'];
  final count = part?['count'];
  final notTested = asStrings(part?['notTested']);
  if (index is! int ||
      count is! int ||
      notTested == null ||
      index < 1 ||
      index > count) {
    return null;
  }
  return (shard: Shard(index, count), notTested: notTested);
}
