import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../args.dart';
import '../html_report.dart';
import '../json.dart';
import '../mutation_run.dart';
import '../output.dart';
import 'files.dart';

String _reason(FileSystemException error) =>
    error.osError?.message ?? error.message;

/// Checks where a command is about to write its report ([reportPath]) and
/// its page ([htmlPath], when `--html` is given), before anything is run or
/// changed, and returns the report that is at [reportPath] now (`null` when
/// there is none).
///
/// Throws [UsageError] when one of them would replace a file of another
/// kind: `--report` with the path of something else must not cost that
/// file.
String? checkReportTargets(String reportPath, String? htmlPath) {
  final String? oldReport;
  try {
    oldReport = File(reportPath).existsSync() ? readText(reportPath) : null;
  } on FileSystemException catch (error) {
    throw UsageError('cannot read $reportPath (${_reason(error)})');
  }
  if (oldReport != null && !isReport(oldReport)) {
    throw UsageError(
      '$reportPath exists and is not a mutation report. It is not '
      'overwritten; give another --report, or delete the file',
    );
  }
  if (htmlPath != null) {
    if (p.equals(p.absolute(htmlPath), p.absolute(reportPath))) {
      throw UsageError('--html and --report name the same file ($htmlPath)');
    }
    if (FileSystemEntity.isDirectorySync(htmlPath)) {
      throw UsageError('--html $htmlPath is a directory');
    }
    final String? oldHtml;
    try {
      oldHtml = File(htmlPath).existsSync() ? readText(htmlPath) : null;
    } on FileSystemException catch (error) {
      throw UsageError('cannot read $htmlPath (${_reason(error)})');
    }
    if (oldHtml != null && !isHtmlReport(oldHtml)) {
      throw UsageError(
        '$htmlPath exists and is not a report page of $executable. It is '
        'not overwritten; give another --html, or delete the file',
      );
    }
  }
  return oldReport;
}

/// Writes [report] to [path], and as a page with the title [title] to
/// [htmlPath] when `--html` asks for one: the two always say the same.
///
/// Returns why the page could not be written, when it could not: the report
/// is there then, and the command still says what it found.
String? writeReportFiles(
  String path,
  String? htmlPath,
  JsonObject report, {
  String title = 'Mutation report',
}) {
  File(path).parent.createSync(recursive: true);
  File(
    path,
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  if (htmlPath == null) {
    return null;
  }
  try {
    File(htmlPath).parent.createSync(recursive: true);
    File(htmlPath).writeAsStringSync(htmlReport(report, title: title));
    return null;
  } on FileSystemException catch (error) {
    return 'cannot write the page $htmlPath (${_reason(error)}). The report '
        'is in $path';
  }
}
