# Example

A small package to try `dart_mutant` on: one function, and tests that leave two of its decisions unchecked.

```bash
dart pub global activate dart_mutant

cd example
dart pub get
dart_mutant run lib/discount.dart
```

```
  lib/discount.dart: 18 of 22 mutant(s) with "dart test --fail-fast --timeout 10s test/discount_test.dart", 3 at a time (4 do not compile)
  lib/discount.dart: 22 mutants / killed 16 / survived 2 / timeout 0 / compile error 4 (4 found before the run) (12.8s)
Survived:
  lib/discount.dart:7:30 NumberLiteral: 0 → 1
  lib/discount.dart:8:39 MethodExpression: round → ceil
dart_mutant: FAILED (22 mutants / killed 16 / survived 2 / timeout 0 / compile error 4 (4 found before the run))
```

(`, 3 at a time` is what a machine with 12 processors says; see `--jobs`.)

- `0 → 1` in `percent.clamp(0, 100)`: no test has a percentage below zero.
- `round → ceil`: no test has a price that rounds down.
- The four mutants that do not compile are the syntax mutants of `if (cents == null)`: the line after it multiplies `cents`. `GuardAlwaysTaken` and `GuardThrows` test the same guard in a form that compiles, and both are killed.

Add `expect(discounted(1000, -5), 1000);` and `expect(discounted(333, 60), 133);` to `test/discount_test.dart`, and the run passes.

The same run with the tests named in a plan file ([`plan.json`](plan.json)):

```bash
dart_mutant run --plan plan.json
```

The report is in `reports/mutation/mutation.json`. For a page that shows it in a browser, with every mutant at its place in the source:

```bash
dart_mutant run lib/discount.dart --html reports/mutation/mutation.html
```
