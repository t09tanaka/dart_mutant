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
}
