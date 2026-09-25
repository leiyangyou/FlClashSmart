#!/usr/bin/env bash
# Runs the Dart checks that the CI dart job runs, in the same order, so a green
# run here means a green job. The workflow calls this script too: edit the
# checks here so the two cannot drift.
#
# Needs flutter and dart on PATH, and yq.
set -euo pipefail

cd "$(dirname "$0")/.."

bash tool/check_commit_msg_test.sh
bash tool/check_comment_density_test.sh

expected=$(shasum -a 256 assets/data/Model.bin | awk '{print $1}')
actual=$(tr -d '[:space:]' < assets/data/Model.bin.sha256)
test "$expected" = "$actual"
echo "model asset hash matches"

bash tool/check_submodules.sh

flutter pub get

# Vendored submodules are not this project's code, and CI checks the repo out
# without them, so they are outside the formatting gate here as well.
dart format --output=none --set-exit-if-changed lib test tool setup.dart

flutter analyze --no-fatal-infos

# The native build hooks compile the Go core and the Rust bridge. That is the
# release build's job, not this one, so disable them for the test run and put
# pubspec.yaml back afterwards.
cp pubspec.yaml pubspec.yaml.ci-backup
restore_pubspec() {
  mv pubspec.yaml.ci-backup pubspec.yaml
}
trap restore_pubspec EXIT

yq -i '.hooks.user_defines.setup.build_assets = false | .hooks.user_defines.rust_api.build_assets = false' pubspec.yaml

flutter test
