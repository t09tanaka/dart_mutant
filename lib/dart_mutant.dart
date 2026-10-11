/// Mutation testing for Dart and Flutter.
///
/// This package is a command-line tool (`dart_mutant`, see the README).
/// The library has one entry: [run], the command line as a function, for a
/// program that wants to start it without a process of its own.
///
/// Everything under `package:dart_mutant/src/` is not part of the API and
/// changes without notice. A program that needs the result reads the report
/// file, whose format (mutation-testing-elements) is stable.
library;

export 'src/cli.dart' show run;
export 'src/output.dart' show Io;
