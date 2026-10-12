import 'dart:convert';

import 'package:dart_mutant/src/json.dart';
import 'package:dart_mutant/src/merge.dart';
import 'package:dart_mutant/src/mutant.dart';
import 'package:dart_mutant/src/mutation_run.dart';
import 'package:dart_mutant/src/shard.dart';
import 'package:test/test.dart';

// Two lines, so that a place is a line and a column; the second file ends
// without a line end.
const sourceA = 'int a(int x) =>\n    x + 1;\n';
const sourceB = 'num b(num x, num y) =>\n  x * y -\n  x;';

const plus = Mutant('ArithmeticOperator', 22, 23, '-');
const one = Mutant('NumberLiteral', 24, 25, '2');
const all = Mutant('BlockStatement', 0, sourceA.length, '');
const times = Mutant('ArithmeticOperator', 27, 28, '/');
const minus = Mutant('ArithmeticOperator', 31, 32, '+');
const last = Mutant('ReturnValue', 35, 36, 'null');
const end = Mutant('Added', sourceB.length, sourceB.length, ' + 1');

/// What a run without `--shard` finds.
const whole = {
  'lib/a.dart': FileRun(
    source: sourceA,
    results: [
      MutantResult(plus, killed, milliseconds: 1200),
      MutantResult(one, compileError, reason: 'not a program'),
      MutantResult(all, survived, milliseconds: 900),
    ],
  ),
  'lib/b.dart': FileRun(
    source: sourceB,
    results: [
      MutantResult(times, timeout, milliseconds: 41000),
      MutantResult(minus, compileError),
      MutantResult(last, killed, milliseconds: 5),
      MutantResult(end, survived, milliseconds: 7),
    ],
  ),
};

/// The report of part [shard] of [files], as a run writes and a merge
/// reads it.
JsonObject partReport(
  Shard shard, {
  Map<String, FileRun> files = whole,
  List<String> notTested = const [],
}) =>
    jsonDecode(
          jsonEncode(
            buildReport(
              {
                for (final MapEntry(key: path, value: run) in files.entries)
                  path: FileRun(
                    source: run.source,
                    results: [
                      for (final (index, result) in run.results.indexed)
                        shard.has(index)
                            ? result
                            : MutantResult(result.mutant, notRun),
                    ],
                  ),
              },
              shard: shard,
              notTested: notTested,
            ),
          ),
        )
        as JsonObject;

List<PartFile> partsOf(int count, {Map<String, FileRun> files = whole}) => [
  for (var index = 1; index <= count; index++)
    (
      name: 'part-$index.json',
      content: partReport(Shard(index, count), files: files),
    ),
];

JsonObject fileOf(PartFile part, String path) =>
    ((part.content! as JsonObject)['files']! as JsonObject)[path]!
        as JsonObject;

JsonObject mutantOf(PartFile part, String path, int index) =>
    (fileOf(part, path)['mutants']! as List)[index] as JsonObject;

void main() {
  group('the parts of one run', () {
    for (final count in [1, 2, 3, 4, 7]) {
      test('$count part(s) give the report of the run without --shard', () {
        final merged = mergeParts(partsOf(count));
        expect(merged.problems, isEmpty);
        expect(buildReport(merged.files), buildReport(whole));
        expect(merged.files.keys, ['lib/a.dart', 'lib/b.dart']);
      });
    }

    test('in any order', () {
      final merged = mergeParts(partsOf(3).reversed.toList());
      expect(merged.problems, isEmpty);
      expect(buildReport(merged.files), buildReport(whole));
    });

    test('every result is taken from the part its mutant belongs to', () {
      final parts = partsOf(2);
      // What a part says about its own mutants is the result…
      mutantOf(parts[0], 'lib/a.dart', 2)['duration'] = 77;
      mutantOf(parts[1], 'lib/a.dart', 1)['statusReason'] = 'other words';
      // …and what it says about the time of the others is nothing.
      mutantOf(parts[1], 'lib/a.dart', 2)['duration'] = 11;
      final results = mergeParts(parts).files['lib/a.dart']!.results;
      expect(results[2].milliseconds, 77);
      expect(results[1].reason, 'other words');
      expect(results[0].reason, isNull);
      expect(results.map((result) => result.mutant.offset), [22, 24, 0]);
      expect(results.map((result) => result.mutant.end), [23, 25, 27]);
    });

    test('a run without files', () {
      final merged = mergeParts(partsOf(2, files: const {}));
      expect(merged.problems, isEmpty);
      expect(merged.files, isEmpty);
    });

    test('a mutant at the very end of a source, and one of all of it', () {
      final merged = mergeParts(partsOf(2));
      final end = merged.files['lib/b.dart']!.results[3].mutant;
      expect((end.offset, end.end), (sourceB.length, sourceB.length));
      final all = merged.files['lib/a.dart']!.results[2].mutant;
      expect((all.offset, all.end), (0, sourceA.length));
    });
  });

  test('a source that starts with an empty line', () {
    const source = '\nint a(int x) => x + 1;\n';
    const files = {
      'lib/a.dart': FileRun(
        source: source,
        results: [
          MutantResult(Mutant('ArithmeticOperator', 20, 21, '-'), killed),
          MutantResult(Mutant('NumberLiteral', 22, 23, '2'), survived),
        ],
      ),
    };
    final merged = mergeParts(partsOf(2, files: files));
    expect(merged.problems, isEmpty);
    expect(buildReport(merged.files), buildReport(files));

    // The first line is empty: it has one place, and no second column.
    for (final (column, problems) in [(1, 0), (2, 1)]) {
      final parts = partsOf(2, files: files);
      for (final part in parts) {
        (mutantOf(part, 'lib/a.dart', 0)['location']! as JsonObject)['start'] =
            {'line': 1, 'column': column};
      }
      expect(mergeParts(parts).problems, hasLength(problems * 2));
    }
  });

  group('what is not a part', () {
    test('nothing but files that are no parts', () {
      final merged = mergeParts([(name: 'text.json', content: 'text')]);
      expect(merged.files, isEmpty);
      expect(merged.problems, [
        'text.json is not a part of a run: not a report that dart_mutant '
            'wrote with --shard',
      ]);
    });

    test('a report of a whole run, and what is no report', () {
      final parts = [
        ...partsOf(2),
        (
          name: 'whole.json',
          content: jsonDecode(jsonEncode(buildReport(whole))),
        ),
        (name: 'text.json', content: null),
        (name: 'list.json', content: <Object?>[]),
      ];
      final merged = mergeParts(parts);
      expect(merged.files, isEmpty);
      expect(merged.problems, [
        for (final name in ['whole.json', 'text.json', 'list.json'])
          '$name is not a part of a run: not a report that dart_mutant '
              'wrote with --shard',
      ]);
    });

    void expectNoPart(void Function(JsonObject report) change) {
      final parts = partsOf(2);
      change(parts[1].content! as JsonObject);
      final merged = mergeParts(parts);
      expect(merged.files, isEmpty);
      expect(merged.problems, [
        'part-2.json is not a part of a run: not a report that dart_mutant '
            'wrote with --shard',
      ]);
    }

    test('without files', () {
      expectNoPart((report) => report.remove('files'));
      expectNoPart((report) => report['files'] = <Object?>[]);
    });

    test('a file without a source or without mutants', () {
      for (final key in ['source', 'mutants']) {
        expectNoPart(
          (report) =>
              ((report['files']! as JsonObject)['lib/a.dart']! as JsonObject)
                  .remove(key),
        );
      }
      expectNoPart((report) => (report['files']! as JsonObject)['x'] = 1);
      expectNoPart(
        (report) =>
            ((report['files']! as JsonObject)['lib/a.dart']!
                    as JsonObject)['mutants'] =
                <String, Object?>{},
      );
      expectNoPart(
        (report) =>
            ((report['files']! as JsonObject)['lib/a.dart']!
                    as JsonObject)['source'] =
                1,
      );
    });

    JsonObject first(JsonObject report) =>
        (((report['files']! as JsonObject)['lib/a.dart']!
                    as JsonObject)['mutants']!
                as List)[0]
            as JsonObject;

    test('a mutant that lacks what a mutant has', () {
      for (final key in [
        'mutatorName',
        'replacement',
        'status',
        'duration',
        'location',
      ]) {
        expectNoPart((report) => first(report).remove(key));
      }
      for (final (key, value) in [
        ('mutatorName', 1),
        ('replacement', null),
        ('status', true),
        ('statusReason', 1),
        ('status', 'survived'),
        ('status', 'Ignored'),
        ('status', ''),
        ('duration', -1),
        ('duration', '5'),
        ('duration', 1.5),
        ('location', 'here'),
      ]) {
        expectNoPart((report) => first(report)[key] = value);
      }
      expectNoPart(
        (report) =>
            (((report['files']! as JsonObject)['lib/a.dart']!
                        as JsonObject)['mutants']!
                    as List)[0] =
                'a mutant',
      );
    });

    test('a place that is not in the source', () {
      for (final (edge, position) in [
        ('start', null),
        ('start', {'line': 1}),
        ('start', {'column': 1}),
        ('start', {'line': '2', 'column': 7}),
        ('start', {'line': 2, 'column': '7'}),
        ('start', {'line': 0, 'column': 7}),
        ('start', {'line': 2, 'column': 0}),
        // The source has two lines and an empty third one.
        ('start', {'line': 4, 'column': 1}),
        ('start', {'line': 9, 'column': 1}),
        ('end', {'line': 4, 'column': 1}),
        ('end', {'line': 3, 'column': 2}),
        // Past the end of its line: that would be a place in the next one.
        ('start', {'line': 1, 'column': 17}),
        ('end', {'line': 2, 'column': 12}),
        ('end', {'line': 2, 'column': 9223372036854775807}),
        // The end is before the start.
        ('end', {'line': 2, 'column': 6}),
        ('end', {'line': 1, 'column': 16}),
      ]) {
        expectNoPart(
          (report) =>
              (first(report)['location']! as JsonObject)[edge] = position,
        );
      }
    });

    test('a place at the edges of the source is one', () {
      for (final (edge, position) in [
        // The end of a line, before its line end.
        ('start', {'line': 1, 'column': 16}),
        ('end', {'line': 2, 'column': 11}),
        ('start', {'line': 1, 'column': 1}),
        ('end', {'line': 3, 'column': 1}),
        ('end', {'line': 2, 'column': 7}),
      ]) {
        final parts = partsOf(2);
        for (final part in parts) {
          (mutantOf(part, 'lib/a.dart', 0)['location']! as JsonObject)[edge] =
              position;
        }
        expect(mergeParts(parts).problems, isEmpty, reason: '$edge $position');
      }
    });
  });

  group('parts that are not the parts of one run', () {
    test('a part is missing', () {
      final parts = partsOf(4)..removeAt(2);
      final merged = mergeParts(parts);
      expect(merged.files, isEmpty);
      expect(merged.problems, ['shard 3/4 is missing']);
      expect(mergeParts([partsOf(4)[1]]).problems, [
        'shard 1/4 is missing',
        'shard 3/4 is missing',
        'shard 4/4 is missing',
      ]);
      expect(mergeParts(partsOf(4)..removeAt(0)).problems, [
        'shard 1/4 is missing',
      ]);
      expect(mergeParts(partsOf(4)..removeLast()).problems, [
        'shard 4/4 is missing',
      ]);
    });

    test('of many parts that are missing, the first twenty are named', () {
      List<String> problemsOf(int count) => mergeParts([
        (name: 'p', content: partReport(Shard(2, count), files: const {})),
      ]).problems;
      expect(problemsOf(21), [
        'shard 1/21 is missing',
        for (var index = 3; index <= 21; index++) 'shard $index/21 is missing',
      ]);
      expect(problemsOf(22), [
        'shard 1/22 is missing',
        for (var index = 3; index <= 21; index++) 'shard $index/22 is missing',
        'more parts of the 22 are missing',
      ]);
      // However many a file claims there are.
      final many = problemsOf(4611686018427387904);
      expect(many, hasLength(21));
      expect(many.last, 'more parts of the 4611686018427387904 are missing');
    });

    test('a part is given twice', () {
      final parts = partsOf(2);
      final merged = mergeParts([
        ...parts,
        (name: 'again.json', content: parts[1].content),
      ]);
      expect(merged.files, isEmpty);
      expect(merged.problems, [
        'shard 2/2 is given twice (part-2.json, again.json)',
      ]);
      // Twice, and another one not at all.
      expect(
        mergeParts([
          parts[0],
          (name: 'again.json', content: parts[0].content),
        ]).problems,
        [
          'shard 1/2 is given twice (part-1.json, again.json)',
          'shard 2/2 is missing',
        ],
      );
    });

    test('the parts divide the run into different numbers', () {
      final merged = mergeParts([
        partsOf(2)[0],
        (name: 'of-3.json', content: partReport(const Shard(2, 3))),
      ]);
      expect(merged.files, isEmpty);
      expect(merged.problems, [
        'shard 2/3 (of-3.json) is a part of another run than shard 1/2 '
            '(part-1.json): the number of parts differs',
      ]);
    });

    test('different numbers: nothing is said about which parts there '
        'are, and the first part is the one with the lowest index', () {
      final merged = mergeParts([
        (name: 'of-3.json', content: partReport(const Shard(3, 3))),
        partsOf(2)[0],
      ]);
      expect(merged.problems, [
        'shard 3/3 (of-3.json) is a part of another run than shard 1/2 '
            '(part-1.json): the number of parts differs',
      ]);
    });

    test('a part that is given twice is not looked at any further', () {
      final parts = partsOf(2);
      final other = partReport(const Shard(2, 2));
      ((other['files']! as JsonObject)['lib/a.dart']! as JsonObject)['source'] =
          '$sourceA ';
      expect(
        mergeParts([...parts, (name: 'other.json', content: other)]).problems,
        ['shard 2/2 is given twice (part-2.json, other.json)'],
      );
    });

    test('a part of another version of the tool or of the mutators', () {
      for (final (change, versions) in <(void Function(JsonObject), String)>[
        (
          (report) => (report['framework']! as JsonObject)['version'] = '0.0.9',
          'dart_mutant 0.0.9, mutators 2',
        ),
        (
          (report) => (report['framework']! as JsonObject)['name'] = 'other',
          'other 0.1.1, mutators 2',
        ),
        (
          (report) => (report['config']! as JsonObject)['mutatorsVersion'] = 1,
          'dart_mutant 0.1.1, mutators 1',
        ),
        (
          (report) =>
              (report['config']! as JsonObject).remove('mutatorsVersion'),
          'dart_mutant 0.1.1, mutators null',
        ),
        ((report) => report.remove('framework'), 'null null, mutators 2'),
      ]) {
        final parts = partsOf(2);
        change(parts[1].content! as JsonObject);
        final merged = mergeParts(parts);
        expect(merged.files, isEmpty);
        expect(merged.problems, [
          'shard 2/2 (part-2.json) was written by $versions; this is '
              'dart_mutant 0.1.1, mutators 2',
        ]);
      }
    });

    test('a file could not be mutation tested in a part', () {
      final parts = [
        partsOf(2)[0],
        (
          name: 'part-2.json',
          content: partReport(
            const Shard(2, 2),
            notTested: ['lib/c.dart', 'lib/d.dart'],
          ),
        ),
      ];
      final merged = mergeParts(parts);
      expect(merged.files, isEmpty);
      expect(merged.problems, [
        'shard 2/2 (part-2.json): lib/c.dart could not be mutation tested',
        'shard 2/2 (part-2.json): lib/d.dart could not be mutation tested',
      ]);
      // Also when it is the first part, and when every part says so.
      expect(
        mergeParts([
          for (final index in [1, 2])
            (
              name: 'p$index',
              content: partReport(
                Shard(index, 2),
                files: const {},
                notTested: ['lib/a.dart'],
              ),
            ),
        ]).problems,
        [
          'shard 1/2 (p1): lib/a.dart could not be mutation tested',
          'shard 2/2 (p2): lib/a.dart could not be mutation tested',
        ],
      );
    });

    test('the parts have different files', () {
      final onlyA = {'lib/a.dart': whole['lib/a.dart']!};
      final parts = [
        partsOf(3)[0],
        (
          name: 'part-2.json',
          content: partReport(const Shard(2, 3), files: onlyA),
        ),
        partsOf(3)[2],
      ];
      final merged = mergeParts(parts);
      expect(merged.files, isEmpty);
      expect(merged.problems, [
        'shard 2/3 (part-2.json) has other files than shard 1/3 '
            '(part-1.json) (lib/a.dart / lib/a.dart, lib/b.dart)',
      ]);
      // More files, and the same ones in another order.
      expect(
        mergeParts([
          (name: 'p1', content: partReport(const Shard(1, 2), files: onlyA)),
          (name: 'p2', content: partReport(const Shard(2, 2))),
        ]).problems,
        [
          'shard 2/2 (p2) has other files than shard 1/2 (p1) '
              '(lib/a.dart, lib/b.dart / lib/a.dart)',
        ],
      );
      expect(
        mergeParts([
          partsOf(2)[0],
          (
            name: 'p2',
            content: partReport(
              const Shard(2, 2),
              files: {
                'lib/b.dart': whole['lib/b.dart']!,
                'lib/a.dart': whole['lib/a.dart']!,
              },
            ),
          ),
        ]).problems,
        hasLength(1),
      );
    });

    test('a file has another source in a part', () {
      final parts = partsOf(2);
      fileOf(parts[1], 'lib/b.dart')['source'] = '$sourceB ';
      final merged = mergeParts(parts);
      expect(merged.files, isEmpty);
      expect(merged.problems, [
        'shard 2/2 (part-2.json): lib/b.dart is not the source shard 1/2 '
            '(part-1.json) mutated',
      ]);
    });

    test('the first part is the one the others are compared with, in '
        'whatever order they are given', () {
      final parts = partsOf(2);
      fileOf(parts[1], 'lib/b.dart')['source'] = '$sourceB ';
      expect(mergeParts(parts.reversed.toList()).problems, [
        'shard 2/2 (part-2.json): lib/b.dart is not the source shard 1/2 '
            '(part-1.json) mutated',
      ]);
    });

    test('a file has other mutants in a part', () {
      var parts = partsOf(2);
      (fileOf(parts[1], 'lib/b.dart')['mutants']! as List).removeLast();
      expect(mergeParts(parts).problems, [
        'shard 2/2 (part-2.json): lib/b.dart has 3 mutant(s), shard 1/2 '
            '(part-1.json) has 4',
      ]);

      for (final (key, value) in <(String, Object?)>[
        ('id', 'lib/b.dart#9'),
        ('mutatorName', 'Other'),
        ('replacement', '*'),
        (
          'location',
          {
            'start': {'line': 2, 'column': 8},
            'end': {'line': 2, 'column': 9},
          },
        ),
        ('more', 1),
      ]) {
        parts = partsOf(2);
        mutantOf(parts[1], 'lib/b.dart', 2)[key] = value;
        final merged = mergeParts(parts);
        expect(merged.files, isEmpty, reason: key);
        expect(merged.problems, [
          'shard 2/2 (part-2.json): lib/b.dart: mutant 2 is not the one of '
              'shard 1/2 (part-1.json)',
        ], reason: key);
      }
    });

    test('a mutant has a status in a part it does not belong to', () {
      final parts = partsOf(2);
      mutantOf(parts[1], 'lib/a.dart', 2)['status'] = 'Killed';
      final merged = mergeParts(parts);
      expect(merged.files, isEmpty);
      expect(merged.problems, [
        'shard 2/2 (part-2.json): lib/a.dart: mutant 2 has a status '
            '(Killed), and belongs to another part',
      ]);
    });

    test('a mutant was not evaluated by its part', () {
      final parts = partsOf(2);
      mutantOf(parts[0], 'lib/b.dart', 0)['status'] = 'Pending';
      mutantOf(parts[1], 'lib/b.dart', 3)['status'] = 'Pending';
      final merged = mergeParts(parts);
      expect(merged.files, isEmpty);
      expect(merged.problems, [
        'shard 1/2 (part-1.json): lib/b.dart: mutant 0 belongs to this '
            'part, and was not evaluated',
        'shard 2/2 (part-2.json): lib/b.dart: mutant 3 belongs to this '
            'part, and was not evaluated',
      ]);
    });

    test('one line per file and part, for the first mutant that is wrong', () {
      final parts = partsOf(2);
      for (final index in [0, 2]) {
        mutantOf(parts[0], 'lib/a.dart', index)['status'] = 'Pending';
      }
      mutantOf(parts[0], 'lib/b.dart', 1)['status'] = 'Killed';
      expect(mergeParts(parts).problems, [
        'shard 1/2 (part-1.json): lib/a.dart: mutant 0 belongs to this '
            'part, and was not evaluated',
        'shard 1/2 (part-1.json): lib/b.dart: mutant 1 has a status '
            '(Killed), and belongs to another part',
      ]);
    });
  });
}
