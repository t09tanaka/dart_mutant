import 'package:dart_mutant/src/commands/built_in.dart';
import 'package:dart_mutant/src/io/analysis.dart';
import 'package:dart_mutant/src/mutant.dart';
import 'package:dart_mutant/src/mutation_run.dart';
import 'package:dart_mutant/src/schemata.dart';
import 'package:dart_mutant/src/syntax_mutators.dart';
import 'package:test/test.dart';

import 'support/package_fixture.dart';

void main() {
  late PackageFixture package;
  late PackageAnalysis analysis;

  setUpAll(() {
    package = PackageFixture();
    analysis = PackageAnalysis.open(package.path);
  });

  tearDownAll(() async {
    await analysis.dispose();
    package.delete();
  });

  /// The mutants of [source] that compile, built into it. Returns what was
  /// built, and for every mutant `Mutator original → replacement`.
  Future<(BuiltIn, List<String>)> build(
    String source, {
    bool Function()? stopped,
  }) async {
    package.write('lib/a.dart', source);
    final mutants = numbered(
      source,
      findSyntaxMutants(source).mutants,
      await analysis.typedMutantsOf('lib/a.dart', source),
    );
    final compiling = <int>[];
    for (final (id, mutant) in mutants.indexed) {
      if (await analysis.compileErrorOf('lib/a.dart', mutant.applyTo(source)) ==
          null) {
        compiling.add(id);
      }
    }
    final built = await buildIn(
      analysis,
      'lib/a.dart',
      source,
      mutants,
      compiling,
      stopped: stopped ?? () => false,
    );
    // What is built is a program.
    expect(await analysis.compileErrorOf('lib/a.dart', built.content), isNull);
    await analysis.release('lib/a.dart');
    String shown(Mutant mutant) =>
        '${mutant.mutator} '
        '${source.substring(mutant.offset, mutant.end)} → '
        '${mutant.replacement}';
    return (built, [for (final mutant in mutants) shown(mutant)]);
  }

  test('a mutant is built in at the expression it changes, when the '
      'program stays the one it was', () async {
    final (built, mutants) = await build(
      'int f(int a, int b) { return a - b; }\n',
    );
    expect(mutants, ['ArithmeticOperator - → +']);
    expect(built.ids, [0]);
    expect(built.left, isEmpty);
    expect(built.reasons, '');
    expect(
      built.content,
      'int f(int a, int b) { return '
      '(\$dartMutantActive == 0 ? (a + b) : (a - b)); }\n'
      '\nint \$dartMutantActive = -1;\n',
    );
  });

  test('a mutant that changes an inferred type is built in around the '
      'statements that see the type', () async {
    final (built, mutants) = await build(
      'Object f(num a, num b) { var c = a * b; return [c]; }\n',
    );
    final id = mutants.indexOf('ArithmeticOperator * → /');
    expect(built.ids, contains(id));
    expect(
      built.content,
      contains(
        '{ if (\$dartMutantActive == $id) '
        '{ { var c = a / b; return [c]; } } else { { var c = ',
      ),
    );
  });

  test('a guard on null is built in where the promotion still holds', () async {
    final (built, mutants) = await build(
      'int f(int? a) { if (a == null) { return 0; } return a + 1; }\n',
    );
    // In place they do not compile, so they are not asked for.
    final refused = mutants.indexOf('EqualityOperator == → !=');
    expect(built.ids, isNot(contains(refused)));
    expect(built.left, isNot(contains(refused)));
    final guard = mutants.indexWhere((m) => m.startsWith('GuardThrows '));
    expect(built.ids, contains(guard));
    expect(built.left, isEmpty);
  });

  test('a constant is left out, with the reason; an initializer that runs '
      'once in an isolate is built in', () async {
    final (built, mutants) = await build('''
const names = ['a'];
final count = names.length + 1;
void g([String a = 'b']) {}
int f(int a) => a + count;
''');
    // `names.length + 1`, which runs once, and its number.
    expect(built.ids, [2, 4, 5, 6]);
    expect(mutants[2], 'ArithmeticOperator + → -');
    expect(built.left, {
      0: constantContext,
      1: constantContext,
      3: changesProgram,
    });
    expect(
      built.reasons,
      '2 in a constant, 1 the program does not compile, or has other '
      'types, with a choice there',
    );
  });

  group('mutants that each compile in the program, but not together', () {
    // Two decisions that each give `x` a value. With a block of the first
    // emptied the second still does, and the other way round; with one of
    // each emptied in the same program, a way to `return x` is left on
    // which `x` has no value. The types are the same everywhere, so each
    // choice alone is taken where it is.
    const either = '''
int either(bool a, bool b) {
  int x;
  if (a) { x = 1; } else { x = 2; }
  if (b) { x = 3; } else { x = 4; }
  return x;
}
''';

    test('the later ones are left out, with the reason, and what is built '
        'is a program', () async {
      final (built, mutants) = await build(either);
      final first = [
        mutants.indexOf('BlockStatement { x = 1; } → {}'),
        mutants.indexOf('BlockStatement { x = 2; } → {}'),
      ];
      final second = [
        mutants.indexOf('BlockStatement { x = 3; } → {}'),
        mutants.indexOf('BlockStatement { x = 4; } → {}'),
      ];
      expect([...first, ...second], everyElement(isNonNegative));
      expect(built.left, {for (final id in second) id: notTogether});
      expect(built.ids, [
        for (var id = 0; id < mutants.length; id++)
          if (!second.contains(id)) id,
      ]);
      expect(
        built.reasons,
        '2 does not compile together with the other mutants',
      );
      for (final id in first) {
        expect(
          built.content,
          contains('if (\$dartMutantActive == $id) { {} }'),
        );
      }
      for (final id in second) {
        expect(built.content, isNot(contains('\$dartMutantActive == $id)')));
      }
    });

    // More than one step of mutants before the two decisions.
    const longer =
        'int sum(int a, int b) =>\n'
        '    a + b - a + b - a + b - a + b - a + b - a + b - a + b - a + b - '
        'a + b - a + b;\n'
        '$either';

    test('they are looked for a few at a time: the mutants in front of '
        'them, which go in together, stay in', () async {
      final (built, mutants) = await build(longer);
      final second = [
        mutants.indexOf('BlockStatement { x = 3; } → {}'),
        mutants.indexOf('BlockStatement { x = 4; } → {}'),
      ];
      expect(second.first, greaterThan(16));
      expect(built.left, {for (final id in second) id: notTogether});
      expect(built.ids, [
        for (var id = 0; id < mutants.length; id++)
          if (!second.contains(id)) id,
      ]);
    });

    test('a run that is stopped while they are looked for builds in what '
        'it has put together by then', () async {
      var asked = 0;
      final (all, mutants) = await build(longer);
      // Asked once per mutant, once before they are put together, and once
      // per step: stopped in front of the second step.
      final (built, _) = await build(
        longer,
        stopped: () => ++asked > mutants.length + 2,
      );
      expect(all.ids, hasLength(mutants.length - 2));
      expect(built.ids, [for (var id = 0; id < 16; id++) id]);
      expect(built.left, isEmpty);
      for (final id in built.ids) {
        expect(built.content, contains('\$dartMutantActive == $id ?'));
      }
      expect(built.content, isNot(contains('\$dartMutantActive == 16 ')));
    });
  });

  test('a run that is stopped builds nothing more', () async {
    var asked = 0;
    final (built, mutants) = await build(
      'int f(int a, int b) => a - b + 1;\n',
      stopped: () => ++asked > 1,
    );
    expect(mutants.length, greaterThan(2));
    expect(built.ids, [0]);
    expect(built.left, isEmpty);
  });

  test('resolved: the syntax tree with its types, and why a content does '
      'not compile', () async {
    const source = 'int f(int a) => a + 1;\n';
    package.write('lib/a.dart', source);
    await analysis.typedMutantsOf('lib/a.dart', source);
    final fine = await analysis.resolved('lib/a.dart', source);
    expect(fine.error, isNull);
    expect(typesOf(fine.unit)[(16, 21)], 'int');
    final broken = await analysis.resolved(
      'lib/a.dart',
      'int f(int a) => a + 1.5;\nint g() => "";\n',
    );
    expect(broken.error, contains("can't be returned"));
    expect(typesOf(broken.unit)[(16, 23)], 'double');
    await analysis.release('lib/a.dart');
  });
}
