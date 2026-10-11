import 'dart:io';

import 'package:dart_mutant/src/io/work_copies.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String root;
  late String copy;

  setUp(() {
    temp = Directory(
      Directory.systemTemp
          .createTempSync('dart_mutant_copy_')
          .resolveSymbolicLinksSync(),
    );
    root = '${temp.path}/app';
    copy = '$root/.dart_tool/dart_mutant/work/1';
  });

  tearDown(() => temp.deleteSync(recursive: true));

  void write(String path, [String content = 'x']) => File('$root/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  List<String> copied() => [
    for (final entity in Directory(
      copy,
    ).listSync(recursive: true, followLinks: false))
      if (entity is! Directory) entity.path.substring(copy.length + 1),
  ]..sort();

  test('the package is copied without what the tools write, also into a '
      'directory inside it', () {
    for (final path in [
      'pubspec.yaml',
      'lib/a.dart',
      'lib/src/a.g.dart',
      'lib/src/build/builder.dart',
      'test/a_test.dart',
      '.dart_tool/package_config.json',
      '.dart_tool/pub/bin/test/test.snapshot',
      '.fvm/fvm_config.json',
      // Left out.
      '.git/HEAD',
      'build/app.dill',
      'android/app/build/a.apk',
      'coverage/lcov.info',
      'reports/mutation/mutation.json',
      'ios/Pods/Manifest.lock',
      '.dart_tool/dart_mutant/incremental.json',
      '.dart_tool/dart_mutant/work/2/pubspec.yaml',
      '.dart_tool/flutter_build/a',
    ]) {
      write(path, path);
    }
    Directory('$root/empty').createSync();
    copyPackage(root, copy);
    expect(copied(), [
      '.dart_tool/package_config.json',
      '.dart_tool/pub/bin/test/test.snapshot',
      '.fvm/fvm_config.json',
      'lib/a.dart',
      'lib/src/a.g.dart',
      'lib/src/build/builder.dart',
      'pubspec.yaml',
      'test/a_test.dart',
    ]);
    expect(
      File('$copy/lib/src/a.g.dart').readAsStringSync(),
      'lib/src/a.g.dart',
    );
    expect(Directory('$copy/empty').existsSync(), isTrue);
  });

  test('the times of the files are kept: the test runners compare the '
      'pubspec with the package configuration', () {
    write('pubspec.yaml');
    write('.dart_tool/package_config.json');
    final resolved = DateTime(2024, 5, 6, 7, 8, 9);
    final edited = DateTime(2024, 1, 2, 3, 4, 5);
    File('$root/pubspec.yaml').setLastModifiedSync(edited);
    File('$root/.dart_tool/package_config.json').setLastModifiedSync(resolved);
    copyPackage(root, copy);
    expect(File('$copy/pubspec.yaml').lastModifiedSync(), edited);
    expect(
      File('$copy/.dart_tool/package_config.json').lastModifiedSync(),
      resolved,
    );
  });

  test('a link into the package points into the copy, a link out of it '
      'points where it did', () {
    write('lib/a.dart', 'a');
    write('shared/b.dart', 'b');
    File('${temp.path}/outside.dart').writeAsStringSync('outside');
    Directory('${temp.path}/outside').createSync();
    Link('$root/lib/relative.dart').createSync('a.dart');
    Link('$root/lib/absolute.dart').createSync('$root/lib/a.dart');
    Link('$root/lib/shared').createSync('../shared');
    Link('$root/lib/out_relative.dart').createSync('../../outside.dart');
    Link('$root/lib/out_absolute').createSync('${temp.path}/outside');
    Link('$root/lib/broken.dart').createSync('nothing.dart');
    copyPackage(root, copy);

    expect(Link('$copy/lib/relative.dart').targetSync(), 'a.dart');
    expect(Link('$copy/lib/absolute.dart').targetSync(), '$copy/lib/a.dart');
    expect(Link('$copy/lib/shared').targetSync(), '../shared');
    expect(
      Link('$copy/lib/out_relative.dart').targetSync(),
      '${temp.path}/outside.dart',
    );
    expect(Link('$copy/lib/out_absolute').targetSync(), '${temp.path}/outside');
    expect(Link('$copy/lib/broken.dart').targetSync(), 'nothing.dart');

    // What is written through a link into the package stays in the copy.
    File('$copy/lib/absolute.dart').writeAsStringSync('mutant');
    File('$copy/lib/shared/b.dart').writeAsStringSync('mutant');
    expect(File('$root/lib/a.dart').readAsStringSync(), 'a');
    expect(File('$root/shared/b.dart').readAsStringSync(), 'b');
    expect(File('$copy/lib/out_relative.dart').readAsStringSync(), 'outside');
  }, testOn: '!windows');

  test('removeDirectory: with everything in it, and nothing when it is '
      'not there', () {
    write('a/b/c.dart');
    removeDirectory('$root/a');
    expect(Directory('$root/a').existsSync(), isFalse);
    removeDirectory('$root/a');
  });
}
