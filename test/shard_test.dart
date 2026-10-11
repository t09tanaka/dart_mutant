import 'dart:convert';

import 'package:dart_mutant/src/shard.dart';
import 'package:test/test.dart';

void main() {
  group('Shard', () {
    test('the numbers are dealt out in turn, from the first part', () {
      List<int> of(Shard shard) => [
        for (var mutant = 0; mutant < 10; mutant++)
          if (shard.has(mutant)) mutant,
      ];
      expect(of(const Shard(1, 3)), [0, 3, 6, 9]);
      expect(of(const Shard(2, 3)), [1, 4, 7]);
      expect(of(const Shard(3, 3)), [2, 5, 8]);
      expect(of(const Shard(1, 1)), hasLength(10));
    });

    test('every number belongs to exactly one part', () {
      for (final count in [1, 2, 4, 7]) {
        for (var mutant = 0; mutant < 30; mutant++) {
          expect(
            [
              for (var index = 1; index <= count; index++)
                if (Shard(index, count).has(mutant)) index,
            ],
            hasLength(1),
            reason: '$mutant of $count',
          );
        }
      }
    });

    test('label', () {
      expect(const Shard(2, 4).label, '2/4');
    });
  });

  group('parseShard', () {
    test('an index from 1 to the count', () {
      for (final (value, index, count) in [
        ('1/1', 1, 1),
        ('1/4', 1, 4),
        ('4/4', 4, 4),
        ('12/30', 12, 30),
      ]) {
        final shard = parseShard(value)!;
        expect((shard.index, shard.count), (index, count), reason: value);
      }
    });

    test('anything else is none', () {
      for (final value in [
        '0/4',
        '5/4',
        '0/0',
        '2',
        '/4',
        '2/',
        '2/4/8',
        '-1/4',
        '1/-4',
        ' 1/4',
        '1/4 ',
        'x1/4',
        '1/4x',
        '1 / 4',
        'a/b',
        '1.0/4',
        '99999999999999999999/99999999999999999999',
        '1/99999999999999999999',
        '',
      ]) {
        expect(parseShard(value), isNull, reason: '"$value"');
      }
    });
  });

  group('reportConfig', () {
    test('a whole run: the version of the mutators and nothing else', () {
      expect(reportConfig(), {'mutatorsVersion': 2});
      expect(reportConfig(notTested: ['lib/a.dart']), {'mutatorsVersion': 2});
    });

    test('a part: which one, and the files that could not be tested', () {
      expect(reportConfig(shard: const Shard(2, 4)), {
        'mutatorsVersion': 2,
        'shard': {'index': 2, 'count': 4, 'notTested': <String>[]},
      });
      expect(
        reportConfig(
          shard: const Shard(1, 2),
          notTested: ['lib/a.dart'],
        )['shard'],
        {
          'index': 1,
          'count': 2,
          'notTested': ['lib/a.dart'],
        },
      );
    });
  });

  group('partOf', () {
    Object? reportWith(Object? shard) => jsonDecode(
      jsonEncode({
        'files': <String, Object?>{},
        'config': {'shard': shard},
      }),
    );

    test('what reportConfig wrote', () {
      final part = partOf(
        jsonDecode(
          jsonEncode({
            'config': reportConfig(
              shard: const Shard(3, 4),
              notTested: ['lib/a.dart'],
            ),
          }),
        ),
      )!;
      expect((part.shard.index, part.shard.count), (3, 4));
      expect(part.notTested, ['lib/a.dart']);
      final last = partOf(
        reportWith({'index': 1, 'count': 1, 'notTested': <String>[]}),
      )!;
      expect((last.shard.index, last.shard.count), (1, 1));
      expect(last.notTested, isEmpty);
    });

    test('a report of a whole run is no part', () {
      expect(
        partOf(jsonDecode(jsonEncode({'config': reportConfig()}))),
        isNull,
      );
      expect(partOf(<String, Object?>{'files': <String, Object?>{}}), isNull);
    });

    test('anything else is no part', () {
      for (final shard in [
        null,
        '2/4',
        [2, 4],
        {'index': 2, 'count': 4},
        {'index': 2, 'count': 4, 'notTested': 'lib/a.dart'},
        {
          'index': 2,
          'count': 4,
          'notTested': [1],
        },
        {'index': '2', 'count': 4, 'notTested': <String>[]},
        {'index': 2, 'count': '4', 'notTested': <String>[]},
        {'index': 2.5, 'count': 4, 'notTested': <String>[]},
        {'index': 0, 'count': 4, 'notTested': <String>[]},
        {'index': 5, 'count': 4, 'notTested': <String>[]},
        {'count': 4, 'notTested': <String>[]},
        {'index': 2, 'notTested': <String>[]},
      ]) {
        expect(partOf(reportWith(shard)), isNull, reason: '$shard');
      }
      for (final report in [
        null,
        'report',
        <Object?>[],
        <String, Object?>{'config': 1},
        <String, Object?>{'config': <Object?>[]},
        <String, Object?>{
          'shard': {'index': 1, 'count': 1, 'notTested': <String>[]},
        },
      ]) {
        expect(partOf(report), isNull, reason: '$report');
      }
    });
  });
}
