#!/usr/bin/env bash
# Compat alias: Opus/Fable keep calling `claude-human-stream`.
# Implementation lives in agent-human-stream.sh (--backend claude).
# Default Opus --effort is medium (Fable → high) unless the caller passes --effort.
set -euo pipefail
SOURCE=${BASH_SOURCE[0]}
while [[ -L "$SOURCE" ]]; do
  DIR=$(cd "$(dirname "$SOURCE")" && pwd)
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
ROOT="$(cd "$(dirname "$SOURCE")" && pwd)"
exec "$ROOT/agent-human-stream.sh" --backend claude "$@"
