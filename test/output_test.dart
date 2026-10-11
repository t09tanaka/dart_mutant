import 'package:dart_mutant/src/output.dart';
import 'package:test/test.dart';

void main() {
  test('Io hands each line to the function it was given', () {
    final out = <String>[];
    final err = <String>[];
    final io = Io(out: out.add, err: err.add);
    io.out('a');
    io.err('b');
    expect(out, ['a']);
    expect(err, ['b']);
  });

  test('the name users type', () {
    expect(executable, 'dart_mutant');
  });

  group('tailOf', () {
    String lines(int from, int to) =>
        [for (var line = from; line <= to; line++) 'line $line'].join('\n');

    String indented(int from, int to) => [
      for (var line = from; line <= to; line++) '      line $line',
    ].join('\n');

    test('every line, indented, when there are 25 or fewer', () {
      expect(tailOf('one'), '      one');
      expect(tailOf(lines(1, 25)), indented(1, 25));
    });

    test('the last 25 of more', () {
      expect(tailOf(lines(1, 26)), indented(2, 26));
      expect(tailOf(lines(1, 100)), indented(76, 100));
    });

    test('blank lines at the end do not count', () {
      expect(tailOf('${lines(1, 26)}\n\n  \n'), indented(2, 26));
      expect(tailOf('a\n\nb\n'), '      a\n      \n      b');
    });
  });
}
