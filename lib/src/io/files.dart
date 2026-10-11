import 'dart:convert';
import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// True when [relativePath] (with `/`) is a file under [rootDir] with
/// exactly this spelling.
///
/// The default macOS and Windows file systems treat `Discount.dart` and
/// `discount.dart` as the same file; Linux (CI) does not. Each segment is
/// therefore compared with the directory listing.
bool existsExact(String rootDir, String relativePath) {
  var current = rootDir;
  for (final segment in relativePath.split('/')) {
    final List<String> entries;
    try {
      entries = [
        for (final entity in Directory(current).listSync())
          p.basename(entity.path),
      ];
    } on FileSystemException {
      return false;
    }
    if (!entries.contains(segment)) {
      return false;
    }
    current = p.join(current, segment);
  }
  return FileSystemEntity.isFileSync(current);
}

/// Reads a file as UTF-8. A byte that is not UTF-8 becomes U+FFFD instead of
/// an error, and a byte order mark is kept.
String readText(String path) {
  final bytes = File(path).readAsBytesSync();
  final text = utf8.decode(bytes, allowMalformed: true);
  return hasByteOrderMark(bytes) && !text.startsWith('﻿') ? '﻿$text' : text;
}

bool hasByteOrderMark(List<int> bytes) =>
    bytes.length >= 3 &&
    bytes[0] == 0xEF &&
    bytes[1] == 0xBB &&
    bytes[2] == 0xBF;

/// The `.dart` files below [rootDir] that [pattern] (a glob, relative to
/// [rootDir], with `/`) matches, sorted, with `/`.
///
/// Left out: test files (`*_test.dart`), and what is below a directory whose
/// name starts with `.` or is `build` (the output of the tools).
List<String> dartFilesMatching(String rootDir, String pattern) {
  final glob = Glob(pattern, context: p.posix);
  final found = <String>[];
  void visit(Directory directory, String prefix) {
    final List<FileSystemEntity> entities;
    try {
      entities = directory.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final entity in entities) {
      final name = p.basename(entity.path);
      final path = '$prefix$name';
      if (entity is Directory) {
        if (!name.startsWith('.') && name != 'build') {
          visit(entity, '$path/');
        }
      } else if (entity is File &&
          name.endsWith('.dart') &&
          !name.endsWith('_test.dart') &&
          glob.matches(path)) {
        found.add(path);
      }
    }
  }

  visit(Directory(rootDir), '');
  return found..sort();
}
