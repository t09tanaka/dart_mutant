import 'dart:convert';

import 'package:dart_mutant/src/parallel.dart';
import 'package:test/test.dart';

String config(List<(String, String)> packages) => jsonEncode({
  'configVersion': 2,
  'packages': [
    for (final (name, rootUri) in packages)
      {'name': name, 'rootUri': rootUri, 'packageUri': 'lib/'},
  ],
});

void main() {
  group('defaultJobs', () {
    for (final (processors, jobs) in [
      (1, 1),
      (2, 1),
      (4, 1),
      (7, 1),
      (8, 2),
      (11, 2),
      (12, 3),
      (16, 4),
      (17, 4),
      (64, 4),
    ]) {
      test('$processors processor(s): $jobs', () {
        expect(defaultJobs(processors), jobs);
      });
    }
  });

  group('skippedInCopy', () {
    for (final path in [
      '.git',
      '.git/HEAD',
      'build',
      'build/app.dill',
      'android/app/build/outputs/a.apk',
      'ios/build/a',
      'linux/build/a',
      'macos/build/a',
      'web/build/a',
      'windows/build/a',
      'windows/runner/build/a',
      'ios/Pods/Manifest.lock',
      'android/.gradle/8.0',
      'node_modules/a/index.js',
      '.idea/workspace.xml',
      'ios/.symlinks/plugins',
      'coverage',
      'coverage/lcov.info',
      'reports/mutation/mutation.json',
      '.dart_tool/dart_mutant',
      '.dart_tool/dart_mutant/work/1/pubspec.yaml',
      '.dart_tool/build/entrypoint',
      '.dart_tool/flutter_build/dart_plugin_registrant.dart',
      '.dart_tool/test_gates',
      '.dart_tool/test_gates/dart_mutant/pubspec.lock',
      // Of a package inside the package.
      'packages/api/.dart_tool/dart_mutant/work/1/pubspec.yaml',
    ]) {
      test('$path is left out', () {
        expect(skippedInCopy(path), isTrue);
      });
    }

    for (final path in [
      'pubspec.yaml',
      'lib/a.dart',
      'test/a_test.dart',
      // Only at the top.
      'lib/coverage/a.dart',
      'lib/reports/a.dart',
      // What is in a platform directory beside the output of its build.
      'android',
      'android/app/src/main/AndroidManifest.xml',
      'ios/Runner/Info.plist',
      'web/index.html',
      // build is source further down, outside the platform directories.
      'lib/build/a.dart',
      'lib/src/build/builder.dart',
      'packages/api/build/a.dart',
      // Only directly below a .dart_tool.
      'lib/dart_mutant/a.dart',
      'tool/.dart_tool/x/dart_mutant',
      '.dart_tool/package_config.json',
      '.dart_tool/version',
      '.dart_tool/pub/bin/test/test.dart.snapshot',
      '.dart_tool/hooks_runner/a',
      '.dart_tool/native_assets.yaml',
      '.fvm/fvm_config.json',
      '.gitignore',
      'lib/builder.dart',
    ]) {
      test('$path is copied', () {
        expect(skippedInCopy(path), isFalse);
      });
    }
  });

  group('copyObstacle', () {
    const root = '/work/app';
    const pubspec = 'name: app\nenvironment:\n  sdk: ^3.11.0\n';

    String? obstacle({
      String pubspec = pubspec,
      String? packageConfig,
      List<(String, String)>? packages,
    }) => copyObstacle(
      root: root,
      pubspec: pubspec,
      packageConfig: packages == null ? packageConfig : config(packages),
    );

    test('none: the package itself, a package inside it, and packages of '
        'the cache and of an SDK', () {
      expect(
        obstacle(
          packages: [
            ('app', '../'),
            ('api', '../packages/api'),
            ('deep', '../packages/a/../b/'),
            ('path', 'file:///home/me/.pub-cache/hosted/pub.dev/path-1.9.0'),
            ('flutter', 'file:///opt/flutter/packages/flutter'),
            // Next to the package, with a name that starts like it.
            ('other', 'file:///work/app2'),
            ('hosted', 'https://example.com/package'),
          ],
        ),
        isNull,
      );
    });

    test('a dependency next to the package is relative to it', () {
      expect(
        obstacle(packages: [('app', '../'), ('shared', '../../shared')]),
        'the dependency "shared" is at a path relative to the package '
        '(../../shared)',
      );
    });

    test('a relative path that comes back into the package is inside', () {
      expect(obstacle(packages: [('api', '../../app/packages/api')]), isNull);
    });

    test('a package inside the package as an absolute path would be read '
        'from the package', () {
      expect(
        obstacle(packages: [('app', 'file:///work/app/')]),
        'the package "app" is inside the package and written as an absolute '
        'path in .dart_tool/package_config.json',
      );
      expect(
        obstacle(packages: [('api', 'file:///work/app/packages/api')]),
        contains('the package "api" is inside the package'),
      );
    });

    test('an entry whose rootUri is no URI, or no string, is passed over', () {
      expect(
        obstacle(
          packages: [
            ('broken', 'file://[not-an-address'),
            ('app', '../'),
            ('shared', '../../shared'),
          ],
        ),
        contains('the dependency "shared" is at a path relative'),
      );
      expect(
        obstacle(
          packages: [('broken', 'file://[not-an-address'), ('app', '../')],
        ),
        isNull,
      );
    });

    test('the package configuration can name the package by its path '
        'without symbolic links', () {
      String? linked(String rootUri) => copyObstacle(
        root: '/tmp/app',
        resolvedRoot: '/private/tmp/app',
        pubspec: pubspec,
        packageConfig: config([('api', rootUri)]),
      );
      expect(
        linked('file:///private/tmp/app/packages/api'),
        contains('the package "api" is inside the package'),
      );
      expect(
        linked('file:///tmp/app/packages/api'),
        contains('the package "api" is inside the package'),
      );
      expect(linked('file:///private/tmp/other'), isNull);
    });

    test('a pub workspace: a member and the root', () {
      expect(
        obstacle(
          pubspec: '${pubspec}resolution: workspace\n',
          packages: [('app', '../')],
        ),
        'the package is part of a pub workspace',
      );
      expect(
        obstacle(
          pubspec: 'name: app\r\nworkspace:\r\n  - packages/a\r\n',
          packages: [('app', '../')],
        ),
        'the package is part of a pub workspace',
      );
      // Not a key at the top.
      expect(
        obstacle(
          pubspec: '${pubspec}flutter:\n  workspace: 1\n',
          packages: [('app', '../')],
        ),
        isNull,
      );
    });

    test('no package configuration, or one that cannot be read', () {
      expect(
        obstacle(),
        'the package has no .dart_tool/package_config.json of its own',
      );
      expect(
        obstacle(packageConfig: '{'),
        '.dart_tool/package_config.json is not valid JSON',
      );
      expect(
        obstacle(packageConfig: '[]'),
        '.dart_tool/package_config.json lists no packages',
      );
      expect(
        obstacle(packageConfig: '{"packages": [1, {"name": "a"}]}'),
        isNull,
      );
    });
  });
}
