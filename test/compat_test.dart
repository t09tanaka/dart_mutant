import 'dart:io';

import 'package:dart_mutant/src/syntax_mutators.dart';
import 'package:test/test.dart';

import 'compat/test_gates_0_1_0_mutators.dart' as v010;

/// `mutator|offset|end|replacement`, one per mutant, in the order found.
List<String> _keys(Iterable<({String m, int o, int e, String r})> mutants) => [
  for (final mutant in mutants)
    '${mutant.m}|${mutant.o}|${mutant.e}|${mutant.r}',
];

List<String> _now(String source) => _keys([
  for (final mutant in findSyntaxMutants(source).mutants)
    (m: mutant.mutator, o: mutant.offset, e: mutant.end, r: mutant.replacement),
]);

List<String> _then(String source) => _keys([
  for (final mutant in v010.findMutants(source).mutants)
    (m: mutant.mutator, o: mutant.offset, e: mutant.end, r: mutant.replacement),
]);

/// The contract with test_gates 0.1.0: for the same source the syntax
/// mutators give the same mutants, with the same names, places, replacements
/// and order. Projects have allowances registered against them.
void main() {
  final sources = <String, String>{
    for (final entity in [
      ...Directory('lib').listSync(recursive: true),
      ...Directory('test').listSync(recursive: true),
      ...Directory('bin').listSync(recursive: true),
    ])
      if (entity is File &&
          (entity.path.endsWith('.dart') || entity.path.endsWith('.dart.txt')))
        entity.path: entity.readAsStringSync(),
  };

  test('the inputs cover every syntax mutator', () {
    final names = {
      for (final source in sources.values)
        for (final mutant in v010.findMutants(source).mutants) mutant.mutator,
    };
    expect(names, {
      'ArithmeticOperator',
      'EqualityOperator',
      'LogicalOperator',
      'ConditionalExpression',
      'BooleanLiteral',
      'UnaryOperator',
      'UpdateOperator',
      'AssignmentOperator',
      'BlockStatement',
      'RemoveCall',
      'StringLiteral',
      'ArrayDeclaration',
    });
    expect(sources.keys, contains('test/fixtures/compat/shapes.dart.txt'));
  });

  for (final MapEntry(key: path, value: source) in sources.entries) {
    test('$path: the same mutants as test_gates 0.1.0', () {
      expect(_now(source), _then(source));
    });
  }

  test('a byte order mark shifts both by one', () {
    const source = '﻿int f(int a) => a + 1;\n';
    expect(_now(source), _then(source));
    expect(_now(source), ['ArithmeticOperator|19|20|-']);
  });

  test('a file that is not Dart has no mutants in either', () {
    expect(findSyntaxMutants('int f( => 1;').syntaxErrors, isTrue);
    expect(v010.findMutants('int f( => 1;').syntaxErrors, isTrue);
  });

  test('the fixture has mutants of its own', () {
    final source = sources['test/fixtures/compat/shapes.dart.txt']!;
    expect(v010.findMutants(source).syntaxErrors, isFalse);
    expect(_then(source).length, greaterThan(60));
  });
}
