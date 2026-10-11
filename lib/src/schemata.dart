import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'mutant.dart';

/// The variable that says which mutant of a file is at work, when the
/// mutants are built into the file (`--schemata`): the number of the
/// mutant, or [noMutant].
const switchName = r'$dartMutantActive';

/// The value of [switchName] with which the file does what it did before.
const noMutant = -1;

/// What is added to the end of a file its mutants are built into. At the
/// end, so that no place in the file moves.
const switchDeclaration = '\nint $switchName = $noMutant;\n';

/// The longest text that is written a second time to build a mutant in. A
/// mutant that needs more (a whole long function) is run the usual way.
const longestAlternative = 4000;

/// Why the mutants of [source] cannot be built into it at all, or `null`
/// when they can.
String? fileObstacle(String source) {
  if (source.startsWith('\uFEFF')) {
    return 'starts with a byte order mark';
  }
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  // As a name: in a string or a comment it is in nobody's way.
  for (var token = unit.beginToken; !token.isEof; token = token.next!) {
    if (token.lexeme == switchName) {
      return 'has the name $switchName in it';
    }
  }
  if (unit.directives.any((directive) => directive is PartOfDirective)) {
    // The driver imports the file to set the variable.
    return 'is a part of a library';
  }
  return null;
}

/// A mutant as a choice made while the program runs: the node from [offset]
/// to [end] does what [alternative] says while the mutant [id] is at work.
class Wrap {
  const Wrap(
    this.id,
    this.offset,
    this.end,
    this.alternative, {
    required this.statement,
  });

  /// The number of the mutant in its file.
  final int id;
  final int offset;
  final int end;

  /// The node with the mutant in it.
  final String alternative;

  /// True when the node is a statement, false when it is an expression.
  final bool statement;

  String get _choice => statement
      ? 'if ($switchName == $id) { $alternative } else '
      : '$switchName == $id ? ($alternative) : ';

  /// How far the node is from the start of what it is replaced with, when
  /// this is the only mutant built into it.
  int get lead => _open.length + _choice.length + _open.length;

  String get _open => statement ? '{ ' : '(';

  /// How much longer the file is with this mutant built in, alone.
  int get growth => lead + _close.length;

  String get _close => statement ? ' } }' : '))';
}

/// [source] with [wraps] built in: every node of a wrap is replaced with a
/// choice between its mutants and itself. A wrap inside the node of another
/// is built into the original of that one; the mutants of one node are asked
/// one after the other.
///
/// Without [declared] the variable is not declared: for a look at one part.
String embed(String source, List<Wrap> wraps, {bool declared = true}) {
  String rewrite(int from, int to, List<Wrap> inside) {
    final sorted = inSourceOrderOf(inside);
    final out = StringBuffer();
    var at = from;
    for (final head in sorted) {
      if (head.offset < at) {
        // In the node of a wrap before it, and built in with that one.
        continue;
      }
      bool together(Wrap wrap) =>
          wrap.offset == head.offset &&
          wrap.end == head.end &&
          wrap.statement == head.statement;
      out
        ..write(source.substring(at, head.offset))
        ..write(head._open)
        ..writeAll([
          for (final wrap in sorted)
            if (together(wrap)) wrap._choice,
        ])
        ..write(head._open)
        ..write(
          rewrite(head.offset, head.end, [
            for (final wrap in sorted)
              if (wrap.offset >= head.offset &&
                  wrap.end <= head.end &&
                  !together(wrap))
                wrap,
          ]),
        )
        ..write(head._close);
      at = head.end;
    }
    out.write(source.substring(at, to));
    return out.toString();
  }

  return '${rewrite(0, source.length, wraps)}'
      '${declared ? switchDeclaration : ''}';
}

/// [wraps] with the outer ones first: by where they start, the longer one
/// first, a statement before an expression of the same text, and otherwise
/// in the order they came in.
List<Wrap> inSourceOrderOf(List<Wrap> wraps) {
  final indexed = wraps.indexed.toList()
    ..sort((a, b) {
      final byStart = a.$2.offset - b.$2.offset;
      if (byStart != 0) {
        return byStart;
      }
      final byEnd = b.$2.end - a.$2.end;
      if (byEnd != 0) {
        return byEnd;
      }
      final byKind = (a.$2.statement ? 0 : 1) - (b.$2.statement ? 0 : 1);
      return byKind != 0 ? byKind : a.$1 - b.$1;
    });
  return [for (final (_, wrap) in indexed) wrap];
}

/// Why a mutant has no place where it can be built in.
const runsOnce = 'in an initializer that runs once in a process';
const constantContext = 'in a constant';
const noPlace = 'no expression or statement around it can take it';

/// Where a mutant could be built in.
class Places {
  const Places(this.wraps, this.reason);

  /// The nodes around the mutant that can be replaced with a choice, the
  /// smallest first.
  final List<Wrap> wraps;

  /// Why the smaller nodes, or all of them, were left out.
  final String reason;
}

class _Covering extends GeneralizingAstVisitor<void> {
  _Covering(this.from, this.to);

  final int from;
  final int to;
  final nodes = <AstNode>[];

  @override
  void visitNode(AstNode node) {
    if (node.offset <= from && to <= node.end) {
      nodes.add(node);
      super.visitNode(node);
    }
  }
}

/// The nodes of [unit] that hold the text from [from] to [to], the inner
/// ones first.
///
/// (Where [from] is [to] and one node ends there and the next one starts,
/// the nodes of the second come first, then the ones of the first, then
/// what is around both.)
List<AstNode> _around(CompilationUnit unit, int from, int to) {
  final covering = _Covering(from, to);
  unit.accept(covering);
  return covering.nodes.reversed.toList();
}

/// True for a statement that declares a name for the statements after it:
/// in a block of its own the name would be gone.
bool _declares(Statement node) =>
    node is VariableDeclarationStatement ||
    node is FunctionDeclarationStatement ||
    node is PatternVariableDeclarationStatement;

/// True for an expression that is not a value of its own: the `b` of `a.b`
/// and of `a.b()`, the `a` of a named argument `a: 1`, and the parameters
/// and the body of a function that is declared with a name.
bool _isNoValue(Expression node) {
  final parent = node.parent;
  return node is SimpleIdentifier &&
          (parent is MethodInvocation && parent.methodName == node ||
              parent is PropertyAccess && parent.propertyName == node ||
              parent is PrefixedIdentifier ||
              parent is Label) ||
      node is FunctionExpression && parent is FunctionDeclaration;
}

/// True when [node] is in the initializer of a top-level variable or of a
/// static field, outside every function in it: that code runs once in a
/// process, when the variable is first read, so a mutant in it cannot be
/// changed for another while the program runs.
bool _runsOnce(AstNode node) {
  for (AstNode? at = node; at != null; at = at.parent) {
    if (at is FunctionBody) {
      return false;
    }
    if (at is TopLevelVariableDeclaration) {
      return true;
    }
    if (at is FieldDeclaration) {
      return at.isStatic;
    }
  }
  return false;
}

/// Where [mutant] (the mutant [id] of [source], whose syntax tree is [unit])
/// could be built in: every expression and statement around it that is an
/// expression or a statement with the mutant in it as well ([mutated] is the
/// syntax tree of the mutated source), the smallest first.
///
/// Left out: a statement that declares a name, what is no value, a
/// constant, what runs once in a process, and what is longer than
/// [longestAlternative].
Places placesOf(
  CompilationUnit unit,
  String source,
  int id,
  Mutant mutant,
  CompilationUnit mutated,
) {
  final growth = mutant.replacement.length - (mutant.end - mutant.offset);
  final after = {
    // A node that starts before the mutant and ends after it holds the
    // place where the mutant starts.
    for (final node in _around(mutated, mutant.offset, mutant.offset))
      (node.offset, node.end, node is Statement, node is Expression),
  };
  final wraps = <Wrap>[];
  var reason = noPlace;
  for (final node in _around(unit, mutant.offset, mutant.end)) {
    final statement = node is Statement && !_declares(node);
    final expression = node is Expression && !_isNoValue(node);
    if (!statement && !expression ||
        !after.contains((
          node.offset,
          node.end + growth,
          statement,
          expression,
        ))) {
      continue;
    }
    if (node.length + growth > longestAlternative) {
      break;
    }
    if (_runsOnce(node)) {
      reason = runsOnce;
      continue;
    }
    if (node is Expression && node.inConstantContext) {
      reason = constantContext;
      continue;
    }
    wraps.add(
      Wrap(
        id,
        node.offset,
        node.end,
        '${source.substring(node.offset, mutant.offset)}'
        '${mutant.replacement}'
        '${source.substring(mutant.end, node.end)}',
        statement: statement,
      ),
    );
  }
  return Places(wraps, reason);
}

class _Types extends GeneralizingAstVisitor<void> {
  final facts = <(int, int), String>{};

  void _note(AstNode node, String fact) => facts.update(
    (node.offset, node.end),
    (before) => '$before, $fact',
    ifAbsent: () => fact,
  );

  @override
  void visitExpression(Expression node) {
    _note(
      node,
      '${node.staticType}'
      '${node is InvocationExpression ? ' by ${node.staticInvokeType}' : ''}',
    );
    super.visitExpression(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    _note(node, 'declares ${node.declaredFragment?.element.type}');
    super.visitVariableDeclaration(node);
  }
}

/// The static types of a resolved [unit], by place: of every expression,
/// with the function type a call is made by, and of every variable.
///
/// Two programs with the same types at the same places are compiled to the
/// same calls, the same inferred type arguments and the same promotions.
Map<(int, int), String> typesOf(CompilationUnit unit) {
  final types = _Types();
  unit.accept(types);
  return types.facts;
}

/// True when the program with the types [other] has, outside the node from
/// [from] to [to] of the program with the types [original], the types that
/// program has.
///
/// [other] is that program with the node replaced by something [growth]
/// longer. With [lead], the node itself is still in it, that far from where
/// it started, and is compared as well; without, what is inside the node is
/// not compared.
bool sameTypesOutside(
  Map<(int, int), String> original,
  Map<(int, int), String> other, {
  required int from,
  required int to,
  required int growth,
  int? lead,
}) {
  for (final MapEntry(key: (offset, end), value: type) in original.entries) {
    final (int, int)? place;
    if (end <= from) {
      place = (offset, end);
    } else if (offset >= to) {
      place = (offset + growth, end + growth);
    } else if (offset >= from && end <= to) {
      place = lead == null ? null : (offset + lead, end + lead);
    } else {
      place = (offset, end + growth);
    }
    if (place != null && other[place] != type) {
      return false;
    }
  }
  return true;
}
