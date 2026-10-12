@Tags(['process'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mutant/dart_mutant.dart';
import 'package:dart_mutant/src/args.dart';
import 'package:dart_mutant/src/commands/run.dart';
import 'package:test/test.dart';

/// Why `--schemata` was withdrawn in 0.1.1, as a package
/// (test/fixtures/leftover) and what a run has to say about it.
///
/// The tests of the two files leave something behind in their process (the
/// names that were registered, the value of a counter), and the code under
/// test clears it before they look: `setUpAll(clearNames)`, a first test
/// that resets. A mutant that empties the clearing code changes nothing in
/// a process that has just started, where there is nothing to clear, so no
/// run of its own kills it: it survives, and that is the result.
///
/// With the mutants of a file built into one program the tests are run
/// once per mutant in one process. The round of that mutant then starts
/// with what the round before it left, its tests fail, and it is reported
/// as killed. The tests without a mutant pass every time, because the code
/// that clears is at work in them.
///
/// **A way of running several mutants in one start of the test runner may
/// only be offered again when [differences] is empty for this package.**
void main() {
  late Directory dir;

  setUpAll(() {
    dir = Directory(
      Directory.systemTemp
          .createTempSync('dart_mutant_leftover_')
          .resolveSymbolicLinksSync(),
    );
    void write(String path, String content) => File('${dir.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    String fixture(String name) =>
        File('test/fixtures/leftover/$name.dart.txt').readAsStringSync();

    write('pubspec.yaml', '''
name: leftover_fixture
publish_to: none
environment:
  sdk: ^3.11.0
dev_dependencies:
  test: ^1.27.0
''');
    for (final name in ['registry', 'counter']) {
      write('lib/$name.dart', fixture(name));
      write('test/${name}_test.dart', fixture('${name}_test'));
    }
    // The packages are in the cache: this package depends on `test` too.
    final pubGet = Process.runSync(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: dir.path);
    expect(pubGet.exitCode, 0, reason: '${pubGet.stdout}${pubGet.stderr}');
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  /// The mutants of [targets] as `file line:column Mutator replacement`,
  /// each with its status, and the exit code of the run.
  Future<({Map<String, String> statuses, int exitCode})> mutate({
    required bool builtIn,
    List<String> targets = const ['lib/registry.dart', 'lib/counter.dart'],
  }) async {
    final lines = <String>[];
    final exitCode = await runMutation(
      RunArgs(
        dir: dir.path,
        targets: targets,
        force: true,
        jobs: 2,
        schemata: builtIn,
        command: [Platform.resolvedExecutable, 'test'],
      ),
      Io(out: lines.add, err: lines.add),
    );
    final files =
        (jsonDecode(
                  File(
                    '${dir.path}/reports/mutation/mutation.json',
                  ).readAsStringSync(),
                )
                as Map<String, Object?>)['files']!
            as Map<String, Object?>;
    return (
      statuses: {
        for (final MapEntry(key: path, value: file) in files.entries)
          for (final mutant
              in ((file! as Map<String, Object?>)['mutants']! as List)
                  .cast<Map<String, Object?>>())
            () {
              final start =
                  (mutant['location']! as Map<String, Object?>)['start']!
                      as Map<String, Object?>;
              return '$path ${start['line']}:${start['column']} '
                  '${mutant['mutatorName']} ${mutant['replacement']}';
            }(): mutant['status']! as String,
      },
      exitCode: exitCode,
    );
  }

  /// The mutants that [other] gives another status than [usual], as
  /// `mutant: status of usual, status of other`.
  List<String> differences(
    Map<String, String> usual,
    Map<String, String> other,
  ) {
    expect(other.keys, usual.keys);
    return [
      for (final MapEntry(key: mutant, value: status) in usual.entries)
        if (other[mutant] != status) '$mutant: $status, ${other[mutant]}',
    ];
  }

  test('a run of its own for every mutant: the mutants that empty the '
      'clearing code survive, and the run fails', () async {
    final run = await mutate(builtIn: false);
    expect(run.exitCode, 1);
    expect(run.statuses, {
      'lib/registry.dart 4:19 BlockStatement {}': 'Survived',
      'lib/registry.dart 8:28 BlockStatement {}': 'Killed',
      'lib/counter.dart 4:16 BlockStatement {}': 'Survived',
      'lib/counter.dart 9:11 AssignmentOperator -=': 'Killed',
      // The counter is reset before it is looked at.
      'lib/counter.dart 2:15 NumberLiteral 1': 'Survived',
      'lib/counter.dart 5:13 NumberLiteral 1': 'Killed',
      'lib/counter.dart 9:14 NumberLiteral 2': 'Killed',
      'lib/counter.dart 9:14 NumberLiteral 0': 'Killed',
    });
  });

  test('the mutants built into one program, as --schemata of 0.1.0 ran '
      'them: the same mutants are reported as killed, which is why the '
      'option is refused', () async {
    final usual = await mutate(builtIn: false);
    final builtIn = await mutate(builtIn: true);
    // What has to be empty before such a way of running is offered again.
    expect(differences(usual.statuses, builtIn.statuses), [
      'lib/registry.dart 4:19 BlockStatement {}: Survived, Killed',
      'lib/counter.dart 4:16 BlockStatement {}: Survived, Killed',
    ]);
  });

  test('on the registry alone that was a run without a survivor, and exit '
      'code 0, where a run of its own for every mutant ends with 1', () async {
    const registry = ['lib/registry.dart'];
    final usual = await mutate(builtIn: false, targets: registry);
    expect(usual.exitCode, 1);
    expect(usual.statuses.values, ['Survived', 'Killed']);
    final builtIn = await mutate(builtIn: true, targets: registry);
    expect(builtIn.exitCode, 0);
    expect(builtIn.statuses.values, ['Killed', 'Killed']);
  });

  test('the command line does not get there: --schemata is wrong usage, and '
      'nothing is run', () async {
    final report = File('${dir.path}/reports/mutation/mutation.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"files": {}}');
    final err = <String>[];
    final out = <String>[];
    expect(
      await run([
        'run',
        '--dir',
        dir.path,
        '--force',
        '--schemata',
        'lib/registry.dart',
      ], Io(out: out.add, err: err.add)),
      2,
    );
    expect(err.first, 'dart_mutant: $schemataWithdrawn\n');
    expect(out, isEmpty);
    // Not even the report of the last run is removed.
    expect(report.readAsStringSync(), '{"files": {}}');
    expect(Directory('${dir.path}/$stateDir/work').existsSync(), isFalse);
  });
}
