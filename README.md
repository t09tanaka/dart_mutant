# dart_mutant

[![CI](https://github.com/t09tanaka/dart_mutant/actions/workflows/ci.yml/badge.svg)](https://github.com/t09tanaka/dart_mutant/actions/workflows/ci.yml)

Mutation testing for Dart and Flutter.

`dart_mutant` changes a source file in one small place at a time (a **mutant**: `+` → `-`, a condition → `true`, `round()` → `floor()`), runs the tests of that file on each, and lists the mutants no test noticed. Those are the places where the code decides something that nothing checks.

- **Mutants from the syntax tree and from resolved types.** Operators, conditions, blocks and literals are found in the syntax tree. Members of `num`, `String`, `Iterable`, `Map`, `DateTime` and `Duration` and the values a function returns are mutated by the types the analyzer resolves, so `first` of your own class is not taken for `Iterable.first`. Numbers and guards on `null` get mutants of their own.
- **Mutants that cannot compile are found before a test is run.** Dart is null-safe and statically typed, so many textbook mutants are not programs. Every mutant is checked by the analyzer in memory, in a few milliseconds; only the ones that compile cost a test run.
- **Nothing to add to your project.** It runs as a program of its own and reads the package the way `dart` and `flutter` do. It does not have to resolve next to your code generators.
- **Several mutants at a time, in copies of the package.** The mutants are put into working copies below `.dart_tool`, one test run in each, so your own files are not written while it runs. A second `dart_mutant` in the same package is turned away instead of getting in the way of the first.
- **All mutants of a file in one program, as an option.** With `--schemata` the mutants of a file are built into it behind a variable, and the tests are run on all of them in one process: the test runner starts once per file instead of once per mutant. Experimental, and not the default; see [below](#all-mutants-of-a-file-in-one-program---schemata).
- **A report other tools can read, and a page to look at.** The result is written in the [mutation-testing-elements](https://github.com/stryker-mutator/mutation-testing-elements) JSON schema, and with `--html` as a page that shows every mutant at its place in the source.

```
$ dart_mutant run lib/discount.dart
  lib/discount.dart: 18 of 22 mutant(s) with "dart test --fail-fast --timeout 10s test/discount_test.dart", 3 at a time (4 do not compile)
  lib/discount.dart: 22 mutants / killed 16 / survived 2 / timeout 0 / compile error 4 (4 found before the run) (10.0s)
dart_mutant run: 2 surviving mutant(s)
  - lib/discount.dart:7:30 / NumberLiteral / 0 → 1 (Survived)
  - lib/discount.dart:8:39 / MethodExpression / round → ceil (Survived)
dart_mutant run: FAILED (22 mutants / killed 16 / survived 2 / timeout 0 / compile error 4 (4 found before the run))
```

(That is [`example/`](example/): no test has a percentage below zero, and none has a price that rounds down.)

## Install

> **Not on pub.dev yet.** Until it is, install it from git: `dart pub global activate --source git https://github.com/t09tanaka/dart_mutant`

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

Run it in the package (or name the package with `--dir`). `merge` is for a run that was divided with `--shard`, see [A run in several parts](#a-run-in-several-parts---shard-and-merge).

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

**A key the plan does not have is refused** (exit code 2), with the place and the key (`unknown top-level key "tragets"`, or for `"test"` where `"tests"` was meant):

```
$ dart_mutant run --plan plan.json
dart_mutant: plan.json: targets[0]: unknown key "test"
```

The keys are `version` and `targets`, and in a target `file` and `tests`. It is the reason `test-gates.json` refuses unknown keys: a misspelt key that is silently ignored is a plan that says less than was meant, and the run that follows looks like the full one.

### Options

| Option            | Meaning                                                                                              |
| ----------------- | ---------------------------------------------------------------------------------------------------- |
| `--dir <package>` | The package to mutate. Default: `.`, the current directory                                           |
| `--plan <file>`   | The plan file (a path as your shell sees it). Not together with files as arguments                   |
| `--only <file>`   | Limit the run to this file of the plan or of the arguments. May be given more than once. A path that is not a file of the run is wrong usage. The report keeps what it says about the other files. It is what `--gate` is in `test_gates`; this tool knows no list of gates and is given files, hence `--only` |
| `--report <path>` | Where the report is written (a path as your shell sees it). Default: `reports/mutation/mutation.json` in the package. A file that is already there is only replaced when it is a report |
| `--html <path>`   | Also write the report as a page for a browser (a path as your shell sees it, ending in `.html`), see [The report as a page](#the-report-as-a-page---html). A file that is already there is only replaced when it is such a page |
| `--force`         | Run every mutant again, see [Results of the last run](#results-of-the-last-run-and---force)          |
| `--jobs <n>`      | How many test runs are started at a time, see [Several mutants at a time](#several-mutants-at-a-time---jobs). Default: a quarter of the processors, at least 1 and at most 4. `1` changes the files in place, one mutant at a time |
| `--schemata`      | Experimental. Build the mutants of a file into one program and run its tests on all of them in one process, see [All mutants of a file in one program](#all-mutants-of-a-file-in-one-program---schemata) |
| `--no-schemata`   | One start of the test runner per mutant. The default                                                 |
| `--shard <i>/<n>` | Run part `i` of `n` of the mutants of each file, see [A run in several parts](#a-run-in-several-parts---shard-and-merge). The report is then a part, not a result |
| `-h`, `--help`    | Show the help                                                                                        |
| `-v`, `--version` | Show the version                                                                                     |
| `-- <command>`    | The command that runs test files                                                                     |

**The test command** is `flutter test --no-pub` when the pubspec has a dependency from the Flutter SDK, and `dart test` otherwise. A command after `--` replaces it (`-- fvm flutter test --no-pub`). `--fail-fast --timeout 10s` and the test files are appended to it, so it has to be a `dart test` / `flutter test` of some kind. It is started in the package, without a shell. (With `--schemata` the program that holds all mutants of a file is run with `--timeout 10s --reporter json` instead, so the command has to take those as well.)

### What it prints, and the exit code

For each file a line when its tests start (with `, 3 at a time` when the mutants are run in working copies) and a line with the counts. Then, under a line that counts them (`dart_mutant run: 2 surviving mutant(s)`), the survivors, one line each: `file:line:column / Mutator / original → replacement (Survived)`, the line `test_gates` writes for a mutant (text that spans lines is shown on one). The last line is `dart_mutant run: OK (…)` or `dart_mutant run: FAILED (…)` with the totals, and `dart_mutant merge: …` for `merge`.

The lines of the files and the `OK` line go to stdout. What is wrong goes to stderr: the survivors, a file that could not be mutation tested, the `FAILED` line. Wrong usage is answered with `dart_mutant: <what is wrong>`, an empty line and the help (`--help`); a plan file that cannot be used with the first of these alone, since the help would not say what is wrong with it.

| Exit code       | Meaning                                                                                       |
| --------------- | --------------------------------------------------------------------------------------------- |
| 0               | No mutant survived                                                                            |
| 1               | A mutant survived, or something could not be mutation tested: a file without a test, tests that fail without a mutant, a file that is not there or cannot be parsed, a package that is not resolved, a test command that cannot be started, a page of `--html` that cannot be written (the report is written), another `dart_mutant` at work in the package (nothing is changed then). For `merge`: a mutant survived, or the parts are not all the parts of one run (no report is written then) |
| 2               | Wrong usage, or a plan file that cannot be used: an unknown option, a plan that cannot be read or has a key it does not know, a glob that matches nothing, a file that is not a `.dart` file inside the package, a `--report` or `--html` that would replace a file of another kind. Nothing is run or changed |
| 130 / 143 / 129 | Interrupted (SIGINT / SIGTERM / SIGHUP); the working copies were removed, or the files were put back, and no report was written |

A run starts by removing the report of the last run (with `--only`: what it says about the files of this run), and the page of `--html` with it, so that a run that writes none cannot be read as a result. A run that is interrupted, or that has to stop (the package is not resolved, the test command cannot be started, a file changed during the run), writes no report and does not list the survivors it had found.

**There is no score threshold.** A percentage says nothing about which decision is unchecked, and a threshold below 100 lets new survivors in unnoticed. The exit code depends on the survivors alone; a tool that wants to allow some of them (an equivalent mutant, with a reason) reads the report and decides for itself, see [With `test_gates`](#with-test_gates). `Timeout` and `CompileError` do not fail the run; the counts show them.

| Status of a mutant | When                                                                                         |
| ------------------ | -------------------------------------------------------------------------------------------- |
| `Killed`           | The test run failed                                                                          |
| `Survived`         | The test run passed                                                                          |
| `Timeout`          | The test run did not end within its limit, see [Time limits](#time-limits), or it held more memory than its limit and was ended, see [Memory limit](#memory-limit) (the report then says so as `statusReason`) |
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

## Memory limit

A mutant can make a loop that never ends add to a list on every round (`i++` → `i--` in `[for (var i = 0; i < n; i++) x]`). Such a test run does not wait for its time limit: it takes gigabytes within seconds, and on a machine with less memory than that (a CI runner) the machine is gone before the limit is. So the memory of a test run is limited as well:

- While a test run is at work, the tool asks `ps` ten times a second for the memory of the test command and of every process that descends from it (their resident sets, added up), also during the run without a mutant.
- **The test run of one mutant may hold twice the most the run without a mutant held, plus 1 GB.** With more than one job the run without a mutant is done in every working copy, and the one that held the most counts.
- A test run that holds more is killed at once, with the processes it started. Its mutant is not called `Killed`: like one that reaches the time limit it is **run again alone** when there is more than one job, and it is a `Timeout` when a limit ends that second run as well; otherwise it gets the status of that second run. With one job, and for a file that is run in place, it is a `Timeout` the first time. The report has `the test run used more than … MB of memory and was ended` as its `statusReason`, and a line says how many there were (`1 mutant(s) used more than 2448 MB of memory, were ended and run again alone: 1 reached a limit then as well (Timeout)`).
- With `--schemata` the limit of the program that holds all mutants is made the same way, from what it held while the first position of its plan was at work: until the tests without a mutant were declared for the first time, and again, with everything it held until then, until they had run for the first time. When it holds more with a mutant at work, it is ended, that mutant is run the usual way (which measures it by itself and decides), and another driver is started for the mutants after it. When it holds more while the tests are declared or run without a mutant later in the plan, nothing the drivers of that file reported is used, and every mutant of the file is run the usual way.

Like the time limits it is not a setting, and such a `Timeout` is measured again by every run. What it does not do:

- **It is a measurement ten times a second, not a wall.** A test run that takes memory faster than the machine has left within a tenth of a second is not caught. A test run that the system ends for its memory before the tool does, or that fails by itself for lack of memory, is a failed test run like any other: `Killed`. The loop above is caught: on the machine this was measured on it took about 2 GB a second, and was ended at its limit of 2.4 GB.
- It counts what `ps` reports for the processes that descend from the test command. A process that has left that tree (its parent has ended) is not counted, and neither is memory that belongs to no process (a file in a memory-backed temporary directory). The measurement ends when a test run is told to end for its time limit or on a signal.
- Nothing is limited where there is no `ps`, where it does not answer `ps -A -o pid=,ppid=,rss=` with numbers, and on Windows.
- The limit is per test run. With `--jobs 4`, four runs that go wrong at the same moment hold four times that before they are ended.
- A mutant that makes its tests hold that much more and still pass is a `Timeout`, not the `Survived` it would have been. With less than twice the memory of a whole run of the tests plus a gigabyte no mutant gets there.

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

## All mutants of a file in one program (`--schemata`)

**Experimental, and not the default.** One start of the test runner per mutant is where the time goes: the runner starts, the tests are compiled, and only then do they run. With `--schemata` the mutants of a file are built into the file once, each behind the same variable, and the tests are run on all of them in one process (the technique is known as mutant schemata).

```
$ dart_mutant run --schemata lib/discount.dart
  lib/discount.dart: 18 of 22 mutant(s) built into one program, with "dart test --timeout 10s --reporter json test/dart_mutant_driver_test.dart" (4 do not compile)
  lib/discount.dart: 16 killed with the mutants built in; 2 not killed that way are measured the usual way
  lib/discount.dart: 2 of 22 mutant(s) with "dart test --fail-fast --timeout 10s test/discount_test.dart", 2 at a time
  lib/discount.dart: 22 mutants / killed 16 / survived 2 / timeout 0 / compile error 4 (4 found before the run) (9.0s)
dart_mutant run: 2 surviving mutant(s)
  - lib/discount.dart:7:30 / NumberLiteral / 0 → 1 (Survived)
  - lib/discount.dart:8:39 / MethodExpression / round → ceil (Survived)
dart_mutant run: FAILED (22 mutants / killed 16 / survived 2 / timeout 0 / compile error 4 (4 found before the run))
```

The mutants, their numbers, the report and the exit code are those of a run without the option. **Only `Killed` is ever taken from the one program**; everything else is run the usual way, one start of the test runner per mutant, before it is reported. The rules below are there so that the statuses are the same either way. In what was measured they were, mutant by mutant (see [How long it takes](#how-long-it-takes)); what is not guaranteed is under [What can still go wrong](#what-can-still-go-wrong).

### How a mutant is built in

The smallest expression or statement around a mutant becomes a choice between the mutant and the code that was there. This is a line of [`example/lib/discount.dart`](example/lib/discount.dart) as the tests are run on it, with four of its mutants:

```dart
  final rate = ($dartMutantActive == 11 ? (percent) : (percent.clamp(($dartMutantActive == 12 ? (1) : (0)), ($dartMutantActive == 13 ? (101) : $dartMutantActive == 14 ? (99) : (100)))));
```

- An expression becomes `($dartMutantActive == n ? (mutant) : (original))`, a statement `{ if ($dartMutantActive == n) { mutant } else { original } }`. Several mutants of one node are asked one after the other; a mutant inside the node of another is built into the original of that one.
- `int $dartMutantActive = -1;` is added at the end of the file, so no place in the file moves. It is a variable of the program, set while the program runs. Nothing is passed to the compiler, and nothing is compiled between two mutants.
- **A place is only taken when the program stays what it was.** The analyzer is asked three things about a place before any test runs: the file compiles with the choice there; every expression outside the place has the static type it has in the file as it is (so the code without a mutant at work is compiled to what it was compiled to: the same inferred types, the same promotions, the same calls); and the same holds for the file with the mutant in place (so the code with the mutant at work is that mutant). When the smallest place fails (the condition of a null check would lose its promotion; `var x = a * b` would declare another type with `a / b` next to it), the next larger one is tried: the statement, the block around it, up to 4,000 characters. A statement that declares a name for the statements after it is never a place of its own.

### The driver

The tests are run by a test file that is written next to the tests of the file, **in a working copy** (with any number of jobs; your files are only written for a file that cannot be run from a copy at all, as with `--jobs`): `dart_mutant_driver_test.dart`. It reads a plan, and for every entry it sets the variable, calls `main()` of each test file inside a group of its own, and sets the variable back. The mutant is at work while the tests are declared as well, as it would be in a run of its own: tests that are generated from the code under test are generated from the mutant.

The plan starts with the tests **without a mutant**, repeats them after every 25 mutants, and ends with them. The driver is run with the test command, `--timeout 10s --reporter json`, and the tool reads the result of every test as it comes.

### What is taken from it, and what is not

| What the driver shows for a mutant | What happens |
| ---------------------------------- | ------------ |
| A test failed, and the tests without a mutant passed before it and after it | `Killed`. The other tests of that mutant are not run (the driver is told through a file; a test that had already started still runs) |
| No test failed | Run the usual way, and reported as that run says. A process keeps what it has computed (a `static final`, a cache, a singleton), and it was computed while no mutant was at work: a mutant in that code is never run again in the same process. **`Survived` is always the verdict of a run of its own** |
| Its tests did not end | The limit is that of a run of its own (three times the first run of the tests without a mutant, plus 20 seconds). The driver is ended with the processes it started, the mutant is run the usual way, which decides whether it is a `Timeout`, and another driver is started for the mutants after it. The mutants since the tests last passed without a mutant are run the usual way as well |
| The driver held more memory than its limit while the mutant was at work, see [Memory limit](#memory-limit) | The same: the driver is killed at once, the mutant is run the usual way, which measures it by itself, and another driver is started for the mutants after it |
| The tests fail without a mutant: at the start (they cannot be run this way), or later (a mutant left something behind in the process) | Nothing the drivers of that file reported is used. Every mutant of the file is run the usual way, and a line says which test failed |
| The driver cannot be loaded (a mutant breaks another file, say) | The same |
| Every mutant of the file is killed in the driver | The tests are run once the usual way, without a mutant, before that is believed: test files that only pass together in one process pass in the driver, and are no tests to judge a mutant by |

### What cannot be built in

Run the usual way, and counted in the line of the file (`12 cannot be built in (…)`):

- **A constant.** The element of a `const` list, map, set or record, the default of a parameter, the argument of a `const` constructor, a `case` of a `switch`, a value of an `enum`: a choice made while the program runs is no constant. (Some of them are counted under the next reason, or as "does not compile with a choice there": the line gives the reason as the tool found it.) Where a statement around the constant can take the choice it does (`return const [1, 2];`); in a top-level `const` nothing can.
- **An initializer that runs once in a process**: of a top-level variable or a `static` field, outside every function in it. It runs when the variable is first read, with the mutant that is at work then, and never again.
- A place where every choice changes the program (see above) and no statement around it is small enough.
- A mutant that compiles in the program by itself but not with the mutants that are already in it (`does not compile together with the other mutants`). Two mutants that each take away one of two assignments to a variable are each a program; with both built in, the compiler sees a way on which the variable has no value, although no run ever takes it.
- A whole file: a `part of` file (the driver has to import the file to set the variable), a file that starts with a byte order mark, a file that uses the name `$dartMutantActive`.
- The tests of a file, when the driver cannot call them as the test runner does: no `main()`, a `main` that takes arguments or is `async`, an annotation on the library (`@Timeout`, `@TestOn`, `@Retry`, `@Tags`, `@Skip`: it is for the test runner, which would not see it on the driver), tests in more than one directory, a file that already has the name of the driver, a package with neither `test` nor `flutter_test`. A line on stderr says which.
- A package that cannot be run from a working copy (a pub workspace, a `path:` dependency outside the package): `--schemata` then does nothing, and says so.
- A file whose results are taken from the last run. Only its `Timeout`s are measured again, the usual way.

In what was measured, between none and a bit more than a third of the mutants of a file that compile could not be built in; over all files it was about one in eight. Nearly all of those were in top-level tables of constants.

### With `--jobs`

The drivers run in the working copies of `--jobs`: when a file has more than 25 mutants to build in, they are shared out between up to as many drivers as there are jobs, each in its copy. What is left for the usual way is then run in the same copies, as many at a time as there are jobs. `--jobs 1 --schemata` uses one copy and writes nothing to your files; a file that cannot be run from a copy (behind a symbolic link, or with tests that fail there) is run in place, as with `--jobs`.

`--plan`, `--only`, `--force`, `--report`, `--html`, `--shard`, the results of the last run and the lock mean what they mean without the option. A part of a run (`--shard`) builds in the mutants of that part only, and the parts are put together by `merge` as always. The results of the last run do not say which way they were measured, and are reused either way.

### What can still go wrong

- **A mutant can leave something behind in the process that fails the tests of a later mutant, and that the tests without a mutant do not see.** That later mutant is then reported as `Killed` although its own run would have let it survive. The checks every 25 mutants find what stays and what the tests without a mutant come across. They cannot find what is gone again by then, and they cannot find what only code that a mutant reaches ever reads: a `static final` that is first read with a mutant at work keeps the value that mutant gave it, and the next mutant that gets there reads it. It did not happen in what was measured (see [How long it takes](#how-long-it-takes)). It is the reason this is an option and not the default: a survivor that is reported as killed is the one mistake this tool must not make.
- **The choices are checked one by one.** That the program keeps its static types is asked of every choice alone; of all choices of a file together only that they compile.
- **All test files of a file share one process and one isolate**, one after the other, where the test runner gives each a process of its own. Test files that only pass alone fail the first run without a mutant, and the file is run the usual way.
- **Configuration that is tied to the path of a test file** (`dart_test.yaml` with settings for single paths) does not reach the driver.
- **Code that runs in another isolate** does not see the variable. Its mutants are not killed in the driver and are run the usual way.
- **It does not always pay.** A mutant that survives costs its run in the driver and then a run of its own. A file whose mutants mostly survive, or mostly cannot be built in, takes about as long as without the option; so does a file whose tests take seconds, where the time was never the start of the runner.
- **A test that is slow because the machine is busy** fails as it does without the option; when that is a test without a mutant, the whole file falls back to the usual way.

## A run in several parts (`--shard` and `merge`)

One file with many mutants, or with slow tests, takes as long as it takes: `--jobs` is limited by the processors of one machine. `--shard <i>/<n>` divides the mutants of **each file** into `n` parts and runs part `i`, so that `n` machines (the jobs of a CI workflow) can each take one, and `dart_mutant merge` puts their reports together into the report of the whole run.

```
$ dart_mutant run lib/discount.dart --shard 1/2 --report reports/parts/1.json
  lib/discount.dart: 9 of 22 mutant(s) with "dart test --fail-fast --timeout 10s test/discount_test.dart", 3 at a time (2 do not compile)
  lib/discount.dart: 11 of 22 mutants / killed 8 / survived 1 / timeout 0 / compile error 2 (2 found before the run) (7.9s)
dart_mutant run: 1 surviving mutant(s)
  - lib/discount.dart:7:30 / NumberLiteral / 0 → 1 (Survived)
dart_mutant run: FAILED (shard 1/2: 11 of 22 mutants / killed 8 / survived 1 / timeout 0 / compile error 2 (2 found before the run))
$ dart_mutant run lib/discount.dart --shard 2/2 --report reports/parts/2.json
  lib/discount.dart: 9 of 22 mutant(s) with "dart test --fail-fast --timeout 10s test/discount_test.dart", 3 at a time (2 do not compile)
  lib/discount.dart: 11 of 22 mutants / killed 8 / survived 1 / timeout 0 / compile error 2 (2 found before the run) (8.4s)
dart_mutant run: 1 surviving mutant(s)
  - lib/discount.dart:8:39 / MethodExpression / round → ceil (Survived)
dart_mutant run: FAILED (shard 2/2: 11 of 22 mutants / killed 8 / survived 1 / timeout 0 / compile error 2 (2 found before the run))
$ dart_mutant merge reports/parts/1.json reports/parts/2.json --report reports/mutation/mutation.json
  lib/discount.dart: 22 mutants / killed 16 / survived 2 / timeout 0 / compile error 4 (4 found before the run)
dart_mutant merge: 2 surviving mutant(s)
  - lib/discount.dart:7:30 / NumberLiteral / 0 → 1 (Survived)
  - lib/discount.dart:8:39 / MethodExpression / round → ceil (Survived)
dart_mutant merge: FAILED (2 part(s) merged: 22 mutants / killed 16 / survived 2 / timeout 0 / compile error 4 (4 found before the run))
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
dart_mutant merge: the parts are not the parts of one run
  - shard 2/2 is missing
dart_mutant merge: FAILED (nothing was merged)
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
dart_mutant run: another dart_mutant run is at work in this package (pid 65398, started 2026-10-11T22:29:56.240946Z). Nothing was run or changed; run again when it has ended (the lock is .dart_tool/dart_mutant/lock)
```

It is a lock of the operating system on that file (`fcntl` on macOS and Linux), which the run holds for as long as it lives. The operating system gives it up when the process ends, however it ends, so a run that was killed never has to be told from a running one by its process id, and no stale lock has to be removed by hand. The process id and the time in the file are only there for the message; the file itself stays. On a file system without such locks (some network mounts) a run does not start, and says that the file cannot be locked.

Wrong usage (exit code 2) is reported without the lock.

## Your files during a run with one job

With `--jobs 1` and without `--schemata` (the default on a machine with fewer than 8 processors, and what a package that cannot be copied falls back to) the files are changed **in place**, one mutant at a time, one file at a time. Do not edit a file that is being mutated, commit, or switch branches while it runs.

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

## With `test_gates`

[`test_gates`](https://pub.dev/packages/test_gates) keeps the list and gives the verdict: `test-gates.json` names the files that must not be wrong, and says which surviving mutants are allowed, each with a reason. `dart_mutant` runs the mutants: it is given files and their tests, and knows no list and no allowance. **The two are used together; neither replaces the other.**

What connects them today is the report. `test_gates` 0.1.x has a mutation test of its own (`test_gates mutation`: the twelve syntax mutators, in place, one mutant at a time) and does not start `dart_mutant`. Its `test_gates mutation-result --report <path>` judges any report in the schema this tool writes, so the mutants can be run here and judged there:

1. write the gates and their tests into a [plan file](#which-files-and-which-tests),
2. `dart_mutant run --plan <plan.json> --report <path>` (exit code 1 with a report means that a mutant survived, or that a file could not be mutation tested; which survivors are allowed, and that no gate is missing from the report, is the next step),
3. `test_gates mutation-result --report <path>`.

[This package does that for its own gates](#the-gates-of-this-package), with a script. That `test_gates` starts `dart_mutant` by itself is meant for a later version of it; no published version does.

## Limitations

- **Only the mutated file is checked for compile errors.** A mutant that breaks another file is found when the tests are compiled, at the cost of a test run: `ReturnValue` in a function whose callers rely on an inferred type, for example. It is still a `CompileError`, without `statusReason`. In the measurements below it did not happen.
- **Types that cannot be resolved give fewer mutants.** A file whose generated part is missing, or that imports a package that is not resolved, is analyzed as far as it goes; a receiver without a type gets no `MethodExpression`.
- **`DateTime` mutants depend on the time zone.** `toUtc` ↔ `toLocal` cannot be noticed by a test that compares instants, or on a machine (a CI runner) whose zone is UTC.
- **Mutators that often give equivalent mutants.** `NumberLiteral` on a number that only has to be large enough (a buffer size, a number of retries that no test counts), `ConstantNumberLiteral` on a constant that is only passed on, `round` → `ceil` / `floor` and `toInt` → `round` on values that are whole anyway, `trim()` on text that has no blanks, `first` ↔ `last` on a list of one, `inDays` → `inHours` where only the sign is looked at, `toUpperCase` ↔ `toLowerCase` on digits. Of the syntax mutators, a limit that is written out by hand: in `n > max ? max : n` and `n < 1 ? 1 : n`, `>` → `>=` and `<` → `<=` change nothing, and neither does the number next to them in `length > 25 ? length - 25 : 0`; `min` / `max` / `take` say the same without such a mutant. A survivor of these is a question about the tests first, and sometimes the honest answer is that nothing can observe it.
- **Experiments are not enabled.** Because the analysis options are set aside, a package that needs `enable-experiment` is analyzed without it; the errors that gives are in the file before any mutant, so they are not counted against one, but the check is weaker there.
- **The analyzer has to know the SDK of the package.** This version uses `analyzer` 14.5. A package on an SDK with language features that analyzer does not know yet cannot be analyzed until this tool is updated.
- **Windows, and systems without `ps`.** The tool is developed and tested on macOS and Linux. On Windows only SIGINT is delivered, and the command is started through a shell. The processes a test run started are found with `ps`; where there is none (and on Windows) only the test runner itself is ended at a timeout or on a signal, and a test process that it started can be left behind, still running. The memory of a test run is measured with `ps` as well: there it is not limited, see [Memory limit](#memory-limit).
- **One test run per mutant, unless `--schemata` is given.** Every mutant that compiles costs a start of the test runner on the tests of its file; several of them run at the same time, but nothing is shared between them. With `--schemata` the mutants of a file are compiled into one program; that is experimental, see [What can still go wrong](#what-can-still-go-wrong).
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

The gates of this package itself (see [Development](#the-gates-of-this-package)), on the same machine and as busy, measured when there were eleven of them: 11 files, about 1,700 mutants of which about 180 do not compile, about 35 minutes with `--jobs 3`. Nearly all of that is two files: their tests open an analysis session, or run two implementations side by side, and a mutant costs 5 to 8 seconds of a job there, against about a second and a half for the files with plain tests.

In the workflow of this package (hosted runners of GitHub Actions, `--jobs 2`, one job per gate) the gate with the slowest tests, 544 mutants of which 483 compile, took 54 minutes as one job. Divided with `--shard` into four jobs, each took 9 to 14 minutes, and the whole workflow 16 minutes from start to end. The four parts had 119 to 122 test runs each and still differed that much: one test run cost between 4 and 7 seconds from job to job. The jobs together took a little less time than the one (46 minutes against 54 in these two runs), so dividing cost nothing there; for a file whose mutants take seconds in total, the checkout, `pub get` and the tests without a mutant of every part would outweigh what is gained.

### With `--schemata`

Measured on the same machine on a quieter day, with `--force`: one start of the test runner per mutant with one job and with the default three, and the mutants built in (`--schemata`, three jobs).

| Package                                                   | Mutants   | `--jobs 1`    | `--jobs 3`    | `--jobs 3 --schemata` |
| --------------------------------------------------------- | --------- | ------------- | ------------- | --------------------- |
| [`example/`](example/) of this package, one file          | 22        | 23 s          | 14 s          | 12 s                  |
| Pure Dart, five files                                     | about 340 | about 6 min   | about 2 min   | about 40 s            |
| Flutter app, tests next to the files, five files          | about 145 | about 4 min   | about 2 min   | about 1.5 min         |
| Flutter app, tests under `test/`, five files              | about 165 | about 6 min   | about 2.5 min | about 1.5 min         |
| The gates of this package, 15 files                       | 2,804     | 72 min        | 26 min        | about 10 min          |

- **The statuses of every mutant were the same with and without `--schemata`** in all five, report against report: the same mutants, places and statuses, about 3,000 of them. Two of the five files of each Flutter app are widgets, tested with `testWidgets`.
- Between 85% and 100% of the mutants that compile were built in.
- No mutant was killed in a driver whose tests then failed without a mutant, so no file fell back as a whole. The mutants no test failed on in a driver survived their own run as well; the exception is one file of this package, where a driver was ended at a mutant that did not end and the mutants since its last check were measured again (they were killed).
- **How much it gains depends on what the time was spent on.** The pure Dart files have fast tests and few survivors: nearly all of the time was starts of the test runner, and is gone. In the first Flutter app many of the mutants survive, and every survivor is run again on its own. In this package most of what is left is the mutants in tables of constants, which cannot be built in, on the two files whose tests take seconds.

A second run without `--force` and without a change takes under a second, and makes no copy.

## Development

```bash
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

The code under `lib/src/` is not an API. What decides something is in pure functions: making the mutants (`syntax_mutators.dart`, `typed_mutators.dart`), numbering them, classifying a test run, building the report and reusing results (`mutation_run.dart`), the parts of a run and putting them together (`shard.dart`, `merge.dart`), the page (`html_report.dart`), the plan and the paths (`plan.dart`), the command line (`args.dart`), the rules of the working copies (`parallel.dart`) and of the lock (`lock_state.dart`), where a mutant can be built into its file and what the file is then (`schemata.dart`), and the driver, its plan and what its report means (`driver.dart`). The analysis session, the files, the copies, the lock and the processes are in `lib/src/io/`, and `lib/src/commands/` puts them together (`run.dart`, `merge.dart`; `built_in.dart` for `--schemata`).

The tests under `test/commands` start processes (the command line, with a stand-in for the test runner, and the real `dart test` on `example/` and, for `--schemata`, on a package the test writes); they carry the tag `process`.

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
dart run tool/self_mutation.dart --schemata                   # the mutants of a gate in one program
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

## Related tools

- [test_gates](https://github.com/t09tanaka/test-gates-dart) (pub.dev): gates for Dart and Flutter. A list of the files that must not be wrong, each one pure, covered completely, guarded by a negative control and by a verdict on a mutation report such as the one this tool writes.
- [test-gates](https://github.com/t09tanaka/test-gates) (npm `@t09tanaka/test-gates`): the same gates for JavaScript and TypeScript, with Stryker as the mutation tool.
- [contract-fixtures](https://github.com/t09tanaka/contract-fixtures) (npm and pub.dev): shared request and response fixtures that keep an API and its clients in step.

## License

MIT
