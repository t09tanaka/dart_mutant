@Tags(['process'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// tool/self_mutation.dart, as the workflow of the mutation test uses it.
void main() {
  ProcessResult tool(List<String> arguments) => Process.runSync(
    Platform.resolvedExecutable,
    ['tool/self_mutation.dart', ...arguments],
  );

  final gates = [
    for (final gate
        in (jsonDecode(File('test-gates.json').readAsStringSync())
                as Map<String, Object?>)['gates']!
            as List)
      (gate as Map<String, Object?>)['path']! as String,
  ];

  test('--matrix: every gate of test-gates.json is run, whole or in all of '
      'its parts, and no two jobs share an artifact', () {
    final result = tool(['--matrix']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final lines = (result.stdout as String).trim().split('\n');
    // One line: the workflow puts it into an output.
    expect(lines, hasLength(1));
    final jobs =
        ((jsonDecode(lines.single) as Map<String, Object?>)['include']! as List)
            .cast<Map<String, Object?>>();

    final parts = <String, List<String>>{};
    for (final job in jobs) {
      parts
          .putIfAbsent(job['gate']! as String, () => [])
          .add(job['shard']! as String);
    }
    expect(parts.keys, gates);
    for (final MapEntry(key: gate, value: shards) in parts.entries) {
      final count = shards.length;
      expect(shards, [
        for (var index = 1; index <= count; index++) '$index/$count',
      ], reason: gate);
    }
    expect(jobs.map((job) => job['artifact']).toSet(), hasLength(jobs.length));
    expect(jobs.map((job) => job['name']).toSet(), hasLength(jobs.length));
    // A part is an artifact that `--merge` looks for; a whole gate is not.
    for (final job in jobs) {
      expect(
        (job['artifact']! as String).startsWith('mutation-part-'),
        job['shard'] != '1/1',
        reason: '$job',
      );
    }
  });

  test('--shard has to be the division the script knows for the gate', () {
    final whole = gates.firstWhere((gate) => gate.endsWith('/plan.dart'));
    final result = tool(['--gate', whole, '--shard', '1/2']);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('--shard 1/2: $whole is run in 1 part(s)'));
    expect(tool(['--shard', '1/1']).exitCode, 1);
    expect(tool(['--matrix', '--force']).exitCode, 2);
  });

  test('--merge: a directory without the parts fails', () {
    final empty = Directory.systemTemp.createTempSync('dart_mutant_parts_');
    addTearDown(() => empty.deleteSync(recursive: true));
    final result = tool(['--merge', empty.path]);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('self_mutation: no part of '));
  });
}
