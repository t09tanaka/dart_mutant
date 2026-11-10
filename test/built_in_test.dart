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

  group('a private constant is declared final, with constants in it', () {
    test('every choice is a constant, the original too, and the keyword '
        'changes only for a declaration with a mutant in it', () async {
      final (built, mutants) = await build('''
const _m = <String, int>{'a': 1, 'b': 2};
const _none = <String>{};
int f(String k) => _m[k] ?? 0;
''');
      expect(built.constants, isNotEmpty);
      expect(mutants.length, greaterThan(built.constants.length));
      final content = built.content;
      expect(content, startsWith('final _m = ('));
      // The program with no mutant at work has the very same constant.
      expect(
        content,
        contains(
          " : (const <String, int>{'a': 1, 'b': 2}));\n"
          'const _none = <String>{};',
        ),
      );
      expect(content, contains('? (const <String, int>{'));
    });

    test('an initializer that says const itself gets no second one, and a '
        'static field is one too', () async {
      final (built, _) = await build('''
class A {
  static const _l = const [1, 2];
  static int get first => _l.first;
}
''');
      expect(built.constants, isNotEmpty);
      expect(built.content, startsWith('class A {\n  static final _l = ('));
      expect(built.content, isNot(contains('const const')));
      expect(built.content, contains(' : (const [1, 2]));'));
    });

    test('what is not eligible stays in a constant', () async {
      final (built, mutants) = await build('''
const pub = <int>[1, 2];
const _one = 1 + 2, _two = [3];
const _text = 'a\${1 + 1}';
int f() {
  const local = <int>[4];
  return local.first + pub.first + _one + _two.first + _text.length;
}
''');
      expect(built.constants, isEmpty);
      for (final id in built.left.keys) {
        expect(built.left[id], constantContext, reason: mutants[id]);
      }
      expect(built.left, isNotEmpty);
      expect(built.content, isNot(contains('final _')));
    });

    test('a constant that other code of the library needs as a constant is '
        'left in a constant, with that reason', () async {
      final (built, mutants) = await build('''
const _list = <int>[7, 8];
const _copy = _list;
void g([List<int> a = _list]) {}
class K {
  const K(this.v);
  final List<int> v;
}
const _k = K(_list);
int use(int x) {
  switch (x) {
    case _list.length:
      return 1;
    default:
      return 0;
  }
}
''');
      final ids = [
        for (final (id, text) in mutants.indexed)
          if (text.endsWith('→ 8') || text.endsWith('→ 6')) id,
      ];
      expect(ids, isNotEmpty);
      for (final id in ids) {
        expect(built.ids, isNot(contains(id)), reason: mutants[id]);
        expect(built.left[id], constantContext, reason: mutants[id]);
      }
      expect(built.constants, isEmpty);
    });

    test('a library with a part directive is not eligible', () async {
      package.write('lib/p.dart', "part of 'a.dart';\n");
      final (built, _) = await build('''
part 'p.dart';
const _m = <int>[1, 2];
int f() => _m.first;
''');
      expect(built.constants, isEmpty);
      expect(built.left, isNotEmpty);
      expect(built.left.values, everyElement(constantContext));
    });

    test('two mutants in one initializer are two choices of one '
        'declaration', () async {
      final (built, _) = await build('''
const _m = <int>[1, 2];
int f() => _m.first + _m.last;
''');
      expect(built.constants, hasLength(greaterThanOrEqualTo(2)));
      expect(RegExp('final _m = ').allMatches(built.content), hasLength(1));
      expect(
        RegExp(
          r'\$dartMutantActive == \d+ \? \(const <int>\[',
        ).allMatches(built.content),
        hasLength(built.constants.length),
      );
      expect(built.content, contains(': (const <int>[1, 2]))'));
    });

    test('without the constants the rest is built in as before', () async {
      final (built, _) = await build('''
const _m = <int>[1, 2];
int f(int a) => a + _m.first;
''');
      final rest = built.withoutConstants();
      expect(rest.constants, isEmpty);
      expect(rest.content, isNot(contains('final _m')));
      expect(rest.content, contains('const _m = <int>[1, 2];'));
      expect(rest.ids, isNotEmpty);
      for (final id in built.constants) {
        expect(rest.left[id], constantContext);
        expect(rest.ids, isNot(contains(id)));
      }
    });
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
