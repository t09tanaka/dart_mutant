import 'package:dart_mutant/src/lock_state.dart';
import 'package:test/test.dart';

void main() {
  group('lockedByAnother', () {
    test('macOS and Linux: EAGAIN of either, and EACCES', () {
      for (final code in [11, 13, 35]) {
        expect(lockedByAnother(code, windows: false), isTrue, reason: '$code');
      }
    });

    test('macOS and Linux: any other code is a file that cannot be locked', () {
      for (final code in [null, 0, 1, 10, 12, 14, 33, 34, 36, 45, 77]) {
        expect(lockedByAnother(code, windows: false), isFalse, reason: '$code');
      }
    });

    test('Windows: the lock violation, and nothing else', () {
      expect(lockedByAnother(33, windows: true), isTrue);
      for (final code in [null, 0, 5, 11, 13, 32, 34, 35]) {
        expect(lockedByAnother(code, windows: true), isFalse, reason: '$code');
      }
    });
  });

  group('the holder of a lock', () {
    test('what is written is what is read', () {
      final text = lockHolder(pid: 4242, started: '2026-01-02T03:04:05.678Z');
      expect(text, '{"pid":4242,"started":"2026-01-02T03:04:05.678Z"}');
      expect(readLockHolder(text), (
        pid: 4242,
        started: '2026-01-02T03:04:05.678Z',
      ));
    });

    test('an empty file, and one that is not JSON, name nobody', () {
      for (final text in ['', '{"pid":', 'pid 1']) {
        expect(readLockHolder(text), (pid: null, started: null), reason: text);
      }
    });

    test('JSON that is no object names nobody', () {
      for (final text in ['[1, "x"]', '7', 'null', '"pid"']) {
        expect(readLockHolder(text), (pid: null, started: null), reason: text);
      }
    });

    test('each of the two is read on its own, and only with its type', () {
      expect(readLockHolder('{"pid": 7}'), (pid: 7, started: null));
      expect(readLockHolder('{"started": "now"}'), (pid: null, started: 'now'));
      expect(readLockHolder('{"pid": "7", "started": 8}'), (
        pid: null,
        started: null,
      ));
      expect(readLockHolder('{"pid": 7.5, "started": "now"}'), (
        pid: null,
        started: 'now',
      ));
    });
  });
}
