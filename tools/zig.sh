#!/bin/sh
set -eu
bedrock_workspace_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
bedrock_zig_version=$(tr -d '\r\n' < "$bedrock_workspace_root/.zigversion")
exec zvm run "$bedrock_zig_version" "$@"
