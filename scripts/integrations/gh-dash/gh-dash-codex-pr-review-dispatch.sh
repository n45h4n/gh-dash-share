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
	case "$pr_number" in
	'' | 0* | *[!0-9]*) die "invalid PR number: $pr_number" ;;
	esac
	[ "${#pr_number}" -le 20 ] || die "PR number is too large: $pr_number"
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

file_link_count() {
	local path="$1" links

	if links="$(stat -c '%h' -- "$path" 2>/dev/null)"; then
		:
	else
		links="$(stat -f '%l' "$path" 2>/dev/null)" || return 1
	fi
	case "$links" in
	'' | *[!0-9]*) return 1 ;;
	esac
	printf '%s\n' "$links"
}

ensure_private_log() {
	local links

	if [ -L "$log_path" ]; then
		die "diagnostic log must not be a symbolic link: $log_path"
	fi
	if [ -e "$log_path" ]; then
		[ -f "$log_path" ] || die "diagnostic log is not a regular file: $log_path"
		[ -O "$log_path" ] || die "diagnostic log is not owned by the current user: $log_path"
		links="$(file_link_count "$log_path")" ||
			die "unable to inspect diagnostic log link count: $log_path"
		[ "$links" = 1 ] || die "diagnostic log must have link count 1: $log_path"
	else
		(umask 077 && set -o noclobber && : >"$log_path") 2>/dev/null || {
			[ -f "$log_path" ] && [ ! -L "$log_path" ] && [ -O "$log_path" ] &&
				[ "$(file_link_count "$log_path" 2>/dev/null || true)" = 1 ] ||
				die "unable to create diagnostic log safely: $log_path"
		}
	fi
	chmod 600 -- "$log_path" || die "unable to protect diagnostic log: $log_path"
}

lock_fd_shared() {
	python3 -c 'import fcntl,sys; fcntl.flock(int(sys.argv[1]), fcntl.LOCK_SH)' "$1" 2>/dev/null
}

log_path_matches_fd() {
	python3 -c 'import os,stat,sys
p=os.lstat(sys.argv[1]); f=os.fstat(int(sys.argv[2]))
ok=(stat.S_ISREG(p.st_mode) and stat.S_ISREG(f.st_mode) and
    p.st_uid == f.st_uid == os.geteuid() and p.st_nlink == f.st_nlink == 1 and
    (p.st_mode & 0o777) == (f.st_mode & 0o777) == 0o600 and
    (p.st_dev,p.st_ino) == (f.st_dev,f.st_ino))
raise SystemExit(0 if ok else 1)' "$1" "$2" 2>/dev/null
}

open_shared_locked_log() {
	local attempt

	for ((attempt = 1; attempt <= 10; attempt++)); do
		ensure_private_log
		exec 9>>"$log_path" || die "unable to open diagnostic log: $log_path"
		lock_fd_shared 9 || die "unable to lock diagnostic log: $log_path"
		if log_path_matches_fd "$log_path" 9; then
			return 0
		fi
		exec 9>&-
	done
	die "diagnostic log changed repeatedly while being opened: $log_path"
}

[ "$#" -eq 2 ] || die 'usage: gh-dash-codex-pr-review-dispatch.sh <owner/repository> <pr-number>'

selected_repo="$1"
pr_number="$2"
validate_arguments

for command_name in bash tr mkdir chmod nohup env stat python3; do
	command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

dotfiles_directory="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)}"
helper="$dotfiles_directory/scripts/integrations/gh-dash/gh-dash-codex-pr-review.sh"
[ -f "$helper" ] && [ ! -L "$helper" ] && [ -x "$helper" ] ||
	die "PR review helper is not an executable regular file: $helper"
if ! helper_syntax_error="$(bash -n "$helper" 2>&1)"; then
	die "PR review helper failed syntax validation: $helper_syntax_error"
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
state_directory="$state_base/gh-dash-codex-pr-review"
ensure_private_state_directory

repository_owner_lower="$(printf '%s' "$repository_owner" | LC_ALL=C tr '[:upper:]' '[:lower:]')" ||
	die 'unable to normalize the repository owner'
repository_name_lower="$(printf '%s' "$repository_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')" ||
	die 'unable to normalize the repository name'
repository_identity="repo-${#repository_owner_lower}-${repository_owner_lower}-${#repository_name_lower}-${repository_name_lower}-pr-${pr_number}-review"
case "$repository_identity" in
'' | *[!a-z0-9._-]*) die 'unable to derive a safe diagnostic-log identity' ;;
esac
log_path="$state_directory/$repository_identity.log"
open_shared_locked_log

# Open both redirections synchronously so local failures are visible to gh-dash.
exec 8</dev/null || die 'unable to open /dev/null for the PR review helper'
nohup env GH_DASH_CODEX_PR_REVIEW_BACKEND=1 \
	GH_DASH_CODEX_PR_REVIEW_LOG_PATH="$log_path" \
	"$helper" "$selected_repo" "$pr_number" <&8 >&9 2>&1 &
helper_pid=$!
exec 8<&-
exec 9>&-
[ -n "$helper_pid" ] || die "unable to launch PR review helper; see $log_path"

# The child can still fail immediately after this point; its notification and log
# are the diagnostics for that accepted race.
exit 0
