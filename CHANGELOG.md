## 0.1.0

2026-10-11. The first version.

- `dart_mutant run`: mutation test of the files given as arguments (files or
  globs; the tests are the `_test.dart` next to the file or its mirror under
  `test/`), or of the files of a plan (`--plan`, a JSON file that names the
  tests of each file). `--only`, `--report`, `--html`, `--force`, `--jobs`,
  and `-- <command>` for another test command.
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
- `--schemata` (experimental, not the default): the mutants of a file are
  built into the file behind a variable, and its tests are run on all of
  them in one process, by a test file that calls the tests once per mutant.
  The test runner starts once per file instead of once per mutant. Only
  `Killed` is taken from that run, and only while the tests pass without a
  mutant before and after; a mutant no test failed on, one that did not
  end, and what cannot be built in (a constant, an initializer that runs
  once in a process, tests the driver cannot call) are run the usual way.
  Always in working copies. `--no-schemata` is the default, said out loud.
