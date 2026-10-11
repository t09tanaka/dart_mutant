import 'dart:convert';

import 'package:dart_mutant/src/json.dart';
import 'package:test/test.dart';

void main() {
  group('asObject', () {
    test('a JSON object, as it is decoded', () {
      final decoded = jsonDecode('{"a": 1, "b": null}');
      expect(asObject(decoded), same(decoded));
      expect(asObject(<String, Object?>{}), isEmpty);
    });

    test('anything else is no object', () {
      for (final value in [
        null,
        1,
        'a',
        true,
        <Object?>[],
        <int, Object?>{1: 2},
      ]) {
        expect(asObject(value), isNull, reason: '$value');
      }
    });
  });

  group('asStrings', () {
    test('a list of strings, as a list of its own', () {
      final decoded = jsonDecode('["a", "b"]');
      final strings = asStrings(decoded);
      expect(strings, ['a', 'b']);
      expect(strings, isNot(same(decoded)));
      expect(asStrings(<Object?>[]), isEmpty);
    });

    test('a list with anything else in it is none', () {
      expect(asStrings(['a', 1]), isNull);
      expect(asStrings([null]), isNull);
      expect(
        asStrings([
          'a',
          <String>['b'],
        ]),
        isNull,
      );
    });

    test('what is no list is none', () {
      for (final value in [
        null,
        'a',
        1,
        <String, Object?>{'a': 'b'},
      ]) {
        expect(asStrings(value), isNull, reason: '$value');
      }
    });
  });

  group('sameJson', () {
    test('objects: the same keys and values, in any order', () {
      expect(sameJson({'a': 1, 'b': 'x'}, {'b': 'x', 'a': 1}), isTrue);
      expect(sameJson(<String, Object?>{}, <String, Object?>{}), isTrue);
      expect(sameJson({'a': 1}, {'a': 2}), isFalse);
      expect(sameJson({'a': 1}, {'b': 1}), isFalse);
      expect(sameJson({'a': 1}, {'a': 1, 'b': 2}), isFalse);
      expect(sameJson({'a': 1, 'b': 2}, {'a': 1}), isFalse);
      // A key that is there with null is not a key that is missing.
      expect(sameJson({'a': null}, {'b': null}), isFalse);
      expect(sameJson({'a': null}, {'a': null}), isTrue);
    });

    test('lists: the same items in the same order', () {
      expect(sameJson([1, 'a', null], [1, 'a', null]), isTrue);
      expect(sameJson(<Object?>[], <Object?>[]), isTrue);
      expect(sameJson([1, 2], [2, 1]), isFalse);
      expect(sameJson([1, 2], [1]), isFalse);
      expect(sameJson([1], [1, 2]), isFalse);
    });

    test('what is nested is compared the same way', () {
      Object? decoded(String text) => jsonDecode(text);
      expect(
        sameJson(
          decoded('{"a": [{"b": [1, {"c": null}]}]}'),
          decoded('{"a": [{"b": [1, {"c": null}]}]}'),
        ),
        isTrue,
      );
      expect(
        sameJson(
          decoded('{"a": [{"b": [1, {"c": null}]}]}'),
          decoded('{"a": [{"b": [1, {"c": 0}]}]}'),
        ),
        isFalse,
      );
      expect(
        sameJson(
          {
            'a': [1, 2],
          },
          {
            'a': [1, 3],
          },
        ),
        isFalse,
      );
    });

    test('values, and things of different kinds', () {
      expect(sameJson(1, 1), isTrue);
      expect(sameJson('a', 'a'), isTrue);
      expect(sameJson(null, null), isTrue);
      expect(sameJson(1, '1'), isFalse);
      expect(sameJson(null, 0), isFalse);
      expect(sameJson(<Object?>[], <String, Object?>{}), isFalse);
      expect(sameJson(<String, Object?>{}, <Object?>[]), isFalse);
      expect(sameJson(<Object?>[], null), isFalse);
      expect(sameJson(<String, Object?>{}, null), isFalse);
    });
  });
}
