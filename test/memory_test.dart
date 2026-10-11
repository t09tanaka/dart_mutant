import 'package:dart_mutant/src/memory.dart';
import 'package:test/test.dart';

void main() {
  test('processListing: every process, with its parent and its memory, '
      'without a header', () {
    expect(processListing, ['-A', '-o', 'pid=,ppid=,rss=']);
  });

  group('processTree', () {
    // 10 started 11 and 12, 11 started 13; 20 is somebody else's.
    const listing = '''
    1     0   900
   10     1   100
   11    10    20
   12    10     3
   13    11  4000
   20     1 70000
''';

    test('the processes below the root, and the memory of all of them with '
        'the root', () {
      final tree = processTree(listing, 10);
      expect(tree.descendants, [11, 12, 13]);
      expect(tree.kilobytes, 4123);
    });

    test('a process that started nothing is alone', () {
      final tree = processTree(listing, 13);
      expect(tree.descendants, isEmpty);
      expect(tree.kilobytes, 4000);
    });

    test('a root that is not listed holds nothing', () {
      final tree = processTree(listing, 99);
      expect(tree.descendants, isEmpty);
      expect(tree.kilobytes, 0);
      expect(processTree('', 10).kilobytes, 0);
    });

    test('the children of a process are found in the order of the list, '
        'and what they started after all of them', () {
      expect(processTree(listing, 1).descendants, [10, 20, 11, 12, 13]);
    });

    test('a line that is not three numbers is left out', () {
      const odd = '''
  PID  PPID   RSS
   10     1   100
   11    10
   12    10     3     7
   13    10     x
   14     x     5
    x    10     5
   15    10    -
   16    10     8
''';
      final tree = processTree(odd, 10);
      expect(tree.descendants, [16]);
      expect(tree.kilobytes, 108);
    });

    test('tabs and several blanks separate, and blanks around a line do '
        'not count', () {
      final tree = processTree('10\t1 \t 5\n  11   10   6  \n', 10);
      expect(tree.descendants, [11]);
      expect(tree.kilobytes, 11);
    });

    test('a process that is listed as its own parent, and two that are '
        'each the parent of the other, are counted once', () {
      final own = processTree('0 0 7\n1 0 2\n', 0);
      expect(own.descendants, [1]);
      expect(own.kilobytes, 9);
      final ring = processTree('5 6 10\n6 5 20\n7 6 40\n', 5);
      expect(ring.descendants, [6, 7]);
      expect(ring.kilobytes, 70);
    });
  });

  test('memoryLimit: twice the run without a mutant, plus one gigabyte', () {
    expect(memoryLimit(0), 1048576);
    expect(memoryLimit(1), 1048578);
    expect(memoryLimit(600 * 1024), 2277376);
  });

  test('megabytes: rounded up', () {
    expect(megabytes(0), 0);
    expect(megabytes(1), 1);
    expect(megabytes(1024), 1);
    expect(megabytes(1025), 2);
    expect(megabytes(2277376), 2224);
  });

  test('overMemoryReason', () {
    expect(
      overMemoryReason(2277376),
      'the test run used more than 2224 MB of memory and was ended',
    );
  });
}
