import 'package:dart_mutant/src/io/process.dart';
import 'package:test/test.dart';

void main() {
  group('signalMayFollow', () {
    test('a child that ended well waits for nothing', () {
      expect(signalMayFollow(exitCode: 0, terminal: true), isFalse);
    });

    test('an ordinary failure without a terminal waits for nothing', () {
      expect(signalMayFollow(exitCode: 1, terminal: false), isFalse);
      expect(signalMayFollow(exitCode: 127, terminal: false), isFalse);
    });

    test('with a terminal a failure may be a Ctrl-C', () {
      expect(signalMayFollow(exitCode: 1, terminal: true), isTrue);
    });

    test('the code of a signal is waited for without a terminal as well', () {
      expect(signalMayFollow(exitCode: -2, terminal: false), isTrue);
      expect(signalMayFollow(exitCode: 128, terminal: false), isTrue);
      expect(signalMayFollow(exitCode: 130, terminal: false), isTrue);
    });
  });
}
