import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../args.dart';
import '../io/files.dart';
import '../io/report_files.dart';
import '../merge.dart';
import '../mutation_run.dart';
import '../output.dart';

/// Puts the reports of the parts of one run with `--shard` together and
/// writes the report of the whole run, as a run without `--shard` writes
/// it. Nothing is run, and no package is needed.
///
/// The report (and the page) that is at the place of the result is removed
/// first, so that a merge that is refused leaves nothing that can be read
/// as its result.
///
/// Returns the exit code: 0 when the parts fit together and no mutant
/// survived, 1 when one did, or when the parts are not all the parts of
/// one run (no report is written then). Throws [UsageError] for wrong
/// usage, before anything is changed.
int runMerge(MergeArgs args, Io io) {
  final parts = <PartFile>[];
  for (final path in args.parts) {
    if (p.equals(p.absolute(path), p.absolute(args.report))) {
      throw UsageError('--report names one of the parts ($path)');
    }
    final String text;
    try {
      text = readText(path);
    } on FileSystemException catch (error) {
      throw UsageError(
        'cannot read the part $path '
        '(${error.osError?.message ?? error.message})',
      );
    }
    Object? content;
    try {
      content = jsonDecode(text);
    } on FormatException {
      // No JSON is no part: said with the other problems.
    }
    parts.add((name: path, content: content));
  }
  final oldReport = checkReportTargets(args.report, args.html);
  if (oldReport != null) {
    File(args.report).deleteSync();
  }
  final html = args.html;
  if (html != null && File(html).existsSync()) {
    File(html).deleteSync();
  }

  final merged = mergeParts(parts);
  if (merged.problems.isNotEmpty) {
    io.err('The parts are not the parts of one run:');
    for (final problem in merged.problems) {
      io.err('  - $problem');
    }
    io.err('$executable: FAILED (nothing was merged)');
    return 1;
  }
  final runs = merged.files;
  final pageProblem = writeReportFiles(args.report, html, buildReport(runs));
  for (final MapEntry(key: path, value: run) in runs.entries) {
    io.out('  $path: ${totalCounts([run])}');
  }
  final survivors = survivorLines(runs);
  if (survivors.isNotEmpty) {
    io.out('Survived:');
    survivors.forEach(io.out);
  }
  if (pageProblem != null) {
    io.err('$executable: $pageProblem');
  }
  final summary =
      '(${parts.length} part(s) merged: ${totalCounts(runs.values)})';
  if (survivors.isEmpty && pageProblem == null) {
    io.out('$executable: OK $summary');
    return 0;
  }
  io.err('$executable: FAILED $summary');
  return 1;
}
