#!/bin/sh
set -eu
# Compatibility entry point; preserve the original positional interface.
bedrock_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec sh "$bedrock_script_dir/test-boot.sh" arm64 "$@"
