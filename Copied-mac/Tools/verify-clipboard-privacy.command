#!/bin/zsh
set -euo pipefail

tool_directory="${0:A:h}"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
exec xcrun --sdk macosx swift -sdk "$sdk_path" "$tool_directory/verify-clipboard-privacy.swift" "$@"
