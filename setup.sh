#!/usr/bin/env bash
# The installer lives in ClaudeVision/ — this just forwards to it so
# `./setup.sh` works from the repo root too.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ClaudeVision/setup.sh" "$@"
