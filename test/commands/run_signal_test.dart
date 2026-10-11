// Signals are not delivered to a process on Windows.
@Tags(['process'])
@TestOn('!windows')
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_mutant/dart_mutant.dart';
import 'package:dart_mutant/src/commands/run.dart';
import 'package:test/test.dart';

import '../support/compiled.dart';
import '../support/package_fixture.dart';

// Two mutants: `*` → `/`, `-` → `+`. The stand-in for the test run never
// ends on the first.
const source = 'num a(num x, num y) => x * y - x;\n';
const mutated = 'num a(num x, num y) => x / y - x;\n';
const backup = '$stateDir/backup/lib/a.dart';
const placed = '$stateDir/placed/lib/a.dart';

/// `dart_mutant run` interrupted while the tests run on a mutant, and a
/// second run in the same package.
void main() {
  late PackageFixture package;
  late CompiledCommandLine compiled;
  late List<String> commandLine;

  setUpAll(() {
    compiled = CompiledCommandLine();
    commandLine = compiled.arguments;
  });
  tearDownAll(() => compiled.delete());

  setUp(() {
    package = PackageFixture();
    package.write('lib/a.dart', source);
    package.fakeTest('lib/a.dart', ['hang-if: x / y', 'expect: x * y - x']);
  });

  tearDown(() => package.delete());

  /// Starts the command line and waits until the tests run on the mutant.
  /// Returns the process and the pid of the test run.
  Future<(Process, int)> start() async {
    final process = await Process.start(Platform.resolvedExecutable, [
      ...commandLine,
      'run',
      '--jobs',
      '1',
      'lib/a.dart',
      '--',
      ...package.fake,
    ], workingDirectory: package.path);
    final started = package.file('started');
    while (!started.existsSync() || started.readAsStringSync().isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // The mutant is in place while the tests run.
    expect(package.read('lib/a.dart'), mutated);
    expect(package.read(backup), source);
    expect(package.read(placed), mutated);
    return (process, int.parse(started.readAsStringSync()));
  }

  bool alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

  for (final (signal, code) in [
    (ProcessSignal.sigint, 130),
    (ProcessSignal.sigterm, 143),
    (ProcessSignal.sighup, 129),
  ]) {
    test('$signal: the test run is ended, the file is put back, exit code '
        '$code', () async {
      final (process, child) = await start();
      final stderrText = process.stderr
          .transform(systemEncoding.decoder)
          .join();
      unawaited(process.stdout.drain<void>());

      process.kill(signal);
      expect(await process.exitCode, code);
      expect(
        await stderrText,
        contains('dart_mutant: interrupted. The files were put back'),
      );
      expect(package.read('lib/a.dart'), source);
      expect(package.file(backup).existsSync(), isFalse);
      expect(package.file(placed).existsSync(), isFalse);
      expect(alive(child), isFalse, reason: 'the test run is still there');
      // An interrupted run writes no report.
      expect(
        package.file('reports/mutation/mutation.json').existsSync(),
        isFalse,
      );
    });
  }

  test('SIGKILL: the mutant stays in the file, and the next run takes it '
      'out first', () async {
    final (process, child) = await start();
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    Process.killPid(child, ProcessSignal.sigkill);
    expect(package.read('lib/a.dart'), mutated);
    expect(package.read(backup), source);

    // Nothing hangs this time: the next run goes through.
    package.fakeTest('lib/a.dart', ['expect: x * y - x']);
    final code = await run([
      'run',
      '--jobs',
      '1',
      '--root',
      package.path,
      'lib/a.dart',
      '--',
      ...package.fake,
    ], package.io);
    expect(package.err, [
      'dart_mutant: put back lib/a.dart, which an interrupted run left with '
          'a mutant in it',
    ]);
    expect(code, 0);
    expect(package.read('lib/a.dart'), source);
    expect(package.file(backup).existsSync(), isFalse);
    expect(package.file(placed).existsSync(), isFalse);
  });
  group('with working copies (--jobs 2)', () {
    const work = '$stateDir/work';

    /// Starts the command line with two jobs and waits until the tests hang
    /// on both mutants, each in its copy. Returns the process and the pids
    /// of the test runs.
    Future<(Process, List<int>)> startTwo() async {
      package.fakeTest('lib/a.dart', ['hang-if: x / y', 'hang-if: y + x']);
      final process = await Process.start(Platform.resolvedExecutable, [
        ...commandLine,
        'run',
        '--jobs',
        '2',
        'lib/a.dart',
        '--',
        ...package.sharedFake,
      ], workingDirectory: package.path);
      while (package.sharedHung.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      // The mutants are in the copies, not in the package.
      expect(package.read('lib/a.dart'), source);
      expect(
        {
          for (final copy in ['1', '2']) package.read('$work/$copy/lib/a.dart'),
        },
        {mutated, 'num a(num x, num y) => x * y + x;\n'},
      );
      expect(package.file(backup).existsSync(), isFalse);
      return (process, package.sharedHung.map(int.parse).toList());
    }

    for (final (signal, code) in [
      (ProcessSignal.sigint, 130),
      (ProcessSignal.sigterm, 143),
      (ProcessSignal.sighup, 129),
    ]) {
      test('$signal: the test runs are ended and the copies removed, exit '
          'code $code', () async {
        final (process, children) = await startTwo();
        final stderrText = process.stderr
            .transform(systemEncoding.decoder)
            .join();
        unawaited(process.stdout.drain<void>());

        process.kill(signal);
        expect(await process.exitCode, code);
        expect(
          await stderrText,
          contains(
            'dart_mutant: interrupted. No file of the package was changed',
          ),
        );
        expect(package.read('lib/a.dart'), source);
        expect(Directory('${package.path}/$work').existsSync(), isFalse);
        for (final child in children) {
          expect(alive(child), isFalse, reason: 'a test run is still there');
        }
        expect(
          package.file('reports/mutation/mutation.json').existsSync(),
          isFalse,
        );
      });
    }

    test('SIGKILL: the copies stay, the package is as it was, and the next '
        'run removes them', () async {
      final (process, children) = await startTwo();
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      for (final child in children) {
        Process.killPid(child, ProcessSignal.sigkill);
      }
      expect(package.read('lib/a.dart'), source);
      expect(Directory('${package.path}/$work/2').existsSync(), isTrue);

      // The lock of the killed run is gone with its process.
      package.fakeTest('lib/a.dart', ['expect: x * y - x']);
      final code = await run([
        'run',
        '--root',
        package.path,
        '--jobs',
        '2',
        'lib/a.dart',
        '--',
        ...package.sharedFake,
      ], package.io);
      expect(package.err, isEmpty);
      expect(code, 0);
      expect(Directory('${package.path}/$work').existsSync(), isFalse);
    });
  });

  group('a second run while the first is at work', () {
    Future<int> second(int jobs) => run([
      'run',
      '--root',
      package.path,
      '--jobs',
      '$jobs',
      'lib/a.dart',
      '--',
      ...package.fake,
    ], package.io);

    test('changes nothing: the mutant of the first run stays where it is, '
        'and the first run goes on', () async {
      final (process, child) = await start();
      final stderrText = process.stderr
          .transform(systemEncoding.decoder)
          .join();
      unawaited(process.stdout.drain<void>());
      final runs = package.runs.length;

      for (final jobs in [1, 2]) {
        package.err.clear();
        expect(await second(jobs), 1);
        expect(package.err, [
          matches(
            '^dart_mutant: another dart_mutant run is at work in this '
            'package \\(pid ${process.pid}, started [^)]+\\)\\. Nothing was '
            'run or changed; ',
          ),
        ]);
        expect(package.out, isEmpty);
        // The second run did not take the mutant for a leftover.
        expect(package.read('lib/a.dart'), mutated);
        expect(package.read(backup), source);
        expect(package.read(placed), mutated);
        expect(package.runs, hasLength(runs));
        expect(alive(child), isTrue);
      }

      process.kill(ProcessSignal.sigint);
      expect(await process.exitCode, 130);
      expect(await stderrText, contains('The files were put back'));
      expect(package.read('lib/a.dart'), source);
    });

    test('after the first was killed, the next run has the package to '
        'itself and takes the mutant out', () async {
      final (process, child) = await start();
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      Process.killPid(child, ProcessSignal.sigkill);
      expect(package.read('lib/a.dart'), mutated);

      package.fakeTest('lib/a.dart', ['expect: x * y - x']);
      expect(await second(2), 0);
      expect(package.err, [
        'dart_mutant: put back lib/a.dart, which an interrupted run left '
            'with a mutant in it',
      ]);
      expect(package.read('lib/a.dart'), source);
    });
  });
}
