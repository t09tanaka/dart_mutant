# dart_mutant

Mutation testing for Dart and Flutter.

`dart_mutant` changes a source file in one small place at a time (a **mutant**: `+` → `-`, a condition → `true`, `round()` → `floor()`), runs the tests of that file on each, and lists the mutants no test noticed. Those are the places where the code decides something that nothing checks.

- **Mutants from the syntax tree and from resolved types.** Operators, conditions, blocks and literals are found in the syntax tree. Members of `num`, `String`, `Iterable`, `Map`, `DateTime` and `Duration` and the values a function returns are mutated by the types the analyzer resolves, so `first` of your own class is not taken for `Iterable.first`. Numbers and guards on `null` get mutants of their own.
- **Mutants that cannot compile are found before a test is run.** Dart is null-safe and statically typed, so many textbook mutants are not programs. Every mutant is checked by the analyzer in memory, in a few milliseconds; only the ones that compile cost a test run.
- **Nothing to add to your project.** It runs as a program of its own and reads the package the way `dart` and `flutter` do. It does not have to resolve next to your code generators.
- **Several mutants at a time, in copies of the package.** The mutants are put into working copies below `.dart_tool`, one test run in each, so your own files are not written while it runs. A second `dart_mutant` in the same package is turned away instead of getting in the way of the first.
- **A report other tools can read, and a page to look at.** The result is written in the [mutation-testing-elements](https://github.com/stryker-mutator/mutation-testing-elements) JSON schema, and with `--html` as a page that shows every mutant at its place in the source.

```
$ dart_mutant run lib/discount.dart
  lib/discount.dart: 18 of 22 mutant(s) with "dart test --fail-fast --timeout 10s test/discount_test.dart", 3 at a time (4 do not compile)
  lib/discount.dart: 22 mutants / killed 16 / survived 2 / timeout 0 / compile error 4 (4 found before the run) (12.8s)
Survived:
  lib/discount.dart:7:30 NumberLiteral: 0 → 1
  lib/discount.dart:8:39 MethodExpression: round → ceil
dart_mutant: FAILED (22 mutants / killed 16 / survived 2 / timeout 0 / compile error 4 (4 found before the run))
```

(That is [`example/`](example/): no test has a percentage below zero, and none has a price that rounds down.)

## Install

```bash
dart pub global activate dart_mutant
```

That is all: the tool is **not** a dependency of the package it mutates. It needs Dart 3.11 or later to run, and the package has to be resolved (`dart pub get` / `flutter pub get`), because the tool reads `.dart_tool/package_config.json` (of the package, or of the pub workspace above it) to find the package's dependencies and, for a Flutter package, the Dart SDK inside the Flutter SDK.

It can be a `dev_dependency` as well (`dart run dart_mutant run …`), but then its `analyzer` constraint has to resolve next to everything else in the package, which is what running it on its own avoids.

## Usage

```
dart_mutant run [options] <file or glob>... [-- <test command>]
dart_mutant run [options] --plan <plan.json> [-- <test command>]
dart_mutant merge <part.json>... --report <path> [--html <path>]
dart_mutant --version | --help
```

Run it in the package (or name the package with `--root`). `merge` is for a run that was divided with `--shard`, see [A run in several parts](#a-run-in-several-parts---shard-and-merge).

### Which files, and which tests

**Files or globs as arguments.** Paths are relative to the package and written with `/`. Quote a glob so that the tool expands it, not the shell: a glob leaves out test files (`*_test.dart`) and whatever is below a directory that is called `build` or whose name starts with `.`, and does not follow symbolic links to directories.

```bash
dart_mutant run lib/pricing/discount.dart lib/pricing/basket.dart
dart_mutant run 'lib/pricing/**.dart'
```

The tests of `lib/a/b.dart` are `lib/a/b_test.dart` (next to the file) and `test/a/b_test.dart` (the mirror under `test/`). Every one that exists is run. (Outside `lib/` there is no mirror: the test of `bin/tool.dart` is `bin/tool_test.dart`.) A file without a test fails the run: nothing could judge its mutants.

**A plan file.** A JSON file that names the files and, for each, the tests to run on its mutants. Use it when the tests live somewhere else, when a file has several, or when another tool decides the mapping.

```json
{
  "version": 1,
  "targets": [
    { "file": "lib/pricing/discount.dart", "tests": ["test/unit/pricing/discount_test.dart"] },
    { "file": "lib/pricing/basket.dart", "tests": ["test/unit/pricing/basket_test.dart", "test/unit/pricing/basket_totals_test.dart"] }
  ]
}
```

```bash
dart_mutant run --plan mutation-plan.json
```

`file` and `tests` are relative to the package, with `/`, without `.` or `..`. The order of `targets` is the order of the run and of the report (with `--only`, what the report keeps about the other files comes first). With a plan nothing is guessed: only the tests it lists are run, and a file whose `tests` is empty, or names a file that is not there, fails the run.

### Options

| Option            | Meaning                                                                                              |
| ----------------- | ---------------------------------------------------------------------------------------------------- |
| `--root <dir>`    | The package to mutate. Default: the current directory                                                |
| `--plan <file>`   | The plan file (a path as your shell sees it). Not together with files as arguments                   |
| `--only <file>`   | Limit the run to this file of the plan or of the arguments. May be given more than once. A path that is not a file of the run is wrong usage. The report keeps what it says about the other files |
| `--report <path>` | Where the report is written (a path as your shell sees it). Default: `reports/mutation/mutation.json` in the package. A file that is already there is only replaced when it is a report |
| `--html <path>`   | Also write the report as a page for a browser (a path as your shell sees it, ending in `.html`), see [The report as a page](#the-report-as-a-page---html). A file that is already there is only replaced when it is such a page |
| `--force`         | Run every mutant again, see [Results of the last run](#results-of-the-last-run-and---force)          |
| `--jobs <n>`      | How many test runs are started at a time, see [Several mutants at a time](#several-mutants-at-a-time---jobs). Default: a quarter of the processors, at least 1 and at most 4. `1` changes the files in place, one mutant at a time |
| `--shard <i>/<n>` | Run part `i` of `n` of the mutants of each file, see [A run in several parts](#a-run-in-several-parts---shard-and-merge). The report is then a part, not a result |
| `-- <command>`    | The command that runs test files                                                                     |

**The test command** is `flutter test --no-pub` when the pubspec has a dependency from the Flutter SDK, and `dart test` otherwise. A command after `--` replaces it (`-- fvm flutter test --no-pub`). `--fail-fast --timeout 10s` and the test files are appended to it, so it has to be a `dart test` / `flutter test` of some kind. It is started in the package, without a shell.

### What it prints, and the exit code

For each file a line when its tests start (with `, 3 at a time` when the mutants are run in working copies) and a line with the counts, then the survivors (`file:line:column Mutator: original → replacement`; text that spans lines is shown on one), then the totals.

| Exit code       | Meaning                                                                                       |
| --------------- | --------------------------------------------------------------------------------------------- |
| 0               | No mutant survived                                                                            |
| 1               | A mutant survived, or something could not be mutation tested: a file without a test, tests that fail without a mutant, a file that is not there or cannot be parsed, a package that is not resolved, a test command that cannot be started, a page of `--html` that cannot be written (the report is written), another `dart_mutant` at work in the package (nothing is changed then). For `merge`: a mutant survived, or the parts are not all the parts of one run (no report is written then) |
| 2               | Wrong usage: an unknown option, a plan that cannot be read, a glob that matches nothing, a file that is not a `.dart` file inside the package, a `--report` or `--html` that would replace a file of another kind. Nothing is run or changed |
| 130 / 143 / 129 | Interrupted (SIGINT / SIGTERM / SIGHUP); the working copies were removed, or the files were put back, and no report was written |

A run starts by removing the report of the last run (with `--only`: what it says about the files of this run), and the page of `--html` with it, so that a run that writes none cannot be read as a result. A run that is interrupted, or that has to stop (the package is not resolved, the test command cannot be started, a file changed during the run), writes no report and does not list the survivors it had found.

**There is no score threshold.** A percentage says nothing about which decision is unchecked, and a threshold below 100 lets new survivors in unnoticed. The exit code depends on the survivors alone; a tool that wants to allow some of them (an equivalent mutant, with a reason) reads the report and decides for itself. `Timeout` and `CompileError` do not fail the run; the counts show them.

| Status of a mutant | When                                                                                         |
| ------------------ | -------------------------------------------------------------------------------------------- |
| `Killed`           | The test run failed                                                                          |
| `Survived`         | The test run passed                                                                          |
| `Timeout`          | The test run did not end within its limit, see [Time limits](#time-limits)                   |
| `Pending`          | Only in the report of a part (`--shard`): the mutant belongs to another part, and was not evaluated in this one |
| `CompileError`     | The mutant is not a program. Nothing was evaluated. Found by the analyzer before the run (the report has the message as `statusReason`), or, rarely, by the compiler in the test run (the output has `file.dart:12:3: Error:` or `Compilation failed`), see [Limitations](#limitations) |

## Mutators

The name of the mutator is `mutatorName` in the report.

### From the syntax tree

| Mutator                 | Change                                                                                  |
| ----------------------- | --------------------------------------------------------------------------------------- |
| `ArithmeticOperator`    | `+` ↔ `-`, `*` ↔ `/`, `%` → `*`, `~/` → `*`                                              |
| `EqualityOperator`      | `<` → `<=`, `>=`; `<=` → `<`, `>`; `>` → `>=`, `<=`; `>=` → `>`, `<`; `==` ↔ `!=`        |
| `LogicalOperator`       | `&&` ↔ `\|\|`; `a ?? b` → `b`                                                            |
| `ConditionalExpression` | The condition of `if`, `? :` and a collection `if` → `true` and `false` (`(c) \|\| true` and `(c) && false` when it tests for `null` or with `is`); of `while`, `do` and `for` → `false` only |
| `BooleanLiteral`        | `true` ↔ `false`; `!a` → `a`                                                             |
| `UnaryOperator`         | `-a` → `a`                                                                               |
| `UpdateOperator`        | `++` ↔ `--`                                                                              |
| `AssignmentOperator`    | `+=` ↔ `-=`, `*=` ↔ `/=`, `%=` → `*=`, `~/=` → `*=`, `??=` → `=`                         |
| `BlockStatement`        | `{ … }` → `{}`                                                                           |
| `RemoveCall`            | A call whose result is not used (`save(x);`, `await sync();`) → `;`                      |
| `StringLiteral`         | `'text'` → `''`, `''` → `'mutated'`, a string with `${…}` → `''`; adjacent strings (`'a' 'b'`) are one string |
| `ArrayDeclaration`      | `[a, b]` → `[]`                                                                          |

Not made, because the syntax already says they are no use: the emptied body of a function that has to return a value, an arithmetic operator next to a string literal (`'a' + b`, `s += 'x'`), a condition that is a literal (left to `BooleanLiteral`), a call that is the only statement of its block (left to `BlockStatement`), and an emptied block that only says `return;` or `return null;` at the end of a function.

These are the mutators of [`test_gates`](https://pub.dev/packages/test_gates) 0.1.0, and they are a contract: for the same source they give the same mutants, with the same names, places, replacements and order (`test/compat_test.dart` compares the two implementations). In the report they come first, so their ids (`lib/a.dart#0`, `#1`, …) are the ones `test_gates` 0.1.0 gave them.

### From resolved types

| Mutator                 | Change                                                                                  |
| ----------------------- | --------------------------------------------------------------------------------------- |
| `MethodExpression`      | A member is exchanged for its counterpart, or the call is taken away and the receiver stays. See the table below |
| `NumberLiteral`         | `n` → `n + 1`, and `n` → `n - 1` when `n` is above zero                                  |
| `ConstantNumberLiteral` | The same, for a number in the value of a top-level `const` or a `static const` (`const retries = 3;`, `static const wait = Duration(seconds: 5);`). A name of its own, so that a tool that allows mutants can treat named constants apart from numbers in the logic |
| `GuardAlwaysTaken`      | `if (x == null) S` → `if (x == null) S else if (1 == 1) S`: the guard is taken whatever the test says. For an `if` without `else` whose condition tests for `null` or with `is` and whose body leaves (`return`, `throw`, `break`, `continue`) |
| `GuardThrows`           | The body of such a guard → `{ throw StateError('mutant'); }`; and an `a == null` that is an operand of `\|\|` (`a == null \|\| b == null`) → `(a == null && (throw StateError('mutant')))`. The value the guard used to answer for is refused instead |
| `GuardResultSwapped`    | Such a guard directly followed by another `if` without `else` whose body leaves: each gets the body of the other (when the two differ) |
| `BranchCopied`          | `if (x is T) A else B` → `if (x is T) B else B` and `… A else A`; the same for `c ? a : b`. Only where the condition tests for `null` or with `is`, the two branches differ, and the `else` is not an `else if` |
| `ReturnValue`           | In a function, method, getter or closure that may return `null`: `return value` or `=> value` → `null`, and `return null` → `false`, `0`, `0.0` or `'mutated'` where the return type is `bool?`, `int?` / `num?`, `double?` or `String?` |

`MethodExpression`, by the type of the receiver:

| Receiver                | Change                                                                                  |
| ----------------------- | --------------------------------------------------------------------------------------- |
| `num`, `int`, `double`  | `ceil` ↔ `floor`; `round` → `floor`, `ceil`; `toInt` → `round`; `truncate` → `round`; `ceilToDouble` ↔ `floorToDouble`; `roundToDouble` → `floorToDouble`; `isEven` ↔ `isOdd`; `x.abs()` → `x`; `x.clamp(a, b)` → `x` |
| `dart:math`             | `min` ↔ `max`                                                                            |
| `String`                | `startsWith` ↔ `endsWith`; `toUpperCase` ↔ `toLowerCase`; `trimLeft` ↔ `trimRight`; `padLeft` ↔ `padRight`; `indexOf` ↔ `lastIndexOf`; `isEmpty` ↔ `isNotEmpty`; `s.trim()` → `s` |
| `Iterable` (`List`, `Set`, …) | `first` ↔ `last`; `firstOrNull` ↔ `lastOrNull`; `firstWhere` ↔ `lastWhere`; `any` ↔ `every`; `take` ↔ `skip`; `takeWhile` ↔ `skipWhile`; `isEmpty` ↔ `isNotEmpty`; `i.where(f)` → `i`; `i.reversed` → `i` |
| `Map`                   | `containsKey` ↔ `containsValue`; `isEmpty` ↔ `isNotEmpty`                                |
| `DateTime`              | `isBefore` ↔ `isAfter`; `add` ↔ `subtract`; `toUtc` ↔ `toLocal`                          |
| `Duration`              | `inDays` → `inHours` → `inMinutes` → `inSeconds` → `inMilliseconds` → `inMicroseconds` (one step finer) |

The static type of the receiver decides (a type variable counts as its bound), so a member of the same name on a class of yours is left alone, and so is a receiver that is `dynamic`. A member in a cascade (`list..add(1)`) is left alone.

A typed mutant that would make exactly the program another mutant of the file makes is left out (the result of one guard given to the next can be the same text as `return null` → `return 0`).

The guard mutators exist because the syntax mutants of a null check mostly do not compile. After `if (name == null) return …;` the code uses `name` as non-null; with the condition replaced, flipped, or the block emptied, it no longer may. In a file that is mostly null checks, most syntax mutants are compile errors and say nothing about the tests. `GuardAlwaysTaken`, `GuardThrows` and the others ask the same questions in a form that keeps the type promotion.

### Left alone

Annotations, `import` / `export` / `part` / `library` directives, `assert`, and a block that holds assertions only. `if (x case …)` is not given a condition mutant.

There is no way to switch a mutator off, and no comment that hides a mutant. A mutant that cannot be observed (an equivalent mutant) is a survivor; deciding which survivors are acceptable, one by one and with a reason, is for the tool or the person that reads the report.

## Mutants that do not compile

Before a test is run, every mutant of a file is given to `package:analyzer`:

1. The package is opened once, the way the Dart tools open it: `.dart_tool/package_config.json` for the dependencies, and the Dart SDK that file names (`flutterRoot`) for a Flutter package.
2. The file is analyzed as it is. What the compiler refuses in it already is remembered: a file can have such errors without being broken, for example a generated part that is not there yet.
3. For each mutant, the changed content is laid over the file **in memory** and the file is analyzed again. A mutant with more errors of a kind than the file had before is a `CompileError`, with the message as `statusReason`. It stays in the report under its number, and no test is run on it.

Only what the compiler refuses counts (compile-time errors and syntax errors), whatever the package's `analysis_options.yaml` says: it, and the ones in the directories below, are replaced by an empty file for this analysis. `exclude` would hide files, the strict modes (`strict-casts`, …) would refuse what the compiler accepts, and `errors:` can turn a compile error into a hint.

Measured against several hundred syntax mutants of three packages whose test runs had been done one by one (more than a tenth of them compile errors): the analyzer found every one of the compile errors and refused no mutant that compiled, in a few milliseconds each. A compile error found in a test run costs about a second.

## Time limits

Two limits, both fixed:

- **A test gets 10 seconds** (`--timeout 10s`, where the test runner's default is 30). A mutant that makes a test wait for something that never comes fails that test: `Killed`. With `--fail-fast` the run ends at the first failing test.
- **The test run of one mutant gets three times the duration of the run without a mutant, plus 20 seconds.** Only a mutant that keeps the process from ending gets this far: a loop that never yields, so that no timer can fire. It is ended together with the processes it started, and is a `Timeout`.

The run without a mutant gets 10 minutes, and has to pass: otherwise nothing is measured for that file and the run fails.

With more than one job, the run without a mutant is done in every working copy that is used, all at the same time, and the slowest of them is the one that is multiplied by three. The limit is then measured under the load the mutants run under, and the first, slower run in a new copy is not a mutant's. A mutant that still reaches the limit is **run again alone**, when the other runs of the file have ended, with the same limit: it is a `Timeout` only when it does not end then either, and otherwise it gets the status of that second run. A line says how many were run again (`2 mutant(s) did not end within 31s and were run again alone: 1 did not end then either (Timeout)`).

They are not settings. A limit that depends on the machine is what makes a timeout appear on one run and not on the next. A `Timeout` is never taken from the last run: it is measured again every time.

## Results of the last run, and `--force`

The first run tests every mutant. After that a file is run again only when something that decides its result changed:

- the file,
- its test files (which ones, and their content),
- the test command,
- the version of this tool, or of its mutators.

The results are kept in `.dart_tool/dart_mutant/incremental.json` (`.dart_tool` is ignored by git in every Dart project; `flutter clean` removes it, and the next run is a full one). An unchanged file is not even analyzed again, and is in the report as before, with a `duration` of 0.

**A file that the mutated file imports is not part of this.** When `lib/basket.dart` is unchanged and `lib/discount.dart`, which it calls, changed, the results of `basket.dart` are reused as they are. The same goes for a helper that the test imports, for `pubspec.lock`, and for the SDK. `--force` tests everything; use it in CI and before a release.

## Several mutants at a time (`--jobs`)

With `--jobs 2` or more, the mutants are not put into your files. The package is copied, and each copy gets one mutant and one test run at a time:

1. Every mutant is made and checked by the analyzer in the package itself, as with one job. Only the ones that compile are given out.
2. When the first file has mutants to run, the package is copied to `.dart_tool/dart_mutant/work/1`, `…/2`, …: as many copies as there are jobs, or mutants if those are fewer. Nothing is copied when every result is taken from the last run.
3. For each file, the file and its tests are taken from the package as they are now, the tests are run without a mutant in every copy at the same time, and then each copy takes the next mutant of the file, runs the tests on it, and puts the file back.
4. The copies are removed at the end of the run, on an error and on SIGINT / SIGTERM / SIGHUP (the test runs are ended first, with the processes they started). What a run that was killed outright leaves is removed by the next run, before anything else.

**Your working tree is not written.** There is nothing to put back, whatever happens to the run, and an edit during the run cannot collide with a mutant. What the run tests is then a mix, though: each file and its tests as they are when its turn comes, everything else as it was when the copies were made. For a result you want to keep, leave the package alone until the run has ended.

The result does not depend on the number of jobs. The mutants, their numbers and their order in the report are those of a run with one job, and so are the statuses (measured, see [How long it takes](#how-long-it-takes)). The results of the last run are reused across any number of jobs, and `--only`, `--force` and a plan mean what they mean with one job.

**The default** is a quarter of the logical processors, at least 1 and at most 4 (`--jobs 1` on a machine with fewer than 8, 3 on one with 12). A test run is not one thread: the compiler, the test runner and the process that runs the tests are busy at the same time, so one job per processor makes every run slower than it is alone and gains nothing. See the measurements below; give `--jobs` when your machine is different, and in a container whose processors are limited (the number is the one the Dart VM reports, which can be the host's).

**What is not copied.** A directory with one of these names, wherever it is: `.git`, `node_modules`, `Pods`, `.gradle`, `.idea`, `.symlinks`. At the top of the package: `build`, `coverage` and `reports`. A `build` below one of the platform directories (`android`, `ios`, `linux`, `macos`, `web`, `windows`); a `build` elsewhere (`lib/src/build`) is source and is copied. Directly below a `.dart_tool`: `dart_mutant` (the copies are in there), `build` and `flutter_build`. Everything else is copied, with the times of the files: `.dart_tool/package_config.json` (so that no `pub get` is needed in a copy: the package is named in it by a path relative to itself, and the packages of the pub cache and of the SDK by absolute ones), the snapshot of the test runner, generated files (`*.g.dart`), assets, fixtures. A symbolic link is copied as a link; one that points into the package points into the copy. A file of the run that is below a directory that is not copied is put into the copies by itself.

The copies are inside `.dart_tool`, so the analyzer of your editor, `dart analyze`, `dart format` and the test runners do not see them as part of the package, `git` ignores them, and `flutter clean` removes them.

**What cannot be run from a copy is run in place**, one mutant at a time, as with `--jobs 1`, and a line on stderr says why:

- a **pub workspace** (`resolution: workspace`, or the `workspace:` root): its one package configuration is above the package;
- a **`path:` dependency outside the package** (`path: ../shared`): it is written relative to the package, and a copy is somewhere else. A `path:` dependency inside the package (`path: packages/api`) is copied with it and is fine;
- a package inside the package that the package configuration names by an absolute path: a copy would still read it from the package, where no mutant is;
- a **file behind a symbolic link** (only that file): it would be written where the link points to;
- a file whose **tests do not pass in a copy** (only that file): they read a path that is not copied, or an absolute one. The run in place then says whether they pass at all;
- a package that **cannot be copied** (a file that cannot be read, a full disk): that file and the ones after it.

**It costs** one copy of the package per job (without `build/`: a few megabytes to a few tens, well under a second each), and one run of the tests without a mutant per copy and file instead of one per file.

## A run in several parts (`--shard` and `merge`)

One file with many mutants, or with slow tests, takes as long as it takes: `--jobs` is limited by the processors of one machine. `--shard <i>/<n>` divides the mutants of **each file** into `n` parts and runs part `i`, so that `n` machines (the jobs of a CI workflow) can each take one, and `dart_mutant merge` puts their reports together into the report of the whole run.

```
$ dart_mutant run lib/discount.dart --shard 1/2 --report reports/parts/1.json
  lib/discount.dart: 9 of 22 mutant(s) with "dart test --fail-fast --timeout 10s test/discount_test.dart", 3 at a time (2 do not compile)
  lib/discount.dart: 11 of 22 mutants / killed 8 / survived 1 / timeout 0 / compile error 2 (2 found before the run) (7.7s)
Survived:
  lib/discount.dart:7:30 NumberLiteral: 0 → 1
dart_mutant: FAILED (shard 1/2: 11 of 22 mutants / killed 8 / survived 1 / timeout 0 / compile error 2 (2 found before the run))
$ dart_mutant run lib/discount.dart --shard 2/2 --report reports/parts/2.json
  lib/discount.dart: 9 of 22 mutant(s) with "dart test --fail-fast --timeout 10s test/discount_test.dart", 3 at a time (2 do not compile)
  lib/discount.dart: 11 of 22 mutants / killed 8 / survived 1 / timeout 0 / compile error 2 (2 found before the run) (7.7s)
Survived:
  lib/discount.dart:8:39 MethodExpression: round → ceil
dart_mutant: FAILED (shard 2/2: 11 of 22 mutants / killed 8 / survived 1 / timeout 0 / compile error 2 (2 found before the run))
$ dart_mutant merge reports/parts/1.json reports/parts/2.json --report reports/mutation/mutation.json
  lib/discount.dart: 22 mutants / killed 16 / survived 2 / timeout 0 / compile error 4 (4 found before the run)
Survived:
  lib/discount.dart:7:30 NumberLiteral: 0 → 1
  lib/discount.dart:8:39 MethodExpression: round → ceil
dart_mutant: FAILED (2 part(s) merged: 22 mutants / killed 16 / survived 2 / timeout 0 / compile error 4 (4 found before the run))
```

(That is [`example/`](example/) again.)

**Which mutant is in which part.** The mutant with the number `k` of a file (the `k` of its id `lib/a.dart#k`, from 0) belongs to part `k mod n`, plus one: with `--shard 1/4` the mutants 0, 4, 8, …. The numbers are the same in every run of the same source, whatever `--jobs`, the order of the files and the results of the last run are, so every mutant belongs to exactly one part. The syntax mutants come first and the typed ones after them, both in the order of the source, so each part gets its share of every region of the file and of both kinds. A mutant that does not compile is reported by the part it belongs to, like any other; it costs that part no test run.

Every part makes and checks **all** mutants of a file (it has to, to number them), and a part that has a mutant to run first runs the tests without a mutant. That is what a part costs before its first mutant: the same as a whole run. What is divided is the test runs on the mutants. The first line of a file counts the part's own mutants (`9 of 22 mutant(s) … (2 do not compile)`: nine to run, two that do not compile, of 22 in the file).

**The report of a part is not a result.** It is a valid report in the same schema, and it lists every mutant of the file, but the mutants of the other parts have the status `Pending`, and `config.shard` says which part it is:

```json
"config": {"mutatorsVersion": 2, "shard": {"index": 2, "count": 2, "notTested": []}}
```

A tool that judges a report must not pass a `Pending` mutant ([`test_gates`](https://pub.dev/packages/test_gates) fails it: a mutant that was not evaluated proves nothing). The last line of a run with `--shard` says `shard 2/2:` and how many of the mutants were its own. The exit code of a part is about its own mutants only.

### `merge`

```bash
dart_mutant merge <part.json>... --report <path> [--html <path>]
```

reads the reports of the parts `1/n` to `n/n` of one run and writes the report that the run would have written without `--shard`: the same files, mutants, ids, order and statuses (and `duration` as each part measured it). It prints the counts, the survivors and the totals like a run, and its exit code is 0 when no mutant survived and 1 when one did. It needs no package, and runs nothing.

**It refuses parts that are not all the parts of one run**, with exit code 1 and without writing a report (the report and the page that were at `--report` and `--html` are removed before the parts are looked at, so nothing old can be read as the result; wrong usage, exit code 2, changes nothing):

```
$ dart_mutant merge reports/parts/1.json --report reports/mutation/mutation.json
The parts are not the parts of one run:
  - shard 2/2 is missing
dart_mutant: FAILED (nothing was merged)
```

- a file that is not the report of a part (the report of a whole run, or anything else);
- a part that is missing (the first twenty are named), or given twice;
- parts of different divisions (`1/2` and `2/4`);
- a part that was written by another version of this tool or of its mutators than the one that merges;
- parts with different files, another source of a file, or other mutants (a part of another state of the file, or made with other dependencies);
- a mutant that its own part did not evaluate, or that another part gave a status, or a status, a place or a duration that a report of this tool cannot have;
- a file that could not be mutation tested in a part (no test, tests that fail without a mutant, …). Such a file is not in a report, so each part names it in `config.shard.notTested`.

A part that did not run must not pass for mutants that were killed: that is what these checks are for.

**What is not checked: the tests.** A part does not say which test files and which test command it was run with, so parts of the same source that were run with different tests fit together. Run the parts from one commit and with one command; the jobs of one workflow run do.

### With the other options

- `--jobs`: as without `--shard`, within the part.
- `--plan`, files and globs: every part has to be given the same ones. `merge` notices when the files differ.
- `--only`: the part has the files of this run and nothing else. What an earlier report says about other files is not kept in a part, and a run without `--shard` keeps nothing of a part.
- `--force` and the results of the last run: a part reuses the results it finds for its own mutants, and what it leaves in `.dart_tool` says which mutants are still without one, so the parts of one run can also be run one after the other in the same checkout, and a run without `--shard` after them only runs what is left. In CI give `--force`, as for any run there.
- `--html`: the page of a part shows the part (title `Mutation report, shard 2/4`); the other mutants are shown as pending. `merge --html` writes the page of the whole run.
- `--shard 1/1` is the whole run, written as a part.

### In CI

**One part per checkout.** [One run at a time has a package](#one-run-at-a-time-in-a-package), so two parts cannot run side by side in the same directory: the second is turned away. `--shard` is for jobs that each have a checkout of their own. For example with GitHub Actions:

```yaml
jobs:
  part:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        shard: [1, 2, 3, 4]
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
      - run: dart pub get
      - run: dart pub global activate dart_mutant
      # Exit code 1 is a survivor of this part: that is judged below. A part
      # that wrote no report is noticed below as well, because it is missing.
      - run: dart pub global run dart_mutant run --plan mutation-plan.json --force --shard ${{ matrix.shard }}/4 --report part.json || test $? -eq 1
      - uses: actions/upload-artifact@v4
        with:
          name: mutation-part-${{ matrix.shard }}
          path: part.json

  mutation:
    needs: part
    if: always()
    runs-on: ubuntu-latest
    steps:
      - uses: dart-lang/setup-dart@v1
      - run: dart pub global activate dart_mutant
      - uses: actions/download-artifact@v4
        with:
          pattern: mutation-part-*
          path: parts
      - run: dart pub global run dart_mutant merge parts/*/part.json --report mutation.json --html mutation.html
```

The number of parts is in two places there (the matrix and `/4`); `merge` fails when they disagree, or when a job is added to one and not to the other. The last job is the one to require: it fails when a part is missing, and when a mutant survived.

How much it gains depends on what a part costs before its first mutant (the checkout, `pub get`, the analysis of all mutants, the tests without a mutant) against the time of the test runs it takes over. See [How long it takes](#how-long-it-takes) for this package.

## One run at a time in a package

A run takes a lock on `.dart_tool/dart_mutant/lock` before it changes anything: before it removes the report of the last run, and before it puts back what a killed run left. A second `dart_mutant run` in the same package, with any number of jobs, ends with exit code 1 and changes nothing:

```
dart_mutant: another dart_mutant run is at work in this package (pid 4242, started 2026-01-02T03:04:05.678Z). Nothing was run or changed; run again when it has ended (the lock is .dart_tool/dart_mutant/lock)
```

It is a lock of the operating system on that file (`fcntl` on macOS and Linux), which the run holds for as long as it lives. The operating system gives it up when the process ends, however it ends, so a run that was killed never has to be told from a running one by its process id, and no stale lock has to be removed by hand. The process id and the time in the file are only there for the message; the file itself stays. On a file system without such locks (some network mounts) a run does not start, and says that the file cannot be locked.

Wrong usage (exit code 2) is reported without the lock.

## Your files during a run with one job

With `--jobs 1` (the default on a machine with fewer than 8 processors, and what a package that cannot be copied falls back to) the files are changed **in place**, one mutant at a time, one file at a time. Do not edit a file that is being mutated, commit, or switch branches while it runs.

- Before the first mutant goes into a file, the file is copied to `.dart_tool/dart_mutant/backup/<path>`. Every mutant, and the original after it, is put in place by writing a file next to the backups and renaming it over the file, so the file is never half-written. The bytes are put back as they were (line ends, a byte order mark).
- The mutant is taken out after every test run, when the tool itself throws, and on **Ctrl-C (SIGINT), SIGTERM and SIGHUP**: the test run is ended first, with the processes it started, then the file is put back, then the tool exits with 130 / 143 / 129 without a report.
- A run that is killed outright (SIGKILL, power loss) leaves one mutant in one file. The next run takes the lock, puts the file back from the backup before it runs anything, and says so. Until then `git diff` shows the mutant.
- A file is only put back when it is exactly what the run left: each mutant is noted in `.dart_tool/dart_mutant/placed/<path>` before it goes into the file, and the file is compared with that note. When a file is saved by somebody else during the run, or edited after a run was killed, it is left as it is, the run stops with exit code 1, and the message names the backup.
- Putting a file in place by renaming keeps its bytes, not its mode, its extended attributes or its hard links. A file that is a symbolic link is changed where it points to (also when that is outside the package), which has to be on the same file system as the package's `.dart_tool`. A file that is not valid UTF-8 is not touched.
- The backup is in `.dart_tool`: do not run `flutter clean` between a run that was killed and the next run, or the mutant stays in the file unnoticed.

## The report

`reports/mutation/mutation.json` (or `--report`) is written in the [mutation-testing-elements JSON schema](https://github.com/stryker-mutator/mutation-testing-elements/tree/master/packages/report-schema), version 2: the schema the Stryker mutation testing tools write. `dart_mutant` is not one of those tools and is not affiliated with them; it writes the same format so that what reads that format can read this report.

At the top `schemaVersion`, `thresholds`, `framework` (`dart_mutant` and its version) and `config` (`mutatorsVersion`, a number that changes when the mutators would make other mutants of the same source; and `shard` in the report of [a part of a run](#a-run-in-several-parts---shard-and-merge)). For each file: `language` (`dart`), `source` (the file as it was mutated), and for each mutant `id` (`<path>#<number>`), `mutatorName`, `replacement`, `location` (1-based lines and columns, `end` exclusive), `status`, `duration` in milliseconds (0 when no test was run in this run: the mutant does not compile, its result is taken from the last run, or it belongs to another part), and `statusReason` for a compile error the analyzer found. `thresholds` is there because the schema requires it and only colours a viewer; see above for why this tool has none.

The numbers after `#` are stable for the syntax mutators (they come first, in the order of the source). The typed mutants follow, in the order of the source. A tool that keys on a mutant should use `mutatorName`, the replaced text and `replacement`, not the number.

### The report as a page (`--html`)

```bash
dart_mutant run lib/discount.dart --html reports/mutation/mutation.html
```

writes the same report as one HTML file: the list of the files with their counts, and for each file its source with every mutant at its place. A click on a mutant shows the change, its status, and for a mutant that does not compile the message of the analyzer.

The page is shown by the `mutation-test-report-app` element of [`mutation-testing-elements`](https://www.npmjs.com/package/mutation-testing-elements) (Apache-2.0, by the Stryker team). The report is in the page; the element is **not**: the page loads it from `cdn.jsdelivr.net`, in one fixed version and with its hash (subresource integrity), so a browser runs that file or nothing. Opening the page therefore needs a connection to that address. Without one the page says so, and the JSON report next to it is complete.

- The viewer starts with the survivors and the timeouts. `Killed` and `CompileError` are behind the checkboxes above the source.
- The percentages and their colours are the viewer's. This tool has no score and no threshold; the `thresholds` in the report are 100, so everything below is shown as not passed.
- The paths in the list are shown without the directory all files share (`discount.dart` for `lib/discount.dart` when every file is below `lib/`).
- A run with `--html` treats the page as it treats the report: the page of the last run is removed when the run starts, a run that is interrupted or has to stop writes none, and with `--only` the other files stay in it. A run **without** `--html` does not know the page of an earlier run and leaves it where it is, as old as it is; give `--html` every time, or delete the page.

## Limitations

- **Only the mutated file is checked for compile errors.** A mutant that breaks another file is found when the tests are compiled, at the cost of a test run: `ReturnValue` in a function whose callers rely on an inferred type, for example. It is still a `CompileError`, without `statusReason`. In the measurements below it did not happen.
- **Types that cannot be resolved give fewer mutants.** A file whose generated part is missing, or that imports a package that is not resolved, is analyzed as far as it goes; a receiver without a type gets no `MethodExpression`.
- **`DateTime` mutants depend on the time zone.** `toUtc` ↔ `toLocal` cannot be noticed by a test that compares instants, or on a machine (a CI runner) whose zone is UTC.
- **Mutators that often give equivalent mutants.** `NumberLiteral` on a number that only has to be large enough (a buffer size, a number of retries that no test counts), `ConstantNumberLiteral` on a constant that is only passed on, `round` → `ceil` / `floor` and `toInt` → `round` on values that are whole anyway, `trim()` on text that has no blanks, `first` ↔ `last` on a list of one, `inDays` → `inHours` where only the sign is looked at, `toUpperCase` ↔ `toLowerCase` on digits. Of the syntax mutators, a limit that is written out by hand: in `n > max ? max : n` and `n < 1 ? 1 : n`, `>` → `>=` and `<` → `<=` change nothing, and neither does the number next to them in `length > 25 ? length - 25 : 0`; `min` / `max` / `take` say the same without such a mutant. A survivor of these is a question about the tests first, and sometimes the honest answer is that nothing can observe it.
- **Experiments are not enabled.** Because the analysis options are set aside, a package that needs `enable-experiment` is analyzed without it; the errors that gives are in the file before any mutant, so they are not counted against one, but the check is weaker there.
- **The analyzer has to know the SDK of the package.** This version uses `analyzer` 14.5. A package on an SDK with language features that analyzer does not know yet cannot be analyzed until this tool is updated.
- **Windows, and systems without `ps`.** The tool is developed and tested on macOS and Linux. On Windows only SIGINT is delivered, and the command is started through a shell. The processes a test run started are found with `ps`; where there is none (and on Windows) only the test runner itself is ended at a timeout or on a signal, and a test process that it started can be left behind, still running.
- **One test run per mutant.** Every mutant that compiles costs a start of the test runner on the tests of its file; several of them run at the same time, but nothing is shared between them (the mutants are not compiled into one program).
- **Working copies.** Tests that depend on where the package is (an absolute path, a file in a directory that is not copied, a `path:` dependency outside the package, a pub workspace) are run in place, one at a time, see [above](#several-mutants-at-a-time---jobs). The test runs of a run that was killed outright (SIGKILL) can go on until they end by themselves; the copies they run in are removed by the next run.
- **A test that is slow because the machine is busy fails like any other.** A test gets 10 seconds; with many jobs on a machine that is busy with other work, a test that needs seconds already can reach that, and its mutant is `Killed` although it would have survived. The time limit of a whole test run is guarded against this (the mutant is run again alone); the limit of one test is the test runner's. Use fewer jobs if the statuses differ between two runs.

## How long it takes

A mutant that compiles costs one start of the test runner on the tests of its file: about a second for a pure Dart package and one to two seconds for a Flutter package on a quiet machine, more on a busy one. Mutants that do not compile cost milliseconds.

Measured with Dart 3.13 / Flutter 3.47 on a Mac with 12 logical processors (where the default is `--jobs 3`), with `--force`, on three files each of three packages, while the machine was busy with other work:

| Package                              | Mutants   | `--jobs 1`    | `--jobs 3`    |
| ------------------------------------ | --------- | ------------- | ------------- |
| Pure Dart, tests under `test/`       | about 130 | about 2 min   | about 1 min   |
| Flutter app, tests next to the files | about 70  | about 3 min   | about 1 min   |
| Flutter app, tests under `test/`     | about 140 | about 9 min   | about 4 min   |

- **The statuses of every mutant were the same for every number of jobs** that was tried (1, 2, 3, and 4 and 6 in two of the packages), and for the syntax mutators they were those `test_gates` 0.1.0 had found on the same files, mutant by mutant.
- No mutant reached the time limit of its test run, so none had to be run again alone.
- More jobs than a quarter of the processors gained little, and each test run got slower as the jobs went up, which is why the default stops there.

The gates of this package itself (see [Development](#the-gates-of-this-package)), on the same machine and as busy: 11 files, about 1,700 mutants of which about 180 do not compile, about 35 minutes with `--jobs 3`. Nearly all of that is two files: their tests open an analysis session, or run two implementations side by side, and a mutant costs 5 to 8 seconds of a job there, against about a second and a half for the files with plain tests.

A second run without `--force` and without a change takes under a second, and makes no copy.

## Development

```bash
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

The code under `lib/src/` is not an API. What decides something is in pure functions: making the mutants (`syntax_mutators.dart`, `typed_mutators.dart`), numbering them, classifying a test run, building the report and reusing results (`mutation_run.dart`), the parts of a run and putting them together (`shard.dart`, `merge.dart`), the page (`html_report.dart`), the plan and the paths (`plan.dart`), the command line (`args.dart`), the rules of the working copies (`parallel.dart`) and of the lock (`lock_state.dart`). The analysis session, the files, the copies, the lock and the processes are in `lib/src/io/`, and `lib/src/commands/` puts them together (`run.dart`, `merge.dart`).

The tests under `test/commands` start processes (the command line, with a stand-in for the test runner, and once the real `dart test` on `example/`); they carry the tag `process`.

### The gates of this package

The pure files are listed in [`test-gates.json`](test-gates.json) as gates of [`test_gates`](https://pub.dev/packages/test_gates), with what each decides and what a mistake in it costs. What is not listed is in `candidates`, with the reason.

```bash
dart run test_gates check       # each gate has its test and imports nothing impure
dart run test_gates test        # 100% line and branch coverage of every gate
dart run test_gates selfcheck   # with unexecuted code in it, a gate fails
```

The mutation test of the gates is run by this package itself, and judged by `test_gates`:

```bash
dart run tool/self_mutation.dart                              # every gate
dart run tool/self_mutation.dart --gate lib/src/plan.dart     # one gate
dart run tool/self_mutation.dart --force                      # nothing from the last run
```

In the workflow ([`.github/workflows/mutation.yml`](.github/workflows/mutation.yml)) every gate is a job of its own, and the gates whose tests are slow are run in parts (`--shard`), which the last job puts together (`merge`) and judges. Which gates, and into how many parts, is written in one place, `_shards` in the script; the jobs are made from it and from `test-gates.json`:

```bash
dart tool/self_mutation.dart --matrix                                             # the jobs, as JSON
dart run tool/self_mutation.dart --gate lib/src/typed_mutators.dart --shard 1/4   # one part: run, not judged
dart run tool/self_mutation.dart --merge parts                                    # merge the parts of each such gate, and judge
```

The script turns the gates into a plan, runs `dart_mutant run --plan` from this checkout (report: `reports/mutation/mutation.json`, page: `reports/mutation/mutation.html`), and gives the report to `test_gates mutation-result`, which requires every mutant to be killed, not to compile, or to be listed under `equivalentMutants` / `expectedTimeouts` of its gate with a reason. Nothing had to be changed on either side for this: the report of `dart_mutant` is one `test_gates mutation-result` reads.

### The copy of the mutators of `test_gates` 0.1.0

`test/compat/test_gates_0_1_0_mutators.dart` is the file `lib/src/mutators.dart` of [`test_gates`](https://pub.dev/packages/test_gates) 0.1.0 (same author, MIT licence), unchanged below a header that says where it is from. `test/compat_test.dart` runs it and the syntax mutators of this package on the same sources and requires the same mutants. It is kept as it was published: do not edit or reformat it.

## License

MIT
