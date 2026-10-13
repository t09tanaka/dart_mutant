#!/bin/sh
# The quick check before a push: a few minutes on a machine with cores to
# spare. What it leaves out is run by CI (`dart test`, with the tests that
# start processes, and the gates).
#
#   tool/quick_check.sh
#
# 1. The analyzer and the formatter.
# 2. The tests that start no process (those without the tag `process`).
# 3. The package of test/fixtures/hazards, mutant by mutant: every mutant has
#    the status with the default that `--one-by-one` gives it
#    (the tag `hazards`). `HAZARDS_JOBS` is the `--jobs` of both runs: 6
#    here, 2 without this script.
#
# Not part of it: the same for a Flutter package (the tag `flutter`), which
# needs `flutter` on the PATH and takes several minutes more. CI runs it;
# here it is `dart test --tags flutter`.
set -eu
cd "$(dirname "$0")/.."

dart analyze --fatal-infos
dart format --output=none --set-exit-if-changed .
dart test --exclude-tags process
HAZARDS_JOBS="${HAZARDS_JOBS:-6}" dart test --tags hazards
