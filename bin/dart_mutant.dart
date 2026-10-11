import 'dart:io';

import 'package:dart_mutant/dart_mutant.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await run(arguments, Io(out: stdout.writeln, err: stderr.writeln));
}
