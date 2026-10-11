import 'dart:io';

import 'package:dart_mutant/src/version.dart';
import 'package:test/test.dart';

void main() {
  test('packageVersion is the version of pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('\nversion: $packageVersion\n'));
  });

  test('CHANGELOG.md has an entry for the version', () {
    final changelog = File('CHANGELOG.md').readAsStringSync();
    expect(changelog, contains('## $packageVersion'));
  });
}
