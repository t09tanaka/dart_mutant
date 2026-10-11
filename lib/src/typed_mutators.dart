import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_provider.dart';
import 'package:analyzer/dart/element/type_system.dart';

import 'mutant.dart';

/// Changes whenever the mutators (the syntax ones or the ones here) would
/// produce other mutants for the same source. A result of an earlier run is
/// only reused for the same number.
const mutatorsVersion = 2;

/// The names of the mutators in this file. None of them is a name of a
/// syntax mutator.
const methodExpression = 'MethodExpression';
const numberLiteral = 'NumberLiteral';
const constantNumberLiteral = 'ConstantNumberLiteral';
const guardAlwaysTaken = 'GuardAlwaysTaken';
const guardThrows = 'GuardThrows';
const guardResultSwapped = 'GuardResultSwapped';
const branchCopied = 'BranchCopied';
const returnValue = 'ReturnValue';

/// Members that can stand in for one another on the same receiver type.
/// `null` as the replacement: the call is taken away and the receiver stays.
const _num = <String, List<String?>>{
  'ceil': ['floor'],
  'floor': ['ceil'],
  'round': ['floor', 'ceil'],
  'truncate': ['round'],
  'toInt': ['round'],
  'ceilToDouble': ['floorToDouble'],
  'floorToDouble': ['ceilToDouble'],
  'roundToDouble': ['floorToDouble'],
  'abs': [null],
  'clamp': [null],
  'isEven': ['isOdd'],
  'isOdd': ['isEven'],
};

const _string = <String, List<String?>>{
  'startsWith': ['endsWith'],
  'endsWith': ['startsWith'],
  'toUpperCase': ['toLowerCase'],
  'toLowerCase': ['toUpperCase'],
  'trim': [null],
  'trimLeft': ['trimRight'],
  'trimRight': ['trimLeft'],
  'padLeft': ['padRight'],
  'padRight': ['padLeft'],
  'indexOf': ['lastIndexOf'],
  'lastIndexOf': ['indexOf'],
  'isEmpty': ['isNotEmpty'],
  'isNotEmpty': ['isEmpty'],
};

const _iterable = <String, List<String?>>{
  'first': ['last'],
  'last': ['first'],
  'firstOrNull': ['lastOrNull'],
  'lastOrNull': ['firstOrNull'],
  'firstWhere': ['lastWhere'],
  'lastWhere': ['firstWhere'],
  'any': ['every'],
  'every': ['any'],
  'where': [null],
  'reversed': [null],
  'take': ['skip'],
  'skip': ['take'],
  'takeWhile': ['skipWhile'],
  'skipWhile': ['takeWhile'],
  'isEmpty': ['isNotEmpty'],
  'isNotEmpty': ['isEmpty'],
};

const _map = <String, List<String?>>{
  'containsKey': ['containsValue'],
  'containsValue': ['containsKey'],
  'isEmpty': ['isNotEmpty'],
  'isNotEmpty': ['isEmpty'],
};

const _dateTime = <String, List<String?>>{
  'isBefore': ['isAfter'],
  'isAfter': ['isBefore'],
  'add': ['subtract'],
  'subtract': ['add'],
  'toUtc': ['toLocal'],
  'toLocal': ['toUtc'],
};

/// One step finer: the number gets larger, which a comparison notices.
const _duration = <String, List<String?>>{
  'inDays': ['inHours'],
  'inHours': ['inMinutes'],
  'inMinutes': ['inSeconds'],
  'inSeconds': ['inMilliseconds'],
  'inMilliseconds': ['inMicroseconds'],
};

/// The top-level functions of `dart:math`.
const _math = {'min': 'max', 'max': 'min'};

/// The members that are taken away (`null` in the tables) and are getters:
/// the others are only taken away where they are called.
const _removedGetters = {'reversed'};

bool _isNullTest(Expression expression) =>
    expression is BinaryExpression &&
    (expression.operator.lexeme == '==' ||
        expression.operator.lexeme == '!=') &&
    (expression.leftOperand is NullLiteral ||
        expression.rightOperand is NullLiteral);

class _PromotionFinder extends RecursiveAstVisitor<void> {
  bool found = false;

  @override
  void visitBinaryExpression(BinaryExpression node) {
    if (_isNullTest(node)) {
      found = true;
    }
    super.visitBinaryExpression(node);
  }

  @override
  void visitIsExpression(IsExpression node) {
    found = true;
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {}
}

/// True when [condition] holds a test that promotes a variable (`x != null`,
/// `x is T`): the conditions whose syntax mutants mostly do not compile.
bool _promotes(Expression condition) {
  final finder = _PromotionFinder();
  condition.accept(finder);
  return finder.found;
}

/// True when [statement] can be put in front of an `else` without taking
/// that `else` for itself: a block, or a statement that ends in `;` and has
/// no statement inside.
bool _standsAlone(Statement statement) =>
    statement is Block ||
    statement is ReturnStatement ||
    statement is ExpressionStatement ||
    statement is BreakStatement ||
    statement is ContinueStatement;

/// True when control never gets past [statement].
bool _exits(Statement statement) {
  if (statement is ReturnStatement ||
      statement is ContinueStatement ||
      statement is BreakStatement) {
    return true;
  }
  if (statement is ExpressionStatement) {
    return statement.expression is ThrowExpression ||
        statement.expression is RethrowExpression;
  }
  if (statement is Block) {
    return statement.statements.isNotEmpty && _exits(statement.statements.last);
  }
  return false;
}

class _Finder extends RecursiveAstVisitor<void> {
  _Finder(this.source, this.typeProvider, this.typeSystem);

  final String source;
  final TypeProvider typeProvider;
  final TypeSystem typeSystem;
  final mutants = <Mutant>[];

  void _add(String mutator, int offset, int end, String replacement) =>
      mutants.add(Mutant(mutator, offset, end, replacement));

  void _node(String mutator, AstNode node, String replacement) =>
      _add(mutator, node.offset, node.end, replacement);

  String _text(AstNode node) => source.substring(node.offset, node.end);

  // What the syntax mutators leave alone is left alone here. (A directive
  // holds nothing these mutators look for outside its annotations.)
  @override
  void visitAnnotation(Annotation node) {}

  @override
  void visitAssertStatement(AssertStatement node) {}

  @override
  void visitAssertInitializer(AssertInitializer node) {}

  // ---- members ----------------------------------------------------------

  bool _core(InterfaceType type, String name) =>
      type.element.name == name && type.element.library.isDartCore;

  Map<String, List<String?>>? _tableFor(DartType? type) {
    var receiver = type;
    if (receiver is TypeParameterType) {
      receiver = receiver.bound;
    }
    if (receiver is! InterfaceType) {
      return null;
    }
    if (typeSystem.isSubtypeOf(
      typeSystem.promoteToNonNull(receiver),
      typeProvider.numType,
    )) {
      return _num;
    }
    if (receiver.isDartCoreString) {
      return _string;
    }
    if (receiver.asInstanceOf(typeProvider.iterableElement) != null) {
      return _iterable;
    }
    if (receiver.asInstanceOf(typeProvider.mapElement) != null) {
      return _map;
    }
    if (_core(receiver, 'DateTime')) {
      return _dateTime;
    }
    if (_core(receiver, 'Duration')) {
      return _duration;
    }
    return null;
  }

  void _member(
    Expression whole,
    Expression? target,
    SimpleIdentifier name, {
    required bool called,
  }) {
    if (target == null) {
      return;
    }
    final replacements = _tableFor(target.staticType)?[name.name];
    if (replacements == null) {
      return;
    }
    for (final replacement in replacements) {
      if (replacement != null) {
        _node(methodExpression, name, replacement);
      } else if (called != _removedGetters.contains(name.name)) {
        // `x.abs()` → `x`; a tear-off (`x.abs`) is left alone.
        _add(methodExpression, target.end, whole.end, '');
      }
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    // In a cascade the receiver is not written next to the member.
    if (!node.isCascaded) {
      _member(node, node.realTarget, node.methodName, called: true);
    }
    final element = node.methodName.element;
    if (element is TopLevelFunctionElement &&
        element.library.uri.toString() == 'dart:math') {
      final replacement = _math[node.methodName.name];
      if (replacement != null) {
        _node(methodExpression, node.methodName, replacement);
      }
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    if (!node.isCascaded) {
      _member(node, node.realTarget, node.propertyName, called: false);
    }
    super.visitPropertyAccess(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    // `math.pi` has an import prefix in front, not a receiver: a prefix has
    // no type, so no table. (The two names below this node hold nothing to
    // visit.)
    _member(node, node.prefix, node.identifier, called: false);
  }

  // ---- numbers ----------------------------------------------------------

  /// The mutator for a number at [node]: one of its own for the value of a
  /// named constant (`const retries = 3;`, `static const limit = 10;`), so
  /// that those can be told apart from a number inside the logic.
  String _numberMutator(AstNode node) {
    final variable = node.thisOrAncestorOfType<VariableDeclaration>();
    final list = variable?.parent;
    if (list is! VariableDeclarationList || !list.isConst) {
      return numberLiteral;
    }
    final declaration = list.parent;
    final named =
        declaration is TopLevelVariableDeclaration ||
        (declaration is FieldDeclaration && declaration.isStatic);
    return named ? constantNumberLiteral : numberLiteral;
  }

  @override
  void visitIntegerLiteral(IntegerLiteral node) {
    final value = node.value;
    // `null`: the literal does not fit an int.
    if (value != null) {
      final mutator = _numberMutator(node);
      _node(mutator, node, '${value + 1}');
      if (value > 0) {
        _node(mutator, node, '${value - 1}');
      }
    }
  }

  @override
  void visitDoubleLiteral(DoubleLiteral node) {
    final value = node.value;
    // Above 2^53 the next double is the same double: nothing would change.
    if (value.isFinite && value + 1 != value) {
      final mutator = _numberMutator(node);
      _node(mutator, node, '${value + 1}');
      if (value > 0) {
        // `a-0.5` → `a--0.5` would be another program altogether.
        final less = value - 1;
        _node(mutator, node, less < 0 ? '($less)' : '$less');
      }
    }
  }

  // ---- null tests and type tests ----------------------------------------
  //
  // The syntax mutants of `if (x == null) return …;` (`(c) || true`, the
  // flipped test, the emptied block) mostly do not compile: the code after
  // the guard relies on the promotion. These say the same things in a form
  // that keeps the promotion.

  @override
  void visitIfStatement(IfStatement node) {
    if (node.caseClause == null && _promotes(node.expression)) {
      final then = node.thenStatement;
      final otherwise = node.elseStatement;
      if (otherwise == null && _exits(then)) {
        // The guard is taken whatever the test says: what `(c) || true`
        // means. `else <then>` alone would leave the rest unreachable, and
        // unreachable code is checked without the promotion; a test that
        // the flow analysis does not evaluate keeps the rest reachable.
        _node(
          guardAlwaysTaken,
          then,
          '${_text(then)} else if (1 == 1) ${_text(then)}',
        );
        // The guard no longer decides anything for the value it lets
        // through: what the emptied block means.
        _node(guardThrows, then, "{ throw StateError('mutant'); }");
        _swapWithNextGuard(node);
      } else if (otherwise != null) {
        final a = _text(then);
        final b = _text(otherwise);
        // A statement that can end in an `if` (`else if (…) …`, a loop
        // without braces) cannot stand where the first branch is without
        // changing which `else` belongs to which `if`.
        if (a != b && _standsAlone(otherwise)) {
          _node(branchCopied, then, b);
          _node(branchCopied, otherwise, a);
        }
      }
    }
    super.visitIfStatement(node);
  }

  /// Two guards in a row (`if (a == null) return x; if (b == null) return
  /// y;`): each gets the result of the other.
  void _swapWithNextGuard(IfStatement node) {
    final parent = node.parent;
    if (parent is! Block) {
      return;
    }
    final index = parent.statements.indexOf(node);
    if (index + 1 >= parent.statements.length) {
      return;
    }
    final next = parent.statements[index + 1];
    if (next is! IfStatement ||
        next.elseStatement != null ||
        next.caseClause != null ||
        !_exits(next.thenStatement)) {
      return;
    }
    final a = _text(node.thenStatement);
    final b = _text(next.thenStatement);
    if (a == b) {
      return;
    }
    _node(guardResultSwapped, node.thenStatement, b);
    _node(guardResultSwapped, next.thenStatement, a);
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    if (_promotes(node.condition)) {
      final a = _text(node.thenExpression);
      final b = _text(node.elseExpression);
      if (a != b) {
        _node(branchCopied, node.thenExpression, b);
        _node(branchCopied, node.elseExpression, a);
      }
    }
    super.visitConditionalExpression(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    // One operand of `a == null || b == null`: the test stays, and the
    // value it used to send away is refused instead.
    final parent = node.parent;
    if (_isNullTest(node) &&
        node.operator.lexeme == '==' &&
        parent is BinaryExpression &&
        parent.operator.lexeme == '||') {
      _node(
        guardThrows,
        node,
        "(${_text(node)} && (throw StateError('mutant')))",
      );
    }
    super.visitBinaryExpression(node);
  }

  /// The type of the values that the function with [body] returns: for an
  /// `async` function what its future completes with. `null` when it is not
  /// known.
  DartType? _returnType(FunctionBody body) {
    DartType? declared;
    final parent = body.parent;
    if (parent is MethodDeclaration) {
      declared = parent.declaredFragment?.element.returnType;
    } else if (parent is FunctionExpression) {
      // A function, a local function or a closure.
      final type = parent.staticType;
      declared = type is FunctionType ? type.returnType : null;
    }
    if (body.isAsynchronous &&
        declared is InterfaceType &&
        (declared.isDartAsyncFuture || declared.isDartAsyncFutureOr)) {
      return declared.typeArguments.single;
    }
    return declared;
  }

  /// A function that may return `null`: a value becomes `null`, and `null`
  /// becomes a value where the type has an obvious one.
  void _returned(Expression value) {
    // A returned value is always inside the body of a function. (Not of a
    // generator: `return value` is an error there, and so is `=>`.)
    final type = _returnType(value.thisOrAncestorOfType<FunctionBody>()!);
    if (type == null ||
        type is VoidType ||
        type is DynamicType ||
        type is InvalidType ||
        type.isDartCoreNull ||
        !typeSystem.isNullable(type)) {
      return;
    }
    if (value is! NullLiteral) {
      _node(returnValue, value, 'null');
      return;
    }
    final plain = typeSystem.promoteToNonNull(type);
    final other = plain.isDartCoreBool
        ? 'false'
        : plain.isDartCoreInt || plain.isDartCoreNum
        ? '0'
        : plain.isDartCoreDouble
        ? '0.0'
        : plain.isDartCoreString
        ? "'mutated'"
        : null;
    if (other != null) {
      _node(returnValue, value, other);
    }
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    final value = node.expression;
    if (value != null) {
      _returned(value);
    }
    super.visitReturnStatement(node);
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    _returned(node.expression);
    super.visitExpressionFunctionBody(node);
  }
}

/// The mutants that need the types of a resolved [unit] of [source], in the
/// order of the source.
///
/// - Members of `num`, `String`, `Iterable`, `Map`, `DateTime` and
///   `Duration`, and `min` / `max` of `dart:math`, are exchanged for their
///   counterpart or taken away. The receiver type decides, so `first` of a
///   class of the package is left alone.
/// - A number becomes the next and (above zero) the one before.
/// - A guard on `null` or on a type is mutated in forms that keep the type
///   promotion the code after it relies on.
/// - A function that may return `null` returns `null`, or a value in place
///   of `null`.
///
/// Whether a mutant compiles is not decided here: every mutant is checked by
/// the analyzer before a test is run on it.
List<Mutant> findTypedMutants(
  CompilationUnit unit,
  String source,
  TypeProvider typeProvider,
  TypeSystem typeSystem,
) {
  final finder = _Finder(source, typeProvider, typeSystem);
  unit.accept(finder);
  return inSourceOrder(finder.mutants);
}
