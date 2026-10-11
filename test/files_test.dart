import 'dart:io';

import 'package:dart_mutant/src/io/files.dart';
import 'package:test/test.dart';

import 'support/package_fixture.dart';

void main() {
  late PackageFixture package;

  setUp(() => package = PackageFixture());

  tearDown(() => package.delete());

  test('existsExact compares the spelling, also where the file system does '
      'not', () {
    package.write('lib/pricing/Discount.dart', '');
    expect(existsExact(package.path, 'lib/pricing/Discount.dart'), isTrue);
    expect(existsExact(package.path, 'lib/pricing/discount.dart'), isFalse);
    expect(existsExact(package.path, 'lib/Pricing/Discount.dart'), isFalse);
    expect(existsExact(package.path, 'lib/pricing'), isFalse);
    expect(existsExact(package.path, 'lib/none/a.dart'), isFalse);
  });

  test('readText keeps a byte order mark and survives bytes that are not '
      'UTF-8', () {
    package.file('a.txt').writeAsBytesSync([0xEF, 0xBB, 0xBF, 0x61]);
    package.file('b.txt').writeAsBytesSync([0x61, 0xFF]);
    expect(readText('${package.path}/a.txt'), '\uFEFFa');
    expect(readText('${package.path}/b.txt'), 'a\uFFFD');
    expect(hasByteOrderMark([0xEF, 0xBB]), isFalse);
  });

  test('dartFilesMatching: Dart files that are no tests, outside the '
      'directories of the tools', () {
    for (final path in [
      'lib/a.dart',
      'lib/a_test.dart',
      'lib/src/b.dart',
      'lib/src/notes.txt',
      'lib/.hidden/c.dart',
      'build/lib/d.dart',
      'test/a_test.dart',
      'bin/tool.dart',
    ]) {
      package.write(path, '');
    }
    expect(dartFilesMatching(package.path, 'lib/**.dart'), [
      'lib/a.dart',
      'lib/src/b.dart',
    ]);
    expect(dartFilesMatching(package.path, 'lib/*.dart'), ['lib/a.dart']);
    expect(dartFilesMatching(package.path, '**.dart'), [
      'bin/tool.dart',
      'lib/a.dart',
      'lib/src/b.dart',
    ]);
    expect(dartFilesMatching(package.path, '{bin,lib/src}/*.dart'), [
      'bin/tool.dart',
      'lib/src/b.dart',
    ]);
    expect(dartFilesMatching(package.path, 'lib/x*.dart'), isEmpty);
    expect(
      dartFilesMatching('${package.path}${Platform.pathSeparator}none', '**'),
      isEmpty,
    );
  });
}
