import 'dart:io';

import 'package:path/path.dart' as p;

import '../parallel.dart';

/// Copies the package in [root] to [destination] (both absolute, [root]
/// without symbolic links), without what [skippedInCopy] leaves out.
///
/// The times of the files are kept: `dart test` and `flutter test` compare
/// the time of `pubspec.yaml` and `pubspec.lock` with the time of
/// `.dart_tool/package_config.json` to decide whether the packages are still
/// resolved, and a copy whose files are all from now can look unresolved.
///
/// A symbolic link is copied as a link: one that points into the package
/// points into the copy, one that points outside points at the same place.
void copyPackage(String root, String destination) {
  void visit(Directory from, String to, String prefix) {
    Directory(to).createSync(recursive: true);
    for (final entity in from.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      final path = '$prefix$name';
      final target = p.join(to, name);
      if (entity is Link) {
        final link = entity.targetSync();
        final absolute = p.normalize(p.join(from.path, link));
        final inside = absolute == root || p.isWithin(root, absolute);
        Link(target).createSync(
          p.isRelative(link)
              // The same place outside the package, or the same file of
              // the copy.
              ? (inside ? link : absolute)
              // An absolute link into the package would make the copy read
              // the package's file, where no mutant is.
              : (inside
                    ? p.join(destination, p.relative(absolute, from: root))
                    : link),
        );
      } else if (entity is Directory) {
        if (!skippedInCopy(path)) {
          visit(entity, target, '$path/');
        }
      } else if (entity is File) {
        entity.copySync(target);
        File(target).setLastModifiedSync(entity.lastModifiedSync());
      }
    }
  }

  visit(Directory(root), destination, '');
}

/// Removes [directory] with everything in it, if it is there.
void removeDirectory(String directory) {
  final found = Directory(directory);
  if (found.existsSync()) {
    found.deleteSync(recursive: true);
  }
}
