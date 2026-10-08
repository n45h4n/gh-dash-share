#!/usr/bin/env bash
set -euo pipefail

PROGRAM="${0##*/}"

die() {
	printf 'ERROR: %s: %s\n' "$PROGRAM" "$1" >&2
	exit 1
}

validate_arguments() {
	case "$selected_repo" in
	*/*/* | /* | */ | *[!A-Za-z0-9_./-]*)
		die "invalid repository argument: $selected_repo"
		;;
	esac
	case "$selected_repo" in
	?*/?*) ;;
	*) die "invalid repository argument: $selected_repo" ;;
	esac
	repository_owner="${selected_repo%%/*}"
	repository_name="${selected_repo#*/}"
	case "$repository_owner" in
	-* | *- | *[!A-Za-z0-9-]*) die "invalid repository owner: $repository_owner" ;;
	esac
	case "$repository_name" in
	. | .. | *[!A-Za-z0-9._-]*) die "invalid repository name: $repository_name" ;;
	esac
	[ "${#repository_owner}" -le 39 ] || die "repository owner is too long: $repository_owner"
	[ "${#repository_name}" -le 100 ] || die "repository name is too long: $repository_name"
	case "$issue_number" in
	'' | 0* | *[!0-9]*) die "invalid issue number: $issue_number" ;;
	esac
	[ "${#issue_number}" -le 20 ] || die "issue number is too large: $issue_number"
}

ensure_private_state_directory() {
	if [ -L "$state_directory" ]; then
		die "state directory must not be a symbolic link: $state_directory"
	fi
	if [ -e "$state_directory" ]; then
		[ -d "$state_directory" ] || die "state path is not a directory: $state_directory"
		[ -O "$state_directory" ] || die "state directory is not owned by the current user: $state_directory"
	else
		mkdir -p -- "$state_directory" || die "unable to create state directory: $state_directory"
	fi
	chmod 700 -- "$state_directory" || die "unable to protect state directory: $state_directory"
}

ensure_private_log() {
	local links

	if [ -L "$log_path" ]; then
		die "diagnostic log must not be a symbolic link: $log_path"
	fi
	if [ -e "$log_path" ]; then
		[ -f "$log_path" ] || die "diagnostic log is not a regular file: $log_path"
		[ -O "$log_path" ] || die "diagnostic log is not owned by the current user: $log_path"
		links="$(stat -c '%h' -- "$log_path" 2>/dev/null || stat -f '%l' "$log_path" 2>/dev/null)" ||
			die "unable to inspect diagnostic log link count: $log_path"
		[ "$links" = 1 ] || die "diagnostic log must have link count 1: $log_path"
	else
		(umask 077 && set -o noclobber && : >"$log_path") 2>/dev/null || {
			[ -f "$log_path" ] && [ ! -L "$log_path" ] && [ -O "$log_path" ] ||
				die "unable to create diagnostic log safely: $log_path"
			links="$(stat -c '%h' -- "$log_path" 2>/dev/null || stat -f '%l' "$log_path" 2>/dev/null)" ||
				die "unable to inspect diagnostic log link count: $log_path"
			[ "$links" = 1 ] || die "diagnostic log must have link count 1: $log_path"
		}
	fi
	chmod 600 -- "$log_path" || die "unable to protect diagnostic log: $log_path"
}

lock_and_validate_dispatch_log() {
	python3 - "$log_path" <<'PY'
import fcntl
import os
import stat
import sys

fcntl.flock(9, fcntl.LOCK_SH)
path = os.lstat(sys.argv[1])
opened = os.fstat(9)
safe = (
    stat.S_ISREG(path.st_mode)
    and stat.S_ISREG(opened.st_mode)
    and path.st_uid == opened.st_uid == os.geteuid()
    and path.st_nlink == opened.st_nlink == 1
    and stat.S_IMODE(path.st_mode) == stat.S_IMODE(opened.st_mode) == 0o600
    and (path.st_dev, path.st_ino) == (opened.st_dev, opened.st_ino)
)
raise SystemExit(0 if safe else 1)
PY
}

open_locked_dispatch_log() {
	for _ in 1 2 3; do
		ensure_private_log
		exec 9>>"$log_path" || die "unable to open diagnostic log: $log_path"
		if lock_and_validate_dispatch_log; then
			return 0
		fi
		exec 9>&-
	done
	die "diagnostic log changed identity while being locked: $log_path"
}

[ "$#" -eq 2 ] ||
	die 'usage: gh-dash-codex-issue-dispatch.sh <owner/repository> <issue-number>'

selected_repo="$1"
issue_number="$2"
validate_arguments

for command_name in bash tr mkdir chmod nohup stat python3; do
	command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

dotfiles_directory="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)}"
helper="$dotfiles_directory/scripts/integrations/gh-dash/gh-dash-codex-issue.sh"
[ -f "$helper" ] && [ ! -L "$helper" ] && [ -x "$helper" ] ||
	die "issue helper is not an executable regular file: $helper"
if ! helper_syntax_error="$(bash -n "$helper" 2>&1)"; then
	die "issue helper failed syntax validation: $helper_syntax_error"
fi

umask 077
if [ -n "${XDG_STATE_HOME:-}" ]; then
	state_base="$XDG_STATE_HOME"
else
	[ -n "${HOME:-}" ] || die 'HOME is required when XDG_STATE_HOME is unset'
	state_base="$HOME/.local/state"
fi
case "$state_base" in
/*) ;;
*) die "state base must be an absolute path: $state_base" ;;
esac
state_directory="$state_base/gh-dash-codex-issue"
ensure_private_state_directory

repository_owner_lower="$(printf '%s' "$repository_owner" | LC_ALL=C tr '[:upper:]' '[:lower:]')" ||
	die 'unable to normalize the repository owner'
repository_name_lower="$(printf '%s' "$repository_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')" ||
	die 'unable to normalize the repository name'
repository_identity="repo-${#repository_owner_lower}-${repository_owner_lower}-${#repository_name_lower}-${repository_name_lower}-issue-${issue_number}"
case "$repository_identity" in
'' | *[!a-z0-9._-]*) die 'unable to derive a safe diagnostic-log identity' ;;
esac
log_path="$state_directory/$repository_identity.log"
open_locked_dispatch_log

# Open both redirections synchronously so local failures are visible to gh-dash.
exec 8</dev/null || die 'unable to open /dev/null for the issue helper'
GH_DASH_CODEX_ISSUE_LOG_PATH="$log_path" \
	nohup "$helper" "$@" <&8 >&9 2>&1 &
helper_pid=$!
exec 8<&-
exec 9>&-
[ -n "$helper_pid" ] || die "unable to launch issue helper; see $log_path"

# The child can still fail immediately after this point; its notification and log
# are the diagnostics for that accepted race.
exit 0
