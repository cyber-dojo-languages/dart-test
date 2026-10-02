#!/bin/bash
# Set here rather than on the shebang line because the Dockerfile runs this
# as `bash ./install.sh`, which ignores the shebang's options.
set -Eeu -o pipefail

# A kata has no network, so package:test and everything it depends on is
# fetched into the sandbox user's pub cache here, where `dart pub get
# --offline` finds it at every test run.
#
# Two more things are baked in, because a test run starts in a fresh /sandbox
# and anything it writes there is thrown away afterwards:
#
#  - test.snapshot: package:test's runner, compiled. `dart test` builds this
#    into .dart_tool/pub/bin/ the first time it runs in a package, which costs
#    about 2s, so in a fresh sandbox that is every test run.
#  - incremental_kernel.*: the test runner's compiled copy of package:test and
#    a kata-shaped test, which it reads from .dart_tool/test/ to compile only
#    the files that differ. It is read rather than trusted: a learner's edited
#    files are recompiled.
#
# Measured on the build that wrote this: a plain `dart test` in a fresh
# sandbox took about 2400ms, and the cached run below about 280ms.
# The check at the end fails the build if a test run would not be faster.

readonly CACHE_DIR=/home/sandbox/.cache/dart_test
readonly WARM_DIR=/tmp/warm

# Telemetry is on by default, and its first-run notice would land in the
# output of a learner's first test run. The setting is kept under HOME, so
# HOME is the sandbox user's while it is written.
export HOME=/home/sandbox
dart --disable-analytics > /dev/null

# A kata-shaped package, so what is cached is what a kata compiles.
# Must stay in step with the start-point's pubspec.yaml.
mkdir -p "${WARM_DIR}/lib" "${WARM_DIR}/test"
cd "${WARM_DIR}"
cat > pubspec.yaml <<'EOF'
name: hiker
environment:
  sdk: ^3.0.0
dev_dependencies:
  test: any
EOF
cat > lib/hiker.dart <<'EOF'
int answer() => 6 * 9;
EOF
cat > test/hiker_test.dart <<'EOF'
import 'package:hiker/hiker.dart';
import 'package:test/test.dart';

void main() {
  test('life the universe and everything', () {
    expect(answer(), equals(42));
  });
}
EOF

dart pub get

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

# The red kata fails, so a non-zero status is expected from each run.
readonly COLD_START=$(now_ms)
dart test > /dev/null || true
readonly COLD=$(( $(now_ms) - COLD_START ))

mkdir -p "${CACHE_DIR}"
cp .dart_tool/pub/bin/test/test.dart-*.snapshot "${CACHE_DIR}/test.snapshot"
cp .dart_tool/test/incremental_kernel.* "${CACHE_DIR}/"

# What a kata's cyber-dojo.sh does, in a sandbox holding nothing from before.
rm -rf .dart_tool pubspec.lock
dart pub get --offline > /dev/null
mkdir -p .dart_tool/test
cp "${CACHE_DIR}"/incremental_kernel.* .dart_tool/test/
readonly WARM_START=$(now_ms)
dart --packages=.dart_tool/package_config.json "${CACHE_DIR}/test.snapshot" > /dev/null || true
readonly WARM=$(( $(now_ms) - WARM_START ))

echo "Plain dart test: ${COLD}ms, cached: ${WARM}ms"
# A ratio rather than a number of seconds, so the check holds on a slow
# emulated build as well as a native one.
if [ $(( COLD )) -le $(( WARM * 2 )) ]; then
  echo "ERROR: the cache does not make a test run faster" >&2
  exit 42
fi

# The version pub resolved, recorded beside the one the base image wrote.
readonly TEST_VERSION=$(sed --quiet \
  '/^  test:$/,/^    version:/s/^    version: "\(.*\)"$/\1/p' pubspec.lock)
if [ -z "${TEST_VERSION}" ]; then
  echo "ERROR: no version for test in pubspec.lock" >&2
  exit 42
fi
sed --in-place "s/}\$/,\"test\":\"${TEST_VERSION}\"}/" /versions.json
cat /versions.json

cd /
rm -rf "${WARM_DIR}"

# A kata runs as sandbox, and pub writes beside its cache.
chown -R sandbox:sandbox /home/sandbox
du -sm /home/sandbox/.pub-cache "${CACHE_DIR}"
