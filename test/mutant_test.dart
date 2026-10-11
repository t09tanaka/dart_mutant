import 'package:dart_mutant/src/mutant.dart';
import 'package:test/test.dart';

void main() {
  group('applyTo', () {
    test('the text from offset to end, end not included, is replaced', () {
      const source = 'a + b';
      expect(const Mutant('M', 2, 3, '-').applyTo(source), 'a - b');
      expect(const Mutant('M', 0, 1, 'xy').applyTo(source), 'xy + b');
      expect(const Mutant('M', 4, 5, '').applyTo(source), 'a + ');
    });

    test('an empty range puts text in', () {
      expect(const Mutant('M', 1, 1, '!').applyTo('ab'), 'a!b');
    });
  });

  group('inSourceOrder', () {
    test('by offset', () {
      const first = Mutant('A', 1, 2, 'x');
      const second = Mutant('B', 5, 6, 'y');
      const third = Mutant('C', 9, 10, 'z');
      expect(inSourceOrder([third, first, second]), [first, second, third]);
      expect(inSourceOrder([second, third, first]), [first, second, third]);
    });

    test('mutants at the same place keep the order they were found in', () {
      const early = Mutant('A', 0, 9, 'x');
      const a = Mutant('B', 4, 5, 'a');
      const b = Mutant('C', 4, 9, 'b');
      const c = Mutant('D', 4, 5, 'c');
      expect(inSourceOrder([a, b, c, early]), [early, a, b, c]);
      expect(inSourceOrder([c, b, early, a]), [early, c, b, a]);
    });

    test('neighbours that were found in the other order', () {
      const left = Mutant('A', 4, 5, 'x');
      const right = Mutant('B', 5, 6, 'y');
      expect(inSourceOrder([right, left]), [left, right]);
      expect(inSourceOrder([left, right]), [left, right]);
    });

    test('many mutants at one place keep their order as well (a sort '
        'that is not stable would not)', () {
      final found = [
        for (var index = 0; index < 200; index++) Mutant('M$index', 7, 8, 'x'),
      ];
      final sorted = inSourceOrder([
        ...found,
        const Mutant('first', 0, 1, 'y'),
      ]);
      expect(sorted.first.mutator, 'first');
      expect(sorted.skip(1), found);
    });

    test('the list that is given is left as it is', () {
      const first = Mutant('A', 1, 2, 'x');
      const second = Mutant('B', 5, 6, 'y');
      final given = [second, first];
      expect(inSourceOrder(given), [first, second]);
      expect(given, [second, first]);
      expect(inSourceOrder(const []), isEmpty);
    });
  });
}
