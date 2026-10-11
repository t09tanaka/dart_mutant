/// Where the command line writes. Injected, so that it can be tested.
class Io {
  /// Writes results with [out] and what is wrong with [err], one call per
  /// line. The command line passes `stdout.writeln` and `stderr.writeln`.
  const Io({required this.out, required this.err});

  /// Receives the lines of the result: the progress, and the summary of a
  /// run without a survivor.
  final void Function(String line) out;

  /// Receives the lines that say what is wrong: wrong usage, the survivors,
  /// a file that could not be mutation tested, the summary of a run that
  /// failed.
  final void Function(String line) err;
}

/// The name users type.
const executable = 'dart_mutant';

/// How many lines of the output of a failed command are shown.
const shownLines = 25;

/// The last lines of what a command printed ([shownLines] of them),
/// indented, for showing why it failed.
String tailOf(String output) => output
    .trimRight()
    .split('\n')
    .reversed
    .take(shownLines)
    .toList()
    .reversed
    .map((line) => '      $line')
    .join('\n');
