import 'dart:io';

import 'package:dart_mutant/dart_mutant.dart';
import 'package:dart_mutant/src/args.dart';
import 'package:dart_mutant/src/commands/run.dart';

/// A run of the files given as arguments, in the current directory, with
/// their mutants built into one program: what `--schemata` asked for in
/// 0.1.0. The command line refuses that option since 0.1.1, so the tests
/// that need such a run as a process of its own start this.
Future<void> main(List<String> arguments) async {
  exitCode = await runMutation(
    RunArgs(targets: arguments, force: true, schemata: true),
    Io(out: stdout.writeln, err: stderr.writeln),
  );
}
