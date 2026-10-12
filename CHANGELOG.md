# Changelog

## 0.1.1 (not yet published)

`--schemata` is withdrawn: it could report a mutant as killed that survives.

- **What happens.** `dart_mutant run --schemata` is refused with exit code 2
  and a line that says why. Nothing is run. `--no-schemata` is accepted as
  before, and a run without either option does what it did.
- **Why.** With `--schemata`, 0.1.0 ran the tests of a file once per mutant
  in one process. Tests leave things behind in their process (a list that
  was added to, a counter), and when the code under test is what clears
  them (`setUpAll(clearNames)`, a first test that resets), a mutant that
  empties the clearing code changes nothing in a process that has just
  started: it survives a run of its own. In the one process its tests
  started with what the round before had left, failed, and the mutant was
  reported as `Killed`; a run could end with `OK` and exit code 0 where a
  mutant survives. The tests without a mutant, which 0.1.0 ran before and
  after, cannot show this: without a mutant the code that clears is at
  work.
- **Who is affected.** Only results of 0.1.0 from a run that was given
  `--schemata` (experimental, and not the default). A `Killed` from such a
  run is not to be trusted; the other statuses of such a run were measured
  by a run of the mutant on its own, as without the option. A run without
  `--schemata` is not affected, unless it is a run of 0.1.0 that reuses the
  results of one that had the option: 0.1.0 reuses the results of its last
  run whichever way they were measured.
- **What to do.** Run again without `--schemata`. A result of the last run
  is reused while the file, its tests and the test command are the same,
  but not across versions of this tool, so the first run with 0.1.1 tests
  every mutant again. With 0.1.0, give `--force` to that run.
- A run with `--only` keeps what the report says about the other files only
  when this version of the tool, with these mutators, wrote that report.
  Before, a report of any version was kept under the name of the version
  that ran last, so the results of 0.1.0 with `--schemata` could have
  stayed in a report of 0.1.1. `merge` already refused the parts of
  another version.
- The package that shows it is in the tests of this package
  (`test/fixtures/leftover`, `test/commands/leftover_state_test.dart`),
  with what a run of its own for every mutant says about it. The code
  behind the option stays in the package and is not reachable from the
  command line; see "`--schemata` was withdrawn" in the README.

## 0.1.0 (2026-10-12)

First version.

- `dart_mutant run`: mutation test of the files given as arguments (files or
  globs; the tests are the `_test.dart` next to the file or its mirror under
  `test/`), or of the files of a plan (`--plan`, a JSON file that names the
  tests of each file). `--dir`, `--only`, `--report`, `--html`, `--force`,
  `--jobs`, and `-- <command>` for another test command.
- The command line follows `test_gates`: `--dir` for the package, `-h` and
  `-v`, wrong usage answered with the message, an empty line and the help
  (exit code 2), a last line `dart_mutant run: OK (…)` or `FAILED (…)`, and
  a survivor as `file:line:column / Mutator / original → replacement
  (Survived)`.
- A plan file with a key it does not know is refused (exit code 2), as
  `test-gates.json` refuses one: a misspelt key is not silently ignored.
- Syntax mutators: the twelve of `test_gates` 0.1.0, with the same names,
  places, replacements and order.
- Typed mutators, from the types the analyzer resolves: `MethodExpression`,
  `NumberLiteral`, `ConstantNumberLiteral`, `GuardAlwaysTaken`,
  `GuardThrows`, `GuardResultSwapped`, `BranchCopied`, `ReturnValue`.
- Every mutant is checked by the analyzer before a test is run. A mutant
  that does not compile is reported as `CompileError` without a test run.
- The report is written in the mutation-testing-elements JSON schema.
- `--html <path>`: the report as a page for a browser as well. The report
  is in the page, and the viewer (the `mutation-test-report-app` element of
  `mutation-testing-elements`, a fixed version) is loaded from a CDN, with
  its hash, when the page is opened. The path has to end in `.html`, and a
  file that is not such a page is not replaced.
- `--jobs <n>`: several test runs at a time (default: a quarter of the
  processors, at least 1 and at most 4). With more than one job the mutants
  are put into copies of the package below `.dart_tool/dart_mutant/work`,
  and the files of the package are not written. The copies are removed at
  the end, on an error and on SIGINT / SIGTERM / SIGHUP, and by the next
  run after a kill. The mutants and their numbers do not depend on the
  number of jobs, and neither did their statuses in what was measured.
- With more than one job the time limit of a file is measured in every copy
  at the same time, and a mutant that reaches it is run again alone before
  it is reported as `Timeout`.
- A package that cannot be run from a copy (a pub workspace, a `path:`
  dependency outside the package, a package inside it that is named by an
  absolute path, a file behind a symbolic link, tests that only pass in the
  package itself) is run in place, and a line says why.
- A memory limit for the test run of a mutant: twice the most the run
  without a mutant held (the test command and the processes that descend
  from it, as `ps` reports them ten times a second), plus 1 GB. A test run
  that holds more is killed at once with what it started, instead of taking
  the memory of the machine before its time limit ends it. Its mutant is run
  again alone with more than one job, and is a `Timeout` (with the reason as
  `statusReason`) when a limit ends that run as well; with `--schemata` the
  driver is ended and the mutant is run the usual way. Not a setting. Not on
  Windows or where there is no `ps`, and a measurement, not a wall: see
  "Memory limit" in the README.
- With `--jobs 1` the files are mutated in place and put back after every
  mutant, on an error, and on SIGINT / SIGTERM / SIGHUP; what a killed run
  leaves behind is put back by the next run.
- One run at a time in a package: a second `dart_mutant run` ends with exit
  code 1 before it changes anything. The lock is one of the operating
  system, so a killed run leaves none behind.
- The results of a file are reused while the file, its tests and the test
  command are the same (`--force` runs everything).
- `--shard <i>/<n>`: run part `i` of `n` of the mutants of each file (the
  number of the mutant modulo `n`), for a run that is divided over the jobs
  of a CI workflow. The report of a part lists every mutant, the ones of
  the other parts as `Pending`, and says which part it is in `config.shard`.
- `dart_mutant merge <part.json>... --report <path> [--html <path>]`: puts
  the reports of the parts of one run together into the report the run
  would have written without `--shard`. It fails, and writes nothing, when
  a part is missing or given twice, or when the parts are not of the same
  run: another number of parts, other files, sources or mutants, another
  version of the tool or of its mutators, a file that could not be tested.
- The report has `config.mutatorsVersion`.
- (Withdrawn in 0.1.1, see above.) `--schemata` (experimental, not the
  default): the mutants of a file are
  built into the file behind a variable, and its tests are run on all of
  them in one process, by a test file that calls the tests once per mutant.
  The test runner starts once per file instead of once per mutant. Only
  `Killed` is taken from that run, and only while the tests pass without a
  mutant before and after; a mutant no test failed on, one that did not
  end, and what cannot be built in (a constant, an initializer that runs
  once in a process, tests the driver cannot call) are run the usual way.
  Always in working copies. `--no-schemata` is the default, said out loud.
