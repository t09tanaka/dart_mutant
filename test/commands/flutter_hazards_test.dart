@Tags(['process', 'flutter'])
@Timeout(Duration(minutes: 30))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mutant/dart_mutant.dart';
import 'package:dart_mutant/src/args.dart';
import 'package:dart_mutant/src/commands/run.dart';
import 'package:test/test.dart';

/// The condition under which the mutants of a Flutter package may be run
/// in another way than by a start of `flutter test` each: for a Flutter
/// package of tests that are easy to get wrong
/// (test/fixtures/flutter_hazards), **every mutant has the status that a
/// start of the test runner of its own gives it** (`--one-by-one`).
///
/// By default the mutants of a file are built into it, every mutant gets a
/// test file of its own that puts it to work and calls the tests, and one
/// start of `flutter test` runs these files one after the other, each in
/// the process `flutter test` gives every test file. That start has no
/// `--fail-fast`: a test file of which a test failed is run to its end.
///
/// This test needs `flutter` on the PATH, and is skipped without it.
///
/// The files, and what each is there for:
///
/// - `measure`: nothing special, but a `main` of its test file that is
///   `async`, and a test that writes what looks like a failure in a report
///   of the test runner to the standard output.
/// - `shelf`: **what the start without `--fail-fast` leaves in the
///   package.** A test leaves a file when it fails, with mutants that have
///   failed a test before it: a start with `--fail-fast` never gets there.
///   Two other mutants pass as long as that file is not there. Run after a
///   mutant that left it, they would be killed by mistake: a test file of a
///   mutant that finds something in the working copy that was not there at
///   first is not run, and the mutant gets a start of its own, in a working
///   copy that was made again.
/// - `gate`: a `setUpAll` that fails with a mutant.
/// - `outside`: what fails outside the body of a test, each by a mutant of
///   its own: while the tests are declared, in a `tearDownAll`, in a
///   future nobody waits for, when the test has ended, and a callback that
///   is never called (the test waits until its time is up).
/// - `steps`: a mutant that never ends, in a loop that gives nothing else
///   a turn: no time limit of a test ends it, the start is ended, and the
///   mutants after it are started again.
/// - `diag`: a test that prints the form of a compiler error when it
///   fails, which a start of the test runner is read as a mutant that does
///   not compile. A failure with such output is not believed.
/// - `priced`: tests that only pass when `flutter test` starts them through
///   the `flutter_test_config.dart` of their directory.
/// - `label`: a widget, and tests with `testWidgets`.
/// - `background`: code that runs in another isolate (`compute`), where no
///   mutant is at work.
/// - `pair`: a file with two test files, which a start of `flutter test`
///   runs at the same time.
/// - `slow`: a test file with an annotation on its library.
typedef _Run = ({
  Map<String, List<String>> mutants,
  int exitCode,
  List<String> lines,
  Duration took,
});

/// Where the test of a file is, when it is not `test/<name>_test.dart`.
const _tests = {
  'pair': ['test/pair_first_test.dart', 'test/pair_second_test.dart'],
  'priced': ['test/priced/priced_test.dart'],
};

const _all = [
  'measure',
  'shelf',
  'gate',
  'outside',
  'steps',
  'diag',
  'priced',
  'label',
  'background',
  'pair',
  'slow',
];

/// The files of this run: all of them, or those `FLUTTER_HAZARDS_ONLY`
/// names (`shelf,steps`), to look at one of them while working on it.
final _files = [
  for (final name in _all)
    if (Platform.environment['FLUTTER_HAZARDS_ONLY']
            ?.split(',')
            .contains(name) ??
        true)
      name,
];

void main() {
  final found = _flutter();
  if (found == null) {
    test(
      'the mutants of a Flutter package',
      () {},
      skip: 'flutter is not on the PATH: this test starts `flutter test`',
    );
    return;
  }

  late Directory dir;
  late _Run usual;
  late _Run together;

  /// How many test runs each of the two runs starts at a time: 2, or what
  /// `HAZARDS_JOBS` says.
  final jobs = Platform.environment['HAZARDS_JOBS'] ?? '2';

  /// How the mutants of each file that are built in have to go: how many
  /// there are, how many of them are killed in the one start for all of
  /// them, and how many are left for a start of their own, as the run says
  /// it. A file that is given up has no such line, and says why.
  ///
  /// `shelf` is not in it: how many of its mutants are run depends on which
  /// of them come after one that left a file, in which working copy.
  const shared = <String, String>{
    'measure': '26 of 26 built in, 23 killed there, 3 left',
    // Its setUpAll fails with two of them: no test of them failed.
    'gate': '4 of 5 built in, 2 killed there, 2 left',
    // Killed there: the error nobody waits for. Left: what fails while the
    // tests are declared, in the tearDownAll and when its test has ended,
    // and the callback that is never called.
    'outside': '10 of 10 built in, 2 killed there, 8 left',
    // Left: the one that never ends.
    'steps': '7 of 7 built in, 6 killed there, 1 left',
    // Every failure of it is printed in the form of a compiler error.
    'diag': '4 of 4 built in, 0 killed there, 4 left',
    'priced': '10 of 11 built in, 10 killed there, 0 left',
    'label': '14 of 14 built in, 14 killed there, 0 left',
  };

  const givenUp = <String, String>{
    'background':
        'dart_mutant run: lib/background.dart: code of the file ran in '
        'another isolate or process than the tests, where no mutant is at '
        'work; each of its mutants gets a start of the test runner of its own',
    'pair':
        'dart_mutant run: lib/pair.dart has more than one test file, which a '
        'start of the test runner runs at the same time; each of its mutants '
        'gets a start of the test runner of its own',
    'slow':
        'dart_mutant run: lib/slow.dart has a test (test/slow_test.dart) '
        'that has an annotation on its library '
        '(@Timeout(Duration(seconds: 20))); each of its mutants gets a start '
        'of the test runner of its own',
  };

  /// The mutants that the start for many mutants would kill by mistake,
  /// each for the reason its file is there for.
  const survivors = <String>[
    // Count what is half unpacked: they pass while no test that failed
    // after another left a parcel on the shelf.
    'lib/shelf.dart#8 ConditionalExpression false 21:9-21:38',
    'lib/shelf.dart#10 BlockStatement {} 21:40-23:6',
    'lib/shelf.dart#? MethodExpression startsWith 21:21-21:29',
  ];

  Future<_Run> mutate({required bool oneByOne}) async {
    final lines = <String>[];
    final parsed = parseArgs([
      'run',
      '--dir',
      dir.path,
      '--plan',
      '${dir.path}/plan.json',
      '--force',
      '--jobs',
      jobs,
      if (oneByOne) '--one-by-one',
    ]);
    final watch = Stopwatch()..start();
    final exitCode = await runMutation(
      (parsed as RunCommandArgs).run,
      Io(out: lines.add, err: lines.add),
      // Every file goes the way that is compared, however few mutants it
      // has.
      buildInFrom: 0,
    );
    final report =
        (jsonDecode(
                  File(
                    '${dir.path}/reports/mutation/mutation.json',
                  ).readAsStringSync(),
                )
                as Map<String, Object?>)['files']!
            as Map<String, Object?>;
    String place(Object? location) {
      final at = location! as Map<String, Object?>;
      final start = at['start']! as Map<String, Object?>;
      final end = at['end']! as Map<String, Object?>;
      return '${start['line']}:${start['column']}-'
          '${end['line']}:${end['column']}';
    }

    return (
      mutants: {
        for (final MapEntry(key: path, value: file) in report.entries)
          path: [
            for (final mutant
                in ((file! as Map<String, Object?>)['mutants']! as List)
                    .cast<Map<String, Object?>>())
              '${mutant['id']} ${mutant['mutatorName']} '
                  '${mutant['replacement']} ${place(mutant['location'])}: '
                  '${mutant['status']}',
          ],
      },
      exitCode: exitCode,
      lines: lines,
      took: watch.elapsed,
    );
  }

  setUpAll(() async {
    dir = Directory(
      Directory.systemTemp
          .createTempSync('dart_mutant_flutter_hazards_')
          .resolveSymbolicLinksSync(),
    );
    void write(String path, String content) => File('${dir.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    String fixture(String name) =>
        File('test/fixtures/flutter_hazards/$name.dart.txt').readAsStringSync();

    write('pubspec.yaml', '''
name: flutter_hazards
publish_to: none
environment:
  sdk: ^3.8.0
dependencies:
  flutter:
    sdk: flutter
dev_dependencies:
  flutter_test:
    sdk: flutter
''');
    write('lib/settings.dart', fixture('settings'));
    write('test/priced/flutter_test_config.dart', fixture('priced_config'));
    final targets = <Map<String, Object?>>[];
    for (final name in _files) {
      write('lib/$name.dart', fixture(name));
      final tests = _tests[name] ?? ['test/${name}_test.dart'];
      for (final test in tests) {
        write(test, fixture(test.split('/').last.replaceAll('.dart', '')));
      }
      targets.add({'file': 'lib/$name.dart', 'tests': tests});
    }
    write('plan.json', jsonEncode({'version': 1, 'targets': targets}));
    // The packages of the Flutter SDK are in it; the others are in the
    // cache once they have been fetched.
    var pubGet = Process.runSync(found, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: dir.path);
    if (pubGet.exitCode != 0) {
      pubGet = Process.runSync(found, [
        'pub',
        'get',
      ], workingDirectory: dir.path);
    }
    expect(pubGet.exitCode, 0, reason: '${pubGet.stdout}${pubGet.stderr}');

    usual = await mutate(oneByOne: true);
    together = await mutate(oneByOne: false);
    // How long each of the two runs took.
    // ignore: avoid_print
    print(
      'flutter_hazards, --jobs $jobs: '
      '${[for (final mutants in usual.mutants.values) ...mutants].length} '
      'mutants, ${usual.took.inSeconds}s with --one-by-one, '
      '${together.took.inSeconds}s by default',
    );
    // And what they printed, when `FLUTTER_HAZARDS_LINES` is set.
    if (Platform.environment['FLUTTER_HAZARDS_LINES'] != null) {
      // ignore: avoid_print
      print([...usual.lines, ...together.lines].join('\n'));
    }
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  test('every file of the package is in both reports, and the run with a '
      'start per mutant builds nothing in', () {
    final paths = [for (final name in _files) 'lib/$name.dart'];
    expect(usual.mutants.keys, paths);
    expect(together.mutants.keys, paths);
    expect(usual.lines.where((line) => line.contains('built in')), isEmpty);
    expect(
      {...shared.keys, ...givenUp.keys, 'shelf'}.containsAll(_files),
      isTrue,
    );
  });

  for (final name in _files) {
    test('lib/$name.dart: every mutant has the id, the mutator, the '
        'replacement, the place and the status that a start of the test '
        'runner of its own gives it', () {
      final own = usual.mutants['lib/$name.dart']!;
      expect(own, isNotEmpty);
      expect(together.mutants['lib/$name.dart'], own);
    });
  }

  test('and so the two runs end with the same exit code', () {
    expect(usual.exitCode, 1);
    expect(together.exitCode, 1);
  });

  test('the mutants that the one start for many would kill by mistake '
      'survive a start of the test runner of their own', () {
    final all = [for (final mutants in usual.mutants.values) ...mutants];
    for (final survivor in survivors) {
      if (!_files.contains(survivor.split('/').last.split('.').first)) {
        continue;
      }
      final pattern = RegExp(
        '^${RegExp.escape(survivor).replaceFirst(r'#\?', r'#\d+')}: Survived\$',
      );
      expect(
        all.where(pattern.hasMatch),
        hasLength(1),
        reason: '$survivor\n${all.join('\n')}',
      );
    }
  });

  test('how the mutants that were built in went: how many there were, how '
      'many were killed in the start for all of them, and how many were '
      'left for a start of their own', () {
    final went = <String, String>{};
    for (final name in _files) {
      final builtIn = RegExp(
        '^  lib/$name\\.dart: (\\d+) of (\\d+) mutant\\(s\\) built in,',
      );
      final killed = RegExp(
        '^  lib/$name\\.dart: (\\d+) killed with the mutants built in'
        '(?:; (\\d+) cannot be built in \\([^)]*\\))?'
        '(?:; (\\d+) not killed that way get a start of their own)?(?:;|\$)',
      );
      final first = together.lines.map(builtIn.firstMatch).nonNulls;
      final second = together.lines.map(killed.firstMatch).nonNulls;
      if (first.isNotEmpty && second.isNotEmpty) {
        went[name] =
            '${first.single.group(1)} of ${first.single.group(2)} built in, '
            '${second.single.group(1)} killed there, '
            '${second.single.group(3) ?? 0} left';
      }
    }
    went.remove('shelf');
    expect(went, {
      for (final MapEntry(key: name, value: line) in shared.entries)
        if (_files.contains(name)) name: line,
    }, reason: together.lines.join('\n'));
  });

  test('lib/shelf.dart: the mutants that come after one whose tests left a '
      'file in the working copy are not run there, and the run says so', () {
    expect(
      together.lines.where(
        (line) =>
            line.startsWith('  lib/shelf.dart: ') &&
            RegExp(
              r'; \d+ of them were not run for a file the tests before them '
              r'left or changed in the working copy$',
            ).hasMatch(line),
      ),
      hasLength(_files.contains('shelf') ? 1 : 0),
      reason: together.lines.join('\n'),
    );
  });

  test('the files that cannot be judged that way are given up, and say '
      'why; no other file is', () {
    final given = {
      for (final MapEntry(key: name, value: line) in givenUp.entries)
        if (_files.contains(name)) name: line,
    };
    for (final MapEntry(key: name, value: line) in given.entries) {
      expect(together.lines, contains(line), reason: name);
    }
    expect(
      together.lines.where(
        (line) => line.contains('each of its mutants gets a start'),
      ),
      hasLength(given.length),
      reason: together.lines.join('\n'),
    );
  });

  test('nothing of the run is left in the package', () {
    expect(
      Directory('${dir.path}/.dart_tool/dart_mutant/work').existsSync(),
      isFalse,
    );
    expect(
      Directory('${dir.path}/.dart_tool/dart_mutant_flutter').existsSync(),
      isFalse,
    );
    expect(Directory('${dir.path}/shelf').existsSync(), isFalse);
    expect(
      Directory('${dir.path}/test')
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => file.path.substring(dir.path.length + 1))
          .toSet(),
      {
        for (final name in _files)
          ...(_tests[name] ?? ['test/${name}_test.dart']),
        'test/priced/flutter_test_config.dart',
      },
    );
  });
}

/// The `flutter` of the PATH, or `null` when there is none.
String? _flutter() {
  try {
    return Process.runSync('flutter', ['--version']).exitCode == 0
        ? 'flutter'
        : null;
  } on ProcessException {
    return null;
  }
}
