import 'dart:io';

import 'args.dart';
import 'commands/merge.dart';
import 'commands/run.dart';
import 'output.dart';
import 'plan.dart';
import 'version.dart';

/// Runs the command line and returns the exit code: 0 when no mutant
/// survived, 1 when one did or something could not be run, 2 for wrong
/// usage or a plan file that cannot be used, 130 / 143 / 129 when
/// interrupted.
Future<int> run(List<String> arguments, Io io) async {
  try {
    switch (parseArgs(arguments)) {
      case HelpArgs():
        io.out(help);
        return 0;
      case VersionArgs():
        io.out(packageVersion);
        return 0;
      case RunCommandArgs(run: final args):
        return await runMutation(args, io);
      case MergeCommandArgs(merge: final args):
        return runMerge(args, io);
    }
  } on UsageError catch (error) {
    io.err('$executable: ${error.message}\n');
    io.err(help);
    return 2;
  } on PlanError catch (error) {
    // Not the command line: the help would not say what is wrong.
    io.err('$executable: ${error.message}');
    return 2;
  } on FileSystemException catch (error) {
    // A report or a state file that cannot be deleted, read or written. The
    // mutated files have been put back by then.
    io.err(
      '$executable: ${error.osError?.message ?? error.message}'
      '${error.path == null ? '' : ' (${error.path})'}',
    );
    return 1;
  }
}
