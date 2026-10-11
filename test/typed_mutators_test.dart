import 'package:dart_mutant/src/io/analysis.dart';
import 'package:dart_mutant/src/syntax_mutators.dart';
import 'package:dart_mutant/src/typed_mutators.dart';
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

  /// `Mutator: original → replacement` of the typed mutants of [source], in
  /// the order of the source. A mutant that does not compile ends in ` !!`.
  Future<List<String>> typed(String source, {String? only}) async {
    package.write('lib/a.dart', source);
    final mutants = await analysis.typedMutantsOf('lib/a.dart', source);
    final lines = <String>[];
    for (final mutant in mutants) {
      if (only != null && mutant.mutator != only) {
        continue;
      }
      final error = await analysis.compileErrorOf(
        'lib/a.dart',
        mutant.applyTo(source),
      );
      final original = source
          .substring(mutant.offset, mutant.end)
          .replaceAll(RegExp(r'\s+'), ' ');
      final replacement = mutant.replacement.replaceAll(RegExp(r'\s+'), ' ');
      lines.add(
        '${mutant.mutator}: $original → $replacement'
        '${error == null ? '' : ' !!'}',
      );
    }
    await analysis.release('lib/a.dart');
    return lines;
  }

  Future<List<String>> methods(String source) async => [
    for (final line in await typed(source, only: methodExpression))
      line.substring(methodExpression.length + 2),
  ];

  group('MethodExpression', () {
    test('num', () async {
      expect(
        await methods('''
List<Object> f(double d, int i, num n) => [
  d.ceil(), d.floor(), d.round(), d.truncate(), d.toInt(),
  d.ceilToDouble(), d.floorToDouble(), d.roundToDouble(),
  i.abs(), n.clamp(i, d), i.isEven, i.isOdd,
];
'''),
        [
          'ceil → floor',
          'floor → ceil',
          'round → floor',
          'round → ceil',
          'truncate → round',
          'toInt → round',
          'ceilToDouble → floorToDouble',
          'floorToDouble → ceilToDouble',
          'roundToDouble → floorToDouble',
          '.abs() → ',
          '.clamp(i, d) → ',
          'isEven → isOdd',
          'isOdd → isEven',
        ],
      );
    });

    test('a type variable is read by its bound', () async {
      expect(await methods('int f<T extends num>(T value) => value.ceil();'), [
        'ceil → floor',
      ]);
    });

    test('min and max of dart:math, with and without a prefix', () async {
      expect(
        await methods('''
import 'dart:math';
import 'dart:math' as math;

int f(int a, int b) => min(a, b) + math.max(a, b);
'''),
        ['min → max', 'max → min'],
      );
    });

    test(
      'a function of the package that is called min is left alone',
      () async {
        expect(
          await methods('int min(int a, int b) => a;\nint f() => min(1, 2);'),
          isEmpty,
        );
      },
    );

    test('String', () async {
      expect(
        await methods('''
List<Object> f(String s) => [
  s.startsWith('a'), s.endsWith('a'), s.toUpperCase(), s.toLowerCase(),
  s.trim(), s.trimLeft(), s.trimRight(), s.padLeft(2), s.padRight(2),
  s.indexOf('a'), s.lastIndexOf('a'), s.isEmpty, s.isNotEmpty,
  s.replaceAll('a', 'b'),
];
'''),
        [
          'startsWith → endsWith',
          'endsWith → startsWith',
          'toUpperCase → toLowerCase',
          'toLowerCase → toUpperCase',
          '.trim() → ',
          'trimLeft → trimRight',
          'trimRight → trimLeft',
          'padLeft → padRight',
          'padRight → padLeft',
          'indexOf → lastIndexOf',
          'lastIndexOf → indexOf',
          'isEmpty → isNotEmpty',
          'isNotEmpty → isEmpty',
        ],
      );
    });

    test('a member behind ?. and on a longer receiver', () async {
      expect(
        await methods('''
class Box {
  String? text;
}

bool f(Box box) => box.text?.trim().isEmpty ?? true;
'''),
        [
          // Without the call the receiver of isEmpty is nullable.
          '?.trim() →  !!',
          'isEmpty → isNotEmpty',
        ],
      );
    });

    test('Iterable, and what implements it', () async {
      expect(
        await methods('''
List<Object?> f(Iterable<int> i, List<int> l, Set<int> s) => [
  i.first, i.last, i.firstOrNull, i.lastOrNull,
  l.firstWhere((v) => v > 0), l.lastWhere((v) => v > 0),
  s.any((v) => v > 0), s.every((v) => v > 0),
  i.where((v) => v > 0), l.reversed,
  i.take(1), i.skip(1), i.takeWhile((v) => v > 0),
  i.skipWhile((v) => v > 0), l.isEmpty, s.isNotEmpty,
];
'''),
        [
          'first → last',
          'last → first',
          'firstOrNull → lastOrNull',
          'lastOrNull → firstOrNull',
          'firstWhere → lastWhere',
          'lastWhere → firstWhere',
          'any → every',
          'every → any',
          '.where((v) => v > 0) → ',
          '.reversed → ',
          'take → skip',
          'skip → take',
          'takeWhile → skipWhile',
          'skipWhile → takeWhile',
          'isEmpty → isNotEmpty',
          'isNotEmpty → isEmpty',
        ],
      );
    });

    test('Map, DateTime and Duration', () async {
      expect(
        await methods('''
List<Object> f(Map<String, int> m, DateTime t, Duration d) => [
  m.containsKey('a'), m.containsValue(1), m.keys, m.values,
  m.isEmpty, m.isNotEmpty,
  t.isBefore(t), t.isAfter(t), t.add(d), t.subtract(d), t.toUtc(),
  t.toLocal(),
  d.inDays, d.inHours, d.inMinutes, d.inSeconds, d.inMilliseconds,
  d.inMicroseconds,
];
'''),
        [
          'containsKey → containsValue',
          'containsValue → containsKey',
          'isEmpty → isNotEmpty',
          'isNotEmpty → isEmpty',
          'isBefore → isAfter',
          'isAfter → isBefore',
          'add → subtract',
          'subtract → add',
          'toUtc → toLocal',
          'toLocal → toUtc',
          'inDays → inHours',
          'inHours → inMinutes',
          'inMinutes → inSeconds',
          'inSeconds → inMilliseconds',
          'inMilliseconds → inMicroseconds',
        ],
      );
    });

    test('the receiver type decides: a member of the same name on another '
        'class is left alone', () async {
      expect(
        await methods('''
class Own {
  int get first => 1;
  int floor() => 2;
  bool isBefore(Own other) => true;
}

Object f(Own o, dynamic d) => [o.first, o.floor(), o.isBefore(o), d.first];
'''),
        isEmpty,
      );
    });

    test('left alone: a cascade, a tear-off that would be taken away, a '
        'call without a receiver, an assertion', () async {
      expect(
        await methods('''
extension on String {
  String tidy() => trim();
}

void f(List<int> list, String s) {
  list..add(1)..first;
  final where = list.where;
  final abs = 1.abs;
  assert(s.trim().isEmpty);
  where((v) => true);
  abs();
  s.tidy();
}
'''),
        isEmpty,
      );
    });

    test('left alone: a receiver without an interface type (dynamic, a '
        'record, a function), and a class of the package with a member of '
        'the last table', () async {
      expect(
        await methods('''
class Span {
  int get inDays => 1;
  bool isBefore(Span other) => false;
}

Object f(dynamic d, (int, int) r, int Function() g, Span s) => [
  d.abs(), d.ceil(), d.round(), d.isEven, d.first, d.trim(),
  r.\$1, g.call, s.inDays, s.isBefore(s),
];
'''),
        isEmpty,
      );
    });

    test('a member inside ? :, inside a return and behind a prefixed name '
        'is found', () async {
      expect(
        await methods('''
import 'dart:math' as math;

class Box {
  static List<int> values = [];
}

int f(bool b, int i, List<int> list) {
  return b ? i.abs() : math.max(list.first, Box.values.last);
}
'''),
        ['.abs() → ', 'max → min', 'first → last', 'last → first'],
      );
    });

    test('nothing is taken away inside a cascade: the receiver is not '
        'next to the member there', () async {
      expect(
        await methods('''
Object f(List<int> a, bool Function(int) g) => [
  a..sort()..where(g).toList(),
  a..reversed.toList(),
  a..sort()..first.abs(),
];
'''),
        ['.abs() → '],
      );
    });

    test('a tear-off is exchanged like a call', () async {
      expect(await methods('Object f(List<int> l) => l.any;'), ['any → every']);
    });
  });

  group('NumberLiteral', () {
    Future<List<String>> numbers(String source) async => [
      for (final line in await typed(source))
        if (line.contains('NumberLiteral: ')) line,
    ];

    test('a number becomes the next, and the one before when it is above '
        'zero', () async {
      expect(await numbers('int f(int a) => a * 2 + 0 - 0x10;'), [
        'NumberLiteral: 2 → 3',
        'NumberLiteral: 2 → 1',
        'NumberLiteral: 0 → 1',
        'NumberLiteral: 0x10 → 17',
        'NumberLiteral: 0x10 → 15',
      ]);
    });

    test('a double, and one that goes below zero', () async {
      expect(await numbers('double f(double a) => a*1.5-0.25 + 0.0;'), [
        'NumberLiteral: 1.5 → 2.5',
        'NumberLiteral: 1.5 → 0.5',
        'NumberLiteral: 0.25 → 1.25',
        // `a*1.5--0.75` would not be read as a subtraction.
        'NumberLiteral: 0.25 → (-0.75)',
        'NumberLiteral: 0.0 → 1.0',
      ]);
    });

    test('one is the first double whose lower neighbour is not below '
        'zero', () async {
      expect(await numbers('double f() => 1.0;'), [
        'NumberLiteral: 1.0 → 2.0',
        'NumberLiteral: 1.0 → 0.0',
      ]);
      expect(await numbers('double f() => 0.5;'), [
        'NumberLiteral: 0.5 → 1.5',
        'NumberLiteral: 0.5 → (-0.5)',
      ]);
    });

    test('a number in a return statement and in the branches of ? :', () async {
      expect(
        await numbers('''
int f(bool b) {
  return b ? 3 : 0;
}
'''),
        [
          'NumberLiteral: 3 → 4',
          'NumberLiteral: 3 → 2',
          'NumberLiteral: 0 → 1',
        ],
      );
    });

    test('a double too large to have a next one is left alone', () async {
      expect(
        await numbers('double f() => 1e20 + 9007199254740992.0;'),
        isEmpty,
      );
      expect(await numbers('double f() => 1e3;'), [
        'NumberLiteral: 1e3 → 1001.0',
        'NumberLiteral: 1e3 → 999.0',
      ]);
    });

    test('the operand of a minus sign is the number', () async {
      expect(await numbers('int f() => -1;'), [
        'NumberLiteral: 1 → 2',
        'NumberLiteral: 1 → 0',
      ]);
    });

    test('the value of a named constant has a mutator of its own', () async {
      expect(
        await numbers('''
const retries = 3;
const wait = Duration(seconds: 5);
final soft = 4;

class Limits {
  static const most = 10;
  static final some = 6;
  final int each = 7;
}

int f() {
  const local = 8;
  return local;
}
'''),
        [
          'ConstantNumberLiteral: 3 → 4',
          'ConstantNumberLiteral: 3 → 2',
          'ConstantNumberLiteral: 5 → 6',
          'ConstantNumberLiteral: 5 → 4',
          'NumberLiteral: 4 → 5',
          'NumberLiteral: 4 → 3',
          'ConstantNumberLiteral: 10 → 11',
          'ConstantNumberLiteral: 10 → 9',
          'NumberLiteral: 6 → 7',
          'NumberLiteral: 6 → 5',
          'NumberLiteral: 7 → 8',
          'NumberLiteral: 7 → 6',
          'NumberLiteral: 8 → 9',
          'NumberLiteral: 8 → 7',
        ],
      );
    });

    test('left alone: an annotation and an assertion', () async {
      expect(
        await numbers('''
@Deprecated('1')
void f(int a) {
  assert(a > 1);
}
'''),
        isEmpty,
      );
    });

    test('left alone: an assertion in the initializers of a constructor, '
        'and the annotation of a directive', () async {
      expect(
        await typed('''
@Deprecated('2')
library;

import 'dart:math' show max;
export 'dart:math' show min;

class A {
  A(this.a) : assert(a > 3 && max(a, 4).isEven), b = a + 5;

  final int a;
  final int b;
}
'''),
        ['NumberLiteral: 5 → 6', 'NumberLiteral: 5 → 4'],
      );
    });
  });

  group('guards on null and on a type', () {
    test('a guard that leaves: taken always, throwing, and swapped with the '
        'guard after it', () async {
      expect(
        await typed('''
String f(String? name, String? title) {
  if (name == null) {
    return 'nobody';
  }
  if (title == null) {
    return name;
  }
  return title + name;
}
'''),
        [
          "GuardAlwaysTaken: { return 'nobody'; } → { return 'nobody'; } "
              "else if (1 == 1) { return 'nobody'; }",
          "GuardThrows: { return 'nobody'; } → "
              "{ throw StateError('mutant'); }",
          // `name` is still nullable there: the analyzer refuses it.
          "GuardResultSwapped: { return 'nobody'; } → { return name; } !!",
          "GuardResultSwapped: { return name; } → { return 'nobody'; }",
          'GuardAlwaysTaken: { return name; } → { return name; } '
              'else if (1 == 1) { return name; }',
          "GuardThrows: { return name; } → { throw StateError('mutant'); }",
        ],
      );
    });

    test('the mutants of a guard compile where its syntax mutants do '
        'not', () async {
      const source = '''
int f(String? name) {
  if (name == null) {
    return -1;
  }
  return name.length;
}
''';
      package.write('lib/a.dart', source);
      final typedMutants = await analysis.typedMutantsOf('lib/a.dart', source);
      final refused = <String>[];
      for (final mutant in [
        ...findSyntaxMutants(source).mutants,
        ...typedMutants,
      ]) {
        if (await analysis.compileErrorOf(
              'lib/a.dart',
              mutant.applyTo(source),
            ) !=
            null) {
          refused.add('${mutant.mutator} → ${mutant.replacement}');
        }
      }
      await analysis.release('lib/a.dart');
      expect(refused, [
        'ConditionalExpression → (name == null) || true',
        'ConditionalExpression → (name == null) && false',
        'EqualityOperator → !=',
        'BlockStatement → {}',
      ]);
    });

    test('a guard without braces, on a type, in a loop', () async {
      expect(
        await typed('''
int f(List<Object> values) {
  var sum = 0;
  for (final value in values) {
    if (value is! int) continue;
    sum += value;
  }
  return sum;
}
''', only: guardAlwaysTaken),
        ['GuardAlwaysTaken: continue; → continue; else if (1 == 1) continue;'],
      );
    });

    test('a guard that is the last statement, and one that is no statement '
        'of a block, have no next guard to swap with', () async {
      expect(
        await typed('''
int f(List<int?> values, int? last) {
  for (final value in values)
    if (value == null) return 1;
  if (last == null) {
    return 2;
  }
}
''', only: guardResultSwapped),
        isEmpty,
      );
      expect(
        await typed('''
int f(List<int?> values) {
  for (final value in values)
    if (value == null) return 1;
  return 2;
}
''', only: guardAlwaysTaken),
        ['GuardAlwaysTaken: return 1; → return 1; else if (1 == 1) return 1;'],
      );
    });

    test('two guards with the same result are not swapped, and neither is '
        'a guard with what follows when that is no guard', () async {
      expect(
        await typed('''
int? f(int? a, int? b, int c) {
  if (a == null) return null;
  if (b == null) return null;
  if (b == a) {
    c++;
  }
  if (a == null) return null;
  if (b == null) return c; else return a;
}

int? g(int? a, Object b) {
  if (a == null) return null;
  if (b case final int c) return c;
  if (a == null) return null;
  return a;
}
''', only: guardResultSwapped),
        isEmpty,
      );
    });

    test('a null test inside a closure of the condition promotes nothing '
        'in the condition', () async {
      expect(
        await typed('''
int f(List<int?> values) {
  if (values.any((value) => value == null)) {
    return 1;
  }
  if (values.every((value) => value is int)) return 2; else return 3;
  return values.any((value) => value == null) ? 4 : 5;
}
''', only: guardAlwaysTaken),
        isEmpty,
      );
      expect(
        await typed('''
int f(List<int?> values) {
  if (values.every((value) => value is int)) return 2; else return 3;
}

int g(List<int?> values) => values.any((value) => value == null) ? 4 : 5;
''', only: branchCopied),
        isEmpty,
      );
    });

    test('a guard on != null, and one that leaves by throw or rethrow', () async {
      expect(
        await typed('''
String f(String? name, Object value) {
  if (name != null) return name;
  if (value is! String) throw ArgumentError();
  try {
    return value;
  } catch (_) {
    if (name == null) rethrow;
    return name;
  }
}
''', only: guardAlwaysTaken),
        [
          'GuardAlwaysTaken: return name; → return name; else if (1 == 1) '
              'return name; !!', // The copy does not know that the name is a string.
          'GuardAlwaysTaken: throw ArgumentError(); → throw ArgumentError(); '
              'else if (1 == 1) throw ArgumentError();',
          'GuardAlwaysTaken: rethrow; → rethrow; else if (1 == 1) rethrow;',
        ],
      );
    });

    test('a block leaves when its last statement does, whatever its first '
        'is', () async {
      expect(
        await typed('''
int f(int? a, int? b, void Function() log) {
  if (a == null) {
    log();
    return 1;
  }
  if (b == null) {
    return 2;
    log();
  }
  if (a == b) {}
  return 3;
}
''', only: guardThrows),
        ["GuardThrows: { log(); return 1; } → { throw StateError('mutant'); }"],
      );
    });

    test('left alone: a body that is a loop, an if or an empty block, and '
        'a ?? with null that is no test', () async {
      expect(
        await typed('''
int f(int? a, List<int?> values, bool b) {
  if (a == null) while (b) {}
  if (a == null) for (;;) {}
  if (a == null) if (b) return 1;
  if (a == null) {}
  if (values.contains(a ?? null)) return 2;
  if (values.contains(a ?? null)) return 3; else return 4;
  return values.contains(a ?? null) ? 5 : 6;
}
'''),
        [
          for (final number in [1, 2, 3, 4, 5, 6]) ...[
            'NumberLiteral: $number → ${number + 1}',
            'NumberLiteral: $number → ${number - 1}',
          ],
        ],
      );
    });

    test('the last two statements of a block can be two guards', () async {
      expect(
        await typed('''
void f(int? a, int? b) {
  if (a == null) return;
  if (b == null) throw 1;
}
''', only: guardResultSwapped),
        [
          'GuardResultSwapped: return; → throw 1;',
          'GuardResultSwapped: throw 1; → return;',
        ],
      );
    });

    test('left alone: a guard that does not leave, a condition that tests '
        'neither null nor a type, if-case', () async {
      expect(
        await typed('''
void f(String? name, int count, Object value, void Function(String) log) {
  if (name == null) {
    log('none');
  }
  if (count > 2) {
    return;
  }
  if (value case final String text) {
    return log(text);
  }
}
'''),
        ['NumberLiteral: 2 → 3', 'NumberLiteral: 2 → 1'],
      );
    });

    test('one operand of a || of null tests', () async {
      expect(
        await typed('''
bool f(String? a, String? b) {
  if (a == null || b == null) {
    return true;
  }
  return a == b;
}
''', only: guardThrows),
        [
          "GuardThrows: a == null → (a == null && (throw StateError('mutant')))",
          "GuardThrows: b == null → (b == null && (throw StateError('mutant')))",
          "GuardThrows: { return true; } → { throw StateError('mutant'); }",
        ],
      );
    });

    test('BranchCopied: both branches of an if and of ? :', () async {
      expect(
        await typed('''
String f(Object value) {
  if (value is String) {
    return value;
  } else {
    return '\$value';
  }
}

String g(String? name) => name == null ? 'none' : name;
''', only: branchCopied),
        [
          "BranchCopied: { return value; } → { return '\$value'; }",
          // An Object where a String is returned.
          "BranchCopied: { return '\$value'; } → { return value; } !!",
          'BranchCopied: \'none\' → name !!',
          "BranchCopied: name → 'none'",
        ],
      );
    });

    test('BranchCopied leaves alone an else that could take the else of '
        'the if it is copied into', () async {
      expect(
        await typed('''
void f(Object? v, bool b, void Function() g) {
  if (v == null)
    g();
  else
    while (b) if (b) g();
  if (v is int) g(); else return;
}
''', only: branchCopied),
        ['BranchCopied: g(); → return;', 'BranchCopied: return; → g();'],
      );
    });

    test('BranchCopied: an else that is a call, a break or a continue '
        'stands alone', () async {
      expect(
        await typed('''
void f(List<Object?> values, void Function() g) {
  for (final v in values) {
    if (v == null) return; else g();
    if (v is int) return; else break;
  }
  for (final v in values) {
    if (v is! int) return; else continue;
  }
}
''', only: branchCopied),
        [
          'BranchCopied: return; → g();',
          'BranchCopied: g(); → return;',
          'BranchCopied: return; → break;',
          'BranchCopied: break; → return;',
          'BranchCopied: return; → continue;',
          'BranchCopied: continue; → return;',
        ],
      );
    });

    test('BranchCopied leaves alone: equal branches, else if, a condition '
        'without a promotion', () async {
      expect(
        await typed('''
int f(Object? v, bool b) {
  if (v == null) {
    return 0;
  } else if (b) {
    return 1;
  }
  final same = v is int ? b : b;
  return b ? (same ? 2 : 3) : 4;
}
''', only: branchCopied),
        isEmpty,
      );
    });
  });

  group('ReturnValue', () {
    Future<List<String>> returns(String source) async => [
      for (final line in await typed(source, only: returnValue))
        line.substring(returnValue.length + 2),
    ];

    test('a function that may return null: a value becomes null, null '
        'becomes a value', () async {
      expect(
        await returns('''
int? a(bool b) {
  if (b) {
    return null;
  }
  return 1;
}

String? s(bool b) => b ? 'x' : null;
bool? c() => null;
double? d() => null;
num? n() => null;
String? t() => null;
List<int>? l() => null;
'''),
        [
          'null → 0',
          '1 → null',
          "b ? 'x' : null → null",
          'null → false',
          'null → 0.0',
          'null → 0',
          "null → 'mutated'",
        ],
      );
    });

    test('async, a getter, a closure', () async {
      expect(
        await returns('''
import 'dart:async';

Future<String?> a(String v) async => v;
FutureOr<int?> b(int v) async {
  return v;
}

class C {
  String? get name => 'c';
}

final d = (String? v) => v;
'''),
        ['v → null', 'v → null', "'c' → null", 'v → null'],
      );
    });

    test('left alone: a constructor', () async {
      expect(
        await returns('''
class A {
  A._();
  factory A() {
    return A._();
  }
  factory A.other() => A._();
}
'''),
        isEmpty,
      );
    });

    test('a closure that is an argument of something unknown is read by its '
        'own type', () async {
      expect(
        await returns('''
final a = unknown((int? v) => v);
'''),
        ['v → null'],
      );
    });

    test('a top-level getter, a local function and a method', () async {
      expect(
        await returns('''
int? get g => 1;

class C {
  int? m() {
    int? local() => 2;
    return local();
  }
}
'''),
        ['1 → null', '2 → null', 'local() → null'],
      );
    });

    test('left alone: a function that can only return null', () async {
      expect(
        await returns('''
Null f(Null x) => x;
Null g(Null x) {
  return x;
}
'''),
        isEmpty,
      );
    });

    test('left alone: a type that is not nullable, void, dynamic, a '
        'generator', () async {
      expect(
        await returns('''
int a() => 1;
void b() => print('b');
dynamic c() => 1;
Iterable<int?> d() sync* {
  yield 1;
}
Null e() => null;
Future<int> f() async => 1;
'''),
        isEmpty,
      );
    });
  });

  test('the names of the mutators, as the report and an allowance spell '
      'them', () {
    expect(
      [
        methodExpression,
        numberLiteral,
        constantNumberLiteral,
        guardAlwaysTaken,
        guardThrows,
        guardResultSwapped,
        branchCopied,
        returnValue,
      ],
      [
        'MethodExpression',
        'NumberLiteral',
        'ConstantNumberLiteral',
        'GuardAlwaysTaken',
        'GuardThrows',
        'GuardResultSwapped',
        'BranchCopied',
        'ReturnValue',
      ],
    );
    // The number that is part of the key of a reused result. It goes up
    // with every change that gives another mutant for the same source, and
    // this line with it.
    expect(mutatorsVersion, 2);
  });

  test('the names are not names of the syntax mutators', () {
    final source = [
      for (final name in [
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
      ])
        name,
    ];
    expect(
      {
        methodExpression,
        numberLiteral,
        constantNumberLiteral,
        guardAlwaysTaken,
        guardThrows,
        guardResultSwapped,
        branchCopied,
        returnValue,
      }.intersection(source.toSet()),
      isEmpty,
    );
  });

  test('typed mutants are in the order of the source', () async {
    const source = 'int? f(int a) => a.abs() + 1;';
    package.write('lib/a.dart', source);
    final mutants = await analysis.typedMutantsOf('lib/a.dart', source);
    await analysis.release('lib/a.dart');
    expect([
      for (final mutant in mutants) mutant.offset,
    ], [for (final mutant in mutants) mutant.offset]..sort());
    expect(mutants.first.mutator, returnValue);
  });
}
