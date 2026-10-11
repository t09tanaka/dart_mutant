import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:dart_mutant/src/io/analysis.dart';
import 'package:dart_mutant/src/mutant.dart';
import 'package:dart_mutant/src/schemata.dart';
import 'package:test/test.dart';

import 'support/package_fixture.dart';

/// The mutant that makes [to] of the first [from] in [source].
Mutant change(String source, String from, String to) {
  final offset = source.indexOf(from);
  return Mutant('M', offset, offset + from.length, to);
}

/// The places of [mutant] in [source], as `kind: node → alternative`, and
/// after them the reason.
List<String> places(String source, Mutant mutant) {
  final found = placesOf(
    parseString(content: source).unit,
    source,
    7,
    mutant,
    parseString(content: mutant.applyTo(source)).unit,
  );
  return [
    for (final wrap in found.wraps)
      '${wrap.statement ? 'statement' : 'expression'}: '
          '${source.substring(wrap.offset, wrap.end)} → ${wrap.alternative}',
    found.reason,
  ];
}

void main() {
  group('fileObstacle', () {
    test('a file like any other has none', () {
      expect(fileObstacle('int a = 1;\n'), isNull);
      expect(fileObstacle("part 'b.dart';\nint a = 1;\n"), isNull);
    });

    test('the name of the variable in a string or a comment is in '
        'nobody\'s way, and a file that cannot be parsed is not asked', () {
      expect(
        fileObstacle('// \$dartMutantActive\nvar a = r"\$dartMutantActive";'),
        isNull,
      );
      expect(fileObstacle('int a = ;'), isNull);
    });

    test('a byte order mark, the name of the variable, a part', () {
      expect(fileObstacle('﻿int a = 1;\n'), 'starts with a byte order mark');
      expect(
        fileObstacle('int \$dartMutantActive = 1;\n'),
        'has the name \$dartMutantActive in it',
      );
      expect(
        fileObstacle('int f() => g(1, \$dartMutantActive);'),
        'has the name \$dartMutantActive in it',
      );
      expect(
        fileObstacle("part of 'a.dart';\nint a = 1;\n"),
        'is a part of a library',
      );
    });
  });

  test('the reasons, and the longest alternative', () {
    expect(runsOnce, 'in an initializer that runs once in a process');
    expect(constantContext, 'in a constant');
    expect(noPlace, 'no expression or statement around it can take it');
    expect(longestAlternative, 4000);
  });

  group('placesOf', () {
    test('an operator: the expressions around it, the smallest first', () {
      const source = 'int f(int a, int b) => a + b * 2;';
      expect(places(source, change(source, '*', '/')), [
        'expression: b * 2 → b / 2',
        'expression: a + b * 2 → a + b / 2',
        noPlace,
      ]);
    });

    test('the number of the mutant is kept', () {
      const source = 'int f(int a) => -a;';
      final mutant = change(source, '-a', 'a');
      final wrap = placesOf(
        parseString(content: source).unit,
        source,
        7,
        mutant,
        parseString(content: mutant.applyTo(source)).unit,
      ).wraps.single;
      expect(wrap.id, 7);
      expect((wrap.offset, wrap.end), (16, 18));
    });

    test('a node that is no node with the mutant in it is passed over', () {
      // `a || b || c` is `(a || b) || c`: there is no `b || c` in it.
      const source = 'bool f(bool a, bool b, bool c) => a || b && c;';
      expect(places(source, change(source, '&&', '||')), [
        'expression: a || b && c → a || b || c',
        noPlace,
      ]);
    });

    test('a name is no value: the member, the method, the prefixed name, '
        'the label', () {
      const member = 'int f(List<int> a) => (a).first;';
      expect(places(member, change(member, 'first', 'last')), [
        'expression: (a).first → (a).last',
        noPlace,
      ]);
      const method = 'int f(List<int> a) => a.indexOf(1);';
      expect(places(method, change(method, 'indexOf', 'lastIndexOf')), [
        'expression: a.indexOf(1) → a.lastIndexOf(1)',
        noPlace,
      ]);
      const prefixed = 'int f(List<int> a) => a.first;';
      expect(places(prefixed, change(prefixed, 'first', 'last')), [
        'expression: a.first → a.last',
        noPlace,
      ]);
      const label = 'int f() => g(b: 1);';
      expect(places(label, change(label, 'b', 'c')), [
        'expression: g(b: 1) → g(c: 1)',
        noPlace,
      ]);
    });

    test('a name that is a value is one', () {
      const source = 'int f(int a, int b) => g(a);';
      expect(places(source, change(source, '(a)', '(b)')), [
        'expression: g(a) → g(b)',
        noPlace,
      ]);
      const argument = 'int f(int a, int b) => g(a);';
      expect(places(argument, Mutant('M', 25, 26, 'b')), [
        'expression: a → b',
        'expression: g(a) → g(b)',
        noPlace,
      ]);
      // `a` of `a.isEven` is a name with a parent that is none of those.
      const target = 'bool f(int a, int b) => [a][0].isEven;';
      expect(
        places(target, Mutant('M', 25, 26, 'b')).first,
        'expression: a → b',
      );
    });

    test('a statement, and the statements around it', () {
      const source = 'void f() { if (a) { g(); h(); } }';
      expect(places(source, change(source, 'g();', ';')), [
        'statement: g(); → ;',
        'statement: { g(); h(); } → { ; h(); }',
        'statement: if (a) { g(); h(); } → if (a) { ; h(); }',
        'statement: { if (a) { g(); h(); } } → { if (a) { ; h(); } }',
        noPlace,
      ]);
    });

    test('what is added behind a statement belongs to the statement that '
        'ends with it', () {
      const source = 'void f() { if (a) return; g(); }';
      final at = source.indexOf(' g()');
      expect(places(source, Mutant('M', at, at, ' else if (b) return;')), [
        'statement: if (a) return; → if (a) return; else if (b) return;',
        'statement: { if (a) return; g(); } → '
            '{ if (a) return; else if (b) return; g(); }',
        noPlace,
      ]);
    });

    test('a statement that declares a name is not wrapped', () {
      const source =
          'void f() { final x = 1 + 2; int g() => 3; '
          'var (a, b) = (4, 5); }';
      expect(places(source, change(source, '+', '-')), [
        'expression: 1 + 2 → 1 - 2',
        startsWith('statement: { final x = 1 + 2;'),
        noPlace,
      ]);
      expect(places(source, change(source, '3', '4')), [
        'expression: 3 → 4',
        startsWith('statement: { final x = 1 + 2;'),
        noPlace,
      ]);
      expect(places(source, change(source, '5', '6')), [
        'expression: 5 → 6',
        'expression: (4, 5) → (4, 6)',
        startsWith('statement: { final x = 1 + 2;'),
        noPlace,
      ]);
    });

    test('the initializer of a top-level variable and of a static field '
        'runs once', () {
      const top = 'final x = 1 + 2;';
      expect(places(top, change(top, '+', '-')), [runsOnce]);
      const field = 'class A { static final x = 1 + 2; }';
      expect(places(field, change(field, '+', '-')), [runsOnce]);
    });

    test('what is in no function and in no variable does not run once', () {
      // The default of a parameter. That it has to be a constant is for
      // the analyzer to say.
      const source = 'void f([int a = 1 + 2]) {}';
      expect(places(source, change(source, '+', '-')), [
        'expression: 1 + 2 → 1 - 2',
        noPlace,
      ]);
    });

    test('the initializer of a field of an object runs for each', () {
      const source = 'class A { final x = 1 + 2; }';
      expect(places(source, change(source, '+', '-')), [
        'expression: 1 + 2 → 1 - 2',
        noPlace,
      ]);
    });

    test('a function in such an initializer runs when it is called; the '
        'function itself is made once', () {
      const source = 'final f = () { return 1 + 2; };';
      expect(places(source, change(source, '+', '-')), [
        'expression: 1 + 2 → 1 - 2',
        'statement: return 1 + 2; → return 1 - 2;',
        'statement: { return 1 + 2; } → { return 1 - 2; }',
        runsOnce,
      ]);
      // A function with a name is no value, wherever it is declared.
      const local = 'void f() { int g() => 1 + 2; }';
      expect(places(local, change(local, '+', '-')), [
        'expression: 1 + 2 → 1 - 2',
        'statement: { int g() => 1 + 2; } → { int g() => 1 - 2; }',
        noPlace,
      ]);
    });

    test('a constant is passed over, and what is around it can be a place', () {
      const source = 'List<int> f() { return const [1 + 2]; }';
      expect(places(source, change(source, '+', '-')), [
        'expression: const [1 + 2] → const [1 - 2]',
        'statement: return const [1 + 2]; → return const [1 - 2];',
        'statement: { return const [1 + 2]; } → { return const [1 - 2]; }',
        constantContext,
      ]);
    });

    test('what is longer than the longest alternative ends the search', () {
      final filler = 'g(); ' * (longestAlternative ~/ 5);
      final source = 'void f() { if (a) { h(1 + 2); } $filler }';
      expect(places(source, change(source, '+', '-')), [
        'expression: 1 + 2 → 1 - 2',
        'expression: h(1 + 2) → h(1 - 2)',
        'statement: h(1 + 2); → h(1 - 2);',
        'statement: { h(1 + 2); } → { h(1 - 2); }',
        'statement: if (a) { h(1 + 2); } → if (a) { h(1 - 2); }',
        noPlace,
      ]);
    });

    test('the longest alternative itself is a place', () {
      String body(int length) => '{ h(1 + 2); ${';' * (length - 13)}}';
      final exact = 'void f() ${body(longestAlternative)}';
      expect(exact.length - 9, longestAlternative);
      expect(places(exact, change(exact, '+', '-')), hasLength(5));
      final longer = 'void f() ${body(longestAlternative + 1)}';
      expect(places(longer, change(longer, '+', '-')), hasLength(4));
      // What counts is the length with the mutant in it.
      expect(places(exact, change(exact, '+', '- 0 -')), hasLength(4));
    });
  });

  group('embed', () {
    const source = 'int f(int a) { g(); return a + 1; }';

    test('an expression becomes a choice of expressions', () {
      expect(
        embed(source, [const Wrap(3, 27, 32, 'a - 1', statement: false)]),
        'int f(int a) { g(); return '
        '(\$dartMutantActive == 3 ? (a - 1) : (a + 1)); }'
        '\nint \$dartMutantActive = -1;\n',
      );
    });

    test('a statement becomes a choice of statements, in a block', () {
      expect(
        embed(source, [
          const Wrap(4, 15, 19, ';', statement: true),
        ], declared: false),
        'int f(int a) { { if (\$dartMutantActive == 4) { ; } else '
        '{ g(); } } return a + 1; }',
      );
    });

    test('the mutants of one node are asked one after the other, in the '
        'order they came in', () {
      expect(
        embed(source, [
          const Wrap(5, 27, 32, 'a * 1', statement: false),
          const Wrap(3, 27, 32, 'a - 1', statement: false),
        ], declared: false),
        'int f(int a) { g(); return (\$dartMutantActive == 5 ? (a * 1) : '
        '\$dartMutantActive == 3 ? (a - 1) : (a + 1)); }',
      );
      expect(
        embed(source, [
          const Wrap(1, 15, 19, ';', statement: true),
          const Wrap(2, 15, 19, 'h();', statement: true),
        ], declared: false),
        'int f(int a) { { if (\$dartMutantActive == 1) { ; } else '
        'if (\$dartMutantActive == 2) { h(); } else { g(); } } '
        'return a + 1; }',
      );
    });

    test('a wrap inside another is built into the original of that one, '
        'whatever the order they are given in', () {
      const inner = Wrap(1, 31, 32, '2', statement: false);
      const outer = Wrap(2, 27, 32, 'a - 1', statement: false);
      const whole = Wrap(3, 20, 33, 'return 0;', statement: true);
      const expected =
          'int f(int a) { g(); { if (\$dartMutantActive == 3) { return 0; } '
          'else { return (\$dartMutantActive == 2 ? (a - 1) : '
          '(a + (\$dartMutantActive == 1 ? (2) : (1)))); } } }';
      expect(embed(source, [inner, outer, whole], declared: false), expected);
      expect(embed(source, [whole, outer, inner], declared: false), expected);
    });

    test('wraps next to each other, and one that starts where another '
        'started', () {
      expect(
        embed('f() => [a, b + c];', [
          const Wrap(1, 8, 9, 'x', statement: false),
          const Wrap(2, 11, 16, 'b - c', statement: false),
          const Wrap(3, 11, 12, 'y', statement: false),
        ], declared: false),
        'f() => [(\$dartMutantActive == 1 ? (x) : (a)), '
        '(\$dartMutantActive == 2 ? (b - c) : '
        '((\$dartMutantActive == 3 ? (y) : (b)) + c))];',
      );
    });

    test('a wrap that starts where another ends is next to it', () {
      expect(
        embed('f() { g();h(); }', [
          const Wrap(1, 6, 10, ';', statement: true),
          const Wrap(2, 10, 14, ';', statement: true),
        ], declared: false),
        'f() { { if (\$dartMutantActive == 1) { ; } else { g(); } }'
        '{ if (\$dartMutantActive == 2) { ; } else { h(); } } }',
      );
    });

    test('a statement and an expression of the same text are two nodes, '
        'the statement outside', () {
      expect(
        embed('f() { g() }', [
          const Wrap(1, 6, 9, 'h()', statement: false),
          const Wrap(2, 6, 9, ';', statement: true),
        ], declared: false),
        'f() { { if (\$dartMutantActive == 2) { ; } else '
        '{ (\$dartMutantActive == 1 ? (h()) : (g())) } } }',
      );
    });

    test('lead and growth say where the node is in what replaces it', () {
      for (final wrap in const [
        Wrap(3, 27, 32, 'a - 1', statement: false),
        Wrap(12, 15, 19, ';', statement: true),
      ]) {
        final built = embed(source, [wrap], declared: false);
        expect(built.length, source.length + wrap.growth);
        expect(
          built.substring(wrap.offset + wrap.lead, wrap.end + wrap.lead),
          source.substring(wrap.offset, wrap.end),
        );
      }
    });
  });

  group('inSourceOrderOf', () {
    test('by start, the longer first, a statement first, then as given', () {
      const a = Wrap(1, 5, 9, '', statement: false);
      const b = Wrap(2, 2, 4, '', statement: false);
      const c = Wrap(3, 5, 12, '', statement: false);
      const d = Wrap(4, 5, 9, '', statement: true);
      const e = Wrap(5, 5, 9, '', statement: false);
      const f = Wrap(6, 5, 9, '', statement: true);
      expect(
        [
          for (final wrap in inSourceOrderOf([a, b, c, d, e, f])) wrap.id,
        ],
        [2, 3, 4, 6, 1, 5],
      );
      expect(
        [
          for (final wrap in inSourceOrderOf([f, e, d, c, b, a])) wrap.id,
        ],
        [2, 3, 6, 4, 5, 1],
      );
    });
  });

  test('inSourceOrderOf keeps the order of many wraps of one node', () {
    final wraps = [
      for (var id = 0; id < 100; id++)
        Wrap(id * 37 % 100, 5, 9, '', statement: id.isEven),
    ];
    expect(
      [for (final wrap in inSourceOrderOf(wraps)) wrap.id],
      [
        for (final wrap in wraps)
          if (wrap.statement) wrap.id,
        for (final wrap in wraps)
          if (!wrap.statement) wrap.id,
      ],
    );
  });

  group('the types of a program', () {
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

    Future<Map<(int, int), String>> types(String source) async {
      package.write('lib/a.dart', source);
      await analysis.typedMutantsOf('lib/a.dart', source);
      final resolved = await analysis.resolved('lib/a.dart', source);
      expect(resolved.error, isNull);
      return typesOf(resolved.unit);
    }

    /// Whether [source] is, outside the node [node], the program it is with
    /// [alternative] there, and with a choice between the two there.
    Future<(bool, bool)> same(
      String source,
      String node,
      String alternative, {
      bool statement = false,
    }) async {
      final offset = source.indexOf(node);
      final wrap = Wrap(
        1,
        offset,
        offset + node.length,
        alternative,
        statement: statement,
      );
      final original = await types(source);
      final mutated = await types(
        source.replaceRange(wrap.offset, wrap.end, alternative),
      );
      final built = await types(embed(source, [wrap]));
      return (
        sameTypesOutside(
          original,
          mutated,
          from: wrap.offset,
          to: wrap.end,
          growth: alternative.length - node.length,
        ),
        sameTypesOutside(
          original,
          built,
          from: wrap.offset,
          to: wrap.end,
          growth: wrap.growth,
          lead: wrap.lead,
        ),
      );
    }

    test('every expression has its type, a call the function type it is '
        'made by, a variable the type it declares', () async {
      expect(await types('int f(num a) { var b = [a.abs()]; return 1; }'), {
        (5, 45): 'int Function(num)',
        (19, 32): 'declares List<num>',
        (23, 32): 'List<num>',
        (24, 31): 'num by num Function()',
        (24, 25): 'num',
        (26, 29): 'num Function()',
        (41, 42): 'int',
      });
    });

    test('two nodes of one text have both their types', () async {
      // The name of a generic function, and the function it is made into.
      final found = await types(
        'T same<T>(T a) => a; int Function(int) f() => same;',
      );
      expect(found.values.where((type) => type.contains(', ')), [
        'int Function(int), T Function<T>(T)',
      ]);
    });

    test('a mutant of the same type in a place where the type is given: '
        'the same program', () async {
      expect(
        await same('int f(int a, int b) { return a + b; }', 'a + b', 'a - b'),
        (true, true),
      );
    });

    test(
      'a mutant of another type where the type is inferred: the '
      'variable has another type, with the mutant and with the choice',
      () async {
        const source = 'Object f(int a, int b) { var c = a * b; return [c]; }';
        expect(await same(source, 'a * b', 'a / b'), (false, false));
        // The statements after the declaration are another program as well.
        expect(await same(source, 'var c = a * b;', 'var c = a / b;'), (
          false,
          false,
        ));
        // The block they are in is not: nothing is outside of it.
        expect(
          await same(
            source,
            '{ var c = a * b; return [c]; }',
            '{ var c = a / b; return [c]; }',
            statement: true,
          ),
          (true, true),
        );
      },
    );

    test('a mutant that promotes more than the code: the choice is the '
        'program that was there, the mutant in place is not', () async {
      const source =
          'Object f(Object a, bool b) { if (b || a is int) { return [a]; } '
          'return 0; }';
      expect(await same(source, 'b || a is int', 'b && a is int'), (
        false,
        true,
      ));
    });

    test('a mutant that promotes less than the code: the choice is not '
        'the program that was there', () async {
      const source =
          'Object f(Object a, bool b) { if (b && a is int) { return [a]; } '
          'return 0; }';
      expect(await same(source, 'b && a is int', 'b || a is int'), (
        false,
        false,
      ));
    });

    test(
      'a member of an extension is noted with its extension: the '
      'choice between an int and a double takes it from another one',
      () async {
        const source = '''
extension A on int { String get label => 'int'; }
extension B on num { String get label => 'num'; }
extension on List<int> { int operator -() => 0; int operator +(int a) => a; }
extension C on Set<int> { int operator [](int a) => a; int operator ~() => 1; }
String f(int a, int b) => (a * b).label;
int g(List<int> a, Set<int> b) => -a + (a + 1) + b[2] + ~b;
class P {}
extension D on P { P operator +(int a) => this; }
void h(P p) { p++; }
''';
        final found = (await types(source)).values.toSet();
        expect(
          found,
          containsAll([
            'String of A in package:fixture/a.dart',
            'int of  in package:fixture/a.dart',
            'int of C in package:fixture/a.dart',
            'P of D in package:fixture/a.dart',
          ]),
        );
        expect(found.where((type) => type.contains(' of B ')), isEmpty);
        // A String either way, from another extension.
        expect(await same(source, 'a * b', 'a / b'), (false, false));
      },
    );

    test('the node itself is compared where it is in the choice', () async {
      // The list has no type of its own: it takes the one that is asked
      // for, which the choice asks for as well.
      const source = 'List<int> f() { return []; }';
      expect(await same(source, '[]', '[1]'), (true, true));
    });
  });

  group('sameTypesOutside', () {
    const original = {
      (0, 4): 'before',
      (4, 8): 'the node',
      (5, 6): 'inside',
      (2, 10): 'around',
      (8, 12): 'after',
    };

    bool same(Map<(int, int), String> other, {int? lead}) => sameTypesOutside(
      original,
      other,
      from: 4,
      to: 8,
      growth: 3,
      lead: lead,
    );

    const moved = {(0, 4): 'before', (2, 13): 'around', (11, 15): 'after'};

    test('what is before stays, what is after moves, what is around grows', () {
      expect(same(moved), isTrue);
      expect(same({...moved, (0, 4): 'other'}), isFalse);
      expect(same({...moved, (2, 13): 'other'}), isFalse);
      expect(same({...moved, (11, 15): 'other'}), isFalse);
      expect(same({...moved}..remove((0, 4))), isFalse);
      expect(same({...moved, (30, 40): 'more'}), isTrue);
    });

    test('what is in the node is not compared without a lead', () {
      expect(same({...moved, (4, 8): 'other', (5, 6): 'other'}), isTrue);
    });

    test('with a lead, what is in the node is compared where it is now', () {
      const inside = {...moved, (6, 10): 'the node', (7, 8): 'inside'};
      expect(same(inside, lead: 2), isTrue);
      expect(same(moved, lead: 2), isFalse);
      expect(same({...inside, (6, 10): 'other'}, lead: 2), isFalse);
      expect(same({...inside, (7, 8): 'other'}, lead: 2), isFalse);
    });

    test('a node that ends where the node starts is before it, one that '
        'starts where it ends is after it', () {
      expect(
        sameTypesOutside(
          const {(0, 4): 'a', (8, 9): 'b'},
          const {(0, 4): 'a', (11, 12): 'b'},
          from: 4,
          to: 8,
          growth: 3,
        ),
        isTrue,
      );
    });

    test('a node that starts with the node and is longer is around it, '
        'and so is one that ends with it', () {
      expect(
        sameTypesOutside(
          const {(4, 9): 'a', (3, 8): 'b'},
          const {(4, 12): 'a', (3, 11): 'b'},
          from: 4,
          to: 8,
          growth: 3,
          lead: 100,
        ),
        isTrue,
      );
    });
  });
}
