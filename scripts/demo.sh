#!/bin/bash
# Shared standalone demo lifecycle; requires PowerShell 7.5 and Azure CLI.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
exec pwsh -NoProfile -File "${script_dir}/Invoke-Demo.ps1" "$@"
