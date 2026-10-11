/// One change to a source: the text from [offset] to [end] (exclusive, in
/// UTF-16 code units) becomes [replacement].
class Mutant {
  const Mutant(this.mutator, this.offset, this.end, this.replacement);

  /// The name of the mutator: `mutatorName` in the report.
  final String mutator;
  final int offset;
  final int end;
  final String replacement;

  /// [source] with this change applied.
  String applyTo(String source) =>
      source.replaceRange(offset, end, replacement);
}

/// The syntax mutants of a Dart file, in the order of the source.
class MutantSet {
  const MutantSet({required this.mutants, required this.syntaxErrors});

  final List<Mutant> mutants;

  /// True when the file cannot be read as Dart. [mutants] is then empty.
  final bool syntaxErrors;
}

/// [mutants] in the order of the source. Mutants at the same place keep the
/// order they were found in.
List<Mutant> inSourceOrder(List<Mutant> mutants) {
  final indexed = mutants.indexed.toList()
    ..sort((a, b) {
      final byOffset = a.$2.offset - b.$2.offset;
      return byOffset != 0 ? byOffset : a.$1 - b.$1;
    });
  return [for (final (_, mutant) in indexed) mutant];
}
