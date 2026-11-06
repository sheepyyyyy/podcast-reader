#!/bin/bash
# Runs the test suite with Xcode's toolchain. The Command Line Tools toolchain
# intermittently fails to find the Swift Testing macros.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# The spoken test clips aren't in the repository, so the first run makes them.
if [ ! -f Tests/PodcastReaderCoreTests/Fixtures/sample.mp3 ]; then
    scripts/make-fixtures.sh
fi
exec swift test "$@"
