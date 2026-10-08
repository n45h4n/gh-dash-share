#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
command -v python3 >/dev/null 2>&1 || {
	printf 'FAIL: python3 >= 3.9 is required; run make setup.\n' >&2
	exit 1
}
python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' || {
	printf 'FAIL: python3 >= 3.9 is required by the bundled imports.\n' >&2
	exit 1
}
exec python3 -I -B "$script_directory/doctor.py" "$@"
