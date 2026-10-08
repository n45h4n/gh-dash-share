#!/usr/bin/env bash
set -euo pipefail

if [ "${GH_DASH_CODEX_PR_REVIEW_BACKEND:-0}" != 1 ]; then
	script_directory="$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)"
	dispatcher="$script_directory/gh-dash-codex-pr-review-dispatch.sh"
	[ -f "$dispatcher" ] && [ ! -L "$dispatcher" ] && [ -x "$dispatcher" ] || {
		printf 'ERROR: %s: PR review dispatcher is not an executable regular file: %s\n' \
			"${0##*/}" "$dispatcher" >&2
		exit 1
	}
	exec "$dispatcher" "$@"
fi
detached_log_path="${GH_DASH_CODEX_PR_REVIEW_LOG_PATH:-}"
unset GH_DASH_CODEX_PR_REVIEW_BACKEND
unset GH_DASH_CODEX_PR_REVIEW_LOG_PATH

PROGRAM="${0##*/}"
NOTIFICATION_TITLE="gh-dash Codex PR review"
AGENT_START_TOTAL_ATTEMPTS=10
AGENT_START_RETRY_INTERVAL_SECONDS=1
DIAGNOSTIC_RETENTION_SECONDS=604800

pr_lock_owned=0
pr_lock_deferred_signal=
candidate_ref_owned=0
candidate_ref=
candidate_sha=
source_root=

notify() {
	local body="$1" sound="${2:-request}"

	if command -v herdr >/dev/null 2>&1; then
		herdr notification show "$NOTIFICATION_TITLE" --body "$body" --sound "$sound" >/dev/null 2>&1 || true
	fi
}

die() {
	local message="$1"

	printf 'ERROR: %s: %s\n' "$PROGRAM" "$message" >&2
	notify "$message" request
	exit 1
}

prelock_die() {
	printf 'ERROR: %s: %s\n' "$PROGRAM" "$1" >&2
	exit 1
}

worktree_conflict() {
	local detail="$1"

	printf 'ERROR: %s: %s\n' "$PROGRAM" "$detail" >&2
	notify 'PR review worktree conflict; no files were overwritten.' request
	exit 1
}

agent_conflict() {
	local detail="$1"

	printf 'ERROR: %s: %s\n' "$PROGRAM" "$detail" >&2
	notify 'PR review agent identity is ambiguous or conflicting; prompt not sent.' request
	exit 1
}

require_command() {
	local command_name="$1"

	command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
}

require_environment() {
	local variable_name="$1"

	[ -n "${!variable_name-}" ] || die "required environment variable is missing: $variable_name"
}

lowercase() {
	LC_ALL=C tr '[:upper:]' '[:lower:]'
}

is_single_json_object() {
	printf '%s\n' "$1" | jq -e -s \
		'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1
}

capture_json_response() {
	local _capture_destination="$1" _capture_output _capture_status=0
	shift

	_capture_output="$("$@" 2>&1)" || _capture_status=$?
	printf -v "$_capture_destination" '%s' "$_capture_output"
	is_single_json_object "$_capture_output" || return 125
	return "$_capture_status"
}

capture_json() {
	local _capture_destination="$1" _capture_response _capture_status=0
	shift

	capture_json_response _capture_response "$@" || _capture_status=$?
	case "$_capture_status" in
	0) printf -v "$_capture_destination" '%s' "$_capture_response" ;;
	125) die "command did not return exactly one JSON object: $_capture_response" ;;
	*) die "command failed: $_capture_response" ;;
	esac
}

json_has_type() {
	local document="$1" expected_type="$2"

	printf '%s\n' "$document" | jq -e --arg expected_type "$expected_type" \
		'type == "object" and
		 (.id | type == "string" and length > 0) and
		 (has("error") | not) and
		 (.result | type) == "object" and
		 .result.type == $expected_type and
		 ([keys[] | select(. != "id" and . != "result")] | length) == 0' >/dev/null 2>&1
}

json_has_no_error() {
	local document="$1"

	printf '%s\n' "$document" | jq -e '.error == null' >/dev/null 2>&1
}

json_is_error_only() {
	local document="$1" expected_code="$2"

	printf '%s\n' "$document" | jq -e --arg expected_code "$expected_code" \
		'type == "object" and
		 (.id | type == "string" and length > 0) and
		 (has("result") | not) and
		 (.error | type) == "object" and
		 (.error.code | type) == "string" and
		 .error.code == $expected_code and
		 (.error.message | type) == "string" and
		 ([keys[] | select(. != "id" and . != "error")] | length) == 0' >/dev/null 2>&1
}

physical_directory() {
	local directory="$1"

	[ -d "$directory" ] || return 1
	(cd "$directory" && pwd -P)
}

git_common_directory() {
	local worktree_root="$1" common_directory

	common_directory="$(git -C "$worktree_root" rev-parse --git-common-dir 2>/dev/null)" || return 1
	case "$common_directory" in
	/*) ;;
	*) common_directory="$worktree_root/$common_directory" ;;
	esac
	physical_directory "$common_directory"
}

sha256_text() {
	local value="$1" output digest

	if command -v sha256sum >/dev/null 2>&1; then
		output="$(printf '%s' "$value" | sha256sum)" ||
			die 'unable to hash the PR review repository identity with sha256sum'
	elif command -v shasum >/dev/null 2>&1; then
		output="$(printf '%s' "$value" | shasum -a 256)" ||
			die 'unable to hash the PR review repository identity with shasum'
	else
		die 'sha256sum or shasum is required to name the PR review agent'
	fi

	digest="${output%%[[:space:]]*}"
	case "$digest" in
	*[!0-9A-Fa-f]* | '') die 'PR review repository identity hash is not hexadecimal' ;;
	esac
	[ "${#digest}" -eq 64 ] || die 'PR review repository identity hash has an unexpected length'
	printf '%s' "$digest" | lowercase
}

sanitize_agent_alias() {
	local repository="$1" number="$2"
	local normalized_repository component digest suffix available

	normalized_repository="$(printf '%s' "$repository" | lowercase)"
	component="$(printf '%s' "$normalized_repository" | tr '/.' '--' | tr -cs 'a-z0-9_-' '-')"
	component="${component#-}"
	component="${component%-}"
	[ -n "$component" ] || component=repo
	case "$component" in
	[a-z]*) ;;
	*) component="repo-$component" ;;
	esac

	digest="$(sha256_text "$normalized_repository")"
	digest="${digest:0:8}"
	suffix="-p${number}-${digest}"
	available=$((32 - ${#suffix}))
	[ "$available" -ge 1 ] || die 'PR number is too long for a Herdr review agent name'
	component="${component:0:$available}"
	component="${component%-}"
	[ -n "$component" ] || component=r
	printf '%s%s\n' "$component" "$suffix"
}

ensure_private_directory() {
	local directory="$1" label="$2"

	[ ! -L "$directory" ] || prelock_die "$label must not be a symbolic link: $directory"
	if [ -e "$directory" ]; then
		[ -d "$directory" ] || prelock_die "$label is not a directory: $directory"
		[ -O "$directory" ] || prelock_die "$label is not owned by the current user: $directory"
	else
		(umask 077 && mkdir -p -- "$directory") ||
			prelock_die "unable to create $label: $directory"
	fi
	[ ! -L "$directory" ] && [ -d "$directory" ] && [ -O "$directory" ] ||
		prelock_die "$label changed identity while being validated: $directory"
	chmod 700 -- "$directory" || prelock_die "unable to protect $label: $directory"
}

refresh_dispatched_diagnostic_log() {
	local path="$1"

	command -v python3 >/dev/null 2>&1 ||
		die 'python3 is required to refresh dispatched PR review diagnostics'
	if ! python3 - "$path" <<'PY'
import fcntl
import os
import stat
import sys

path = sys.argv[1]
descriptor = 1
stderr_descriptor = 2
locked = False
try:
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    locked = True
    opened = os.fstat(descriptor)
    stderr_opened = os.fstat(stderr_descriptor)
    current = os.lstat(path)
    safe = (
        stat.S_ISREG(opened.st_mode)
        and stat.S_ISREG(stderr_opened.st_mode)
        and stat.S_ISREG(current.st_mode)
        and opened.st_uid == stderr_opened.st_uid == current.st_uid == os.geteuid()
        and opened.st_nlink == stderr_opened.st_nlink == current.st_nlink == 1
        and stat.S_IMODE(opened.st_mode)
        == stat.S_IMODE(stderr_opened.st_mode)
        == stat.S_IMODE(current.st_mode)
        == 0o600
        and (opened.st_dev, opened.st_ino)
        == (stderr_opened.st_dev, stderr_opened.st_ino)
        == (current.st_dev, current.st_ino)
    )
    if not safe:
        raise OSError("diagnostic descriptor and path do not identify one private file")
    os.ftruncate(descriptor, 0)
    os.lseek(descriptor, 0, os.SEEK_END)
finally:
    if locked:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
PY
	then
		die "unable to refresh diagnostic log safely: $path"
	fi
}

prune_inactive_diagnostic_logs() {
	if ! command -v python3 >/dev/null 2>&1; then
		printf 'WARNING: %s: python3 is unavailable; diagnostic retention skipped\n' \
			"$PROGRAM" >&2
		return 0
	fi

	python3 - "$state_directory" "$pr_lock_root" "$DIAGNOSTIC_RETENTION_SECONDS" \
		"$PROGRAM" <<'PY' || {
import errno
import fcntl
import os
import re
import stat
import sys
import time

state_path, lock_root_path, retention_text, program = sys.argv[1:]
uid = os.geteuid()
cutoff = int(time.time()) - int(retention_text)
failures = 0
name_pattern = re.compile(
    r"repo-([1-9][0-9]?)-([a-z0-9-]{1,39})-"
    r"([1-9][0-9]{0,2})-([a-z0-9._-]{1,100})-"
    r"pr-([1-9][0-9]{0,19})-review[.]log"
)


def private_directory(info):
    return (
        stat.S_ISDIR(info.st_mode)
        and info.st_uid == uid
        and stat.S_IMODE(info.st_mode) == 0o700
    )


def private_file(info):
    return (
        stat.S_ISREG(info.st_mode)
        and info.st_uid == uid
        and info.st_nlink == 1
        and stat.S_IMODE(info.st_mode) == 0o600
    )


def identity_from_name(name):
    matched = name_pattern.fullmatch(name)
    if matched is None:
        return None
    owner_length, owner, repository_length, repository, number = matched.groups()
    if (
        int(owner_length) != len(owner)
        or int(owner_length) > 39
        or owner.startswith("-")
        or owner.endswith("-")
        or int(repository_length) != len(repository)
        or int(repository_length) > 100
        or repository in (".", "..")
    ):
        return None
    identity = (
        f"repo-{len(owner)}-{owner}-{len(repository)}-{repository}-"
        f"pr-{number}-review"
    )
    return identity if name == f"{identity}.log" else None


directory_flags = os.O_RDONLY | os.O_NONBLOCK | os.O_DIRECTORY | os.O_NOFOLLOW
file_flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW
if hasattr(os, "O_CLOEXEC"):
    directory_flags |= os.O_CLOEXEC
    file_flags |= os.O_CLOEXEC


def open_private_directory(name, parent_fd):
    opened = os.open(name, directory_flags, dir_fd=parent_fd)
    details = os.fstat(opened)
    current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if (
        not private_directory(details)
        or not private_directory(current)
        or (details.st_dev, details.st_ino) != (current.st_dev, current.st_ino)
    ):
        os.close(opened)
        raise OSError("unsafe directory")
    return opened, details


def identity_is_definitely_inactive(identity, lock_root_fd):
    lock_name = f"{identity}.lock"
    try:
        lock_details = os.stat(lock_name, dir_fd=lock_root_fd, follow_symlinks=False)
    except FileNotFoundError:
        return True
    if not private_directory(lock_details):
        return False

    lock_fd = owner_fd = None
    try:
        lock_fd, opened_lock = open_private_directory(lock_name, lock_root_fd)
        if os.listdir(lock_fd) != ["owner"]:
            return False
        owner_fd = os.open("owner", file_flags, dir_fd=lock_fd)
        owner_details = os.fstat(owner_fd)
        current_owner = os.stat("owner", dir_fd=lock_fd, follow_symlinks=False)
        if (
            not private_file(owner_details)
            or not private_file(current_owner)
            or (owner_details.st_dev, owner_details.st_ino)
            != (current_owner.st_dev, current_owner.st_ino)
        ):
            return False
        data = os.read(owner_fd, 256)
        owner = re.fullmatch(
            rb"([1-9][0-9]{0,19})\n([0-9]{1,20})\n", data
        )
        if owner is None:
            return False
        try:
            os.kill(int(owner.group(1)), 0)
        except ProcessLookupError:
            pass
        except (OverflowError, PermissionError, OSError):
            return False
        else:
            return False
        current_lock = os.stat(lock_name, dir_fd=lock_root_fd, follow_symlinks=False)
        current_owner = os.stat("owner", dir_fd=lock_fd, follow_symlinks=False)
        if (
            os.listdir(lock_fd) != ["owner"]
            or (opened_lock.st_dev, opened_lock.st_ino)
            != (current_lock.st_dev, current_lock.st_ino)
            or (owner_details.st_dev, owner_details.st_ino)
            != (current_owner.st_dev, current_owner.st_ino)
        ):
            return False
        return True
    except (FileNotFoundError, NotADirectoryError, OSError):
        return False
    finally:
        if owner_fd is not None:
            os.close(owner_fd)
        if lock_fd is not None:
            os.close(lock_fd)


state_fd = lock_root_fd = None
try:
    state_fd = os.open(state_path, directory_flags)
    lock_root_fd = os.open(lock_root_path, directory_flags)
    if not private_directory(os.fstat(state_fd)) or not private_directory(
        os.fstat(lock_root_fd)
    ):
        raise OSError("unsafe retention root")

    for name in os.listdir(state_fd):
        identity = identity_from_name(name)
        if identity is None:
            continue
        descriptor = None
        try:
            descriptor = os.open(name, file_flags, dir_fd=state_fd)
            opened = os.fstat(descriptor)
            if not private_file(opened):
                failures += 1
                continue
            if opened.st_mtime >= cutoff:
                continue
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                if error.errno not in (errno.EACCES, errno.EAGAIN):
                    failures += 1
                continue

            if not identity_is_definitely_inactive(identity, lock_root_fd):
                continue
            current = os.stat(name, dir_fd=state_fd, follow_symlinks=False)
            if (
                not private_file(current)
                or (opened.st_dev, opened.st_ino)
                != (current.st_dev, current.st_ino)
                or current.st_mtime >= cutoff
            ):
                continue
            os.unlink(name, dir_fd=state_fd)
        except FileNotFoundError:
            continue
        except (NotADirectoryError, OSError):
            failures += 1
        finally:
            if descriptor is not None:
                os.close(descriptor)
except (NotADirectoryError, OSError, ValueError):
    failures += 1
finally:
    if lock_root_fd is not None:
        os.close(lock_root_fd)
    if state_fd is not None:
        os.close(state_fd)

if failures:
    print(
        f"WARNING: {program}: skipped {failures} unsafe or "
        "unreadable PR diagnostic retention candidate(s)",
        file=sys.stderr,
    )
PY
		printf 'WARNING: %s: diagnostic retention failed; cleanup skipped\n' \
			"$PROGRAM" >&2
	}
	return 0
}

# shellcheck disable=SC2329 # Invoked through cleanup's EXIT trap.
release_pr_lock() {
	[ "$pr_lock_owned" -eq 1 ] || return 0
	rm -f -- "$pr_lock_owner" 2>/dev/null || true
	rmdir -- "$pr_lock_directory" 2>/dev/null || true
	pr_lock_owned=0
}

release_candidate_ref() {
	local expected_sha

	[ "$candidate_ref_owned" -eq 1 ] || return 0
	expected_sha="$candidate_sha"
	if [ -z "$expected_sha" ]; then
		expected_sha="$(git -C "$source_root" rev-parse --verify "$candidate_ref" 2>/dev/null)" || {
			candidate_ref_owned=0
			return 0
		}
	fi
	if ! git -C "$source_root" update-ref -d "$candidate_ref" "$expected_sha" >/dev/null 2>&1; then
		printf 'WARNING: %s: unable to remove temporary PR-head ref %s\n' \
			"$PROGRAM" "$candidate_ref" >&2
		return 1
	fi
	candidate_ref_owned=0
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
	local original_status=$?

	trap - EXIT
	release_candidate_ref || true
	release_pr_lock
	exit "$original_status"
}

pr_locked() {
	local message

	message='PR review operation is locked. If no PR review helper is running, remove the stale lock manually and press I again.'
	printf 'ERROR: %s: %s\nLock path: %s\n' \
		"$PROGRAM" "$message" "$pr_lock_directory" >&2
	notify "$message" request
	exit 1
}

# shellcheck disable=SC2329 # Invoked by temporary signal traps while acquiring the lock.
defer_pr_lock_signal() {
	[ -n "$pr_lock_deferred_signal" ] || pr_lock_deferred_signal="$1"
}

acquire_pr_lock() {
	local lock_status=0 now

	ensure_private_directory "$state_directory" 'workflow state directory'
	ensure_private_directory "$pr_lock_root" 'PR review lock parent directory'

	pr_lock_deferred_signal=
	trap 'defer_pr_lock_signal INT' INT
	trap 'defer_pr_lock_signal TERM' TERM
	trap 'defer_pr_lock_signal HUP' HUP
	(umask 077 && mkdir -- "$pr_lock_directory") 2>/dev/null || lock_status=$?
	if [ "$lock_status" -eq 0 ]; then
		pr_lock_owned=1
	fi
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
	case "$pr_lock_deferred_signal" in
	INT) exit 130 ;;
	TERM) exit 143 ;;
	HUP) exit 129 ;;
	esac
	[ "$lock_status" -eq 0 ] || pr_locked
	chmod 700 -- "$pr_lock_directory" || die 'unable to protect the PR review lock'
	now="$(date +%s)" || die 'unable to capture the PR review lock timestamp'
	case "$now" in
	'' | *[!0-9]*) die 'the system returned an invalid PR review lock timestamp' ;;
	esac
	(umask 077 && printf '%s\n%s\n' "$$" "$now" >"$pr_lock_owner") ||
		die 'unable to record the PR review lock owner'
}

capture_source_repo_json() {
	local _destination="$1" _output _status=0

	_output="$(cd "$source_root" && env -u GH_REPO gh repo view --json nameWithOwner,sshUrl 2>&1)" || _status=$?
	is_single_json_object "$_output" ||
		die "source repository lookup did not return exactly one JSON object: $_output"
	[ "$_status" -eq 0 ] || die "unable to resolve the source GitHub repository: $_output"
	printf -v "$_destination" '%s' "$_output"
}

validate_fetch_url() {
	local url="$1" expected_repository_lower="$2"
	local remainder host path path_lower

	case "$url" in
	git@*:*)
		remainder="${url#git@}"
		host="${remainder%%:*}"
		path="${remainder#*:}"
		;;
	ssh://git@*/*)
		remainder="${url#ssh://git@}"
		host="${remainder%%/*}"
		path="${remainder#*/}"
		;;
	*) die 'the canonical repository SSH URL uses an unsupported transport' ;;
	esac
	case "$host" in
	'' | -* | *- | .* | *. | *[!A-Za-z0-9.-]*)
		die 'the canonical repository SSH URL has an invalid host'
		;;
	esac
	case "$path" in
	.git | */ | /* | *[!A-Za-z0-9_./-]*)
		die 'the canonical repository SSH URL has an invalid repository path'
		;;
	esac
	path="${path%.git}"
	path_lower="$(printf '%s' "$path" | lowercase)"
	[ "$path_lower" = "$expected_repository_lower" ] ||
		die 'the canonical repository SSH URL does not match the selected repository'
}

validate_commit_id() {
	local commit_id="$1" label="$2"

	case "$commit_id" in
	*[!0-9A-Fa-f]* | '') die "$label is not a hexadecimal commit ID" ;;
	esac
	case "${#commit_id}" in
	40 | 64) ;;
	*) die "$label must contain 40 or 64 hexadecimal characters" ;;
	esac
}

[ "$#" -eq 2 ] || prelock_die 'usage: gh-dash-codex-pr-review.sh <owner/repository> <pr-number>'

selected_repo="$1"
pr_number="$2"

case "$selected_repo" in
*/*/* | /* | */ | *[!A-Za-z0-9_./-]*)
	prelock_die "invalid repository argument: $selected_repo"
	;;
esac
case "$selected_repo" in
?*/?*) ;;
*) prelock_die "invalid repository argument: $selected_repo" ;;
esac
repository_owner="${selected_repo%%/*}"
repository_name="${selected_repo#*/}"
case "$repository_owner" in
-* | *- | *[!A-Za-z0-9-]*) prelock_die "invalid repository owner: $repository_owner" ;;
esac
case "$repository_name" in
. | .. | *[!A-Za-z0-9._-]*) prelock_die "invalid repository name: $repository_name" ;;
esac
[ "${#repository_owner}" -le 39 ] || prelock_die "repository owner is too long: $repository_owner"
[ "${#repository_name}" -le 100 ] || prelock_die "repository name is too long: $repository_name"
case "$pr_number" in
'' | 0* | *[!0-9]*) prelock_die "invalid PR number: $pr_number" ;;
esac
[ "${#pr_number}" -le 20 ] || prelock_die "PR number is too large: $pr_number"

for command_name in tr mkdir rmdir rm date chmod sleep; do
	command -v "$command_name" >/dev/null 2>&1 ||
		prelock_die "required command not found: $command_name"
done

repository_owner_lower="$(printf '%s' "$repository_owner" | lowercase)" ||
	prelock_die 'unable to normalize the repository owner'
repository_name_lower="$(printf '%s' "$repository_name" | lowercase)" ||
	prelock_die 'unable to normalize the repository name'
selected_repo_lower="$repository_owner_lower/$repository_name_lower"
lock_identity="repo-${#repository_owner_lower}-${repository_owner_lower}-${#repository_name_lower}-${repository_name_lower}-pr-${pr_number}-review"
case "$lock_identity" in
'' | *[!a-z0-9._-]*) prelock_die 'unable to derive a safe PR review lock identity' ;;
esac

if [ -n "${XDG_STATE_HOME:-}" ]; then
	state_base="$XDG_STATE_HOME"
else
	[ -n "${HOME:-}" ] || prelock_die 'HOME is required when XDG_STATE_HOME is unset'
	state_base="$HOME/.local/state"
fi
case "$state_base" in
/*) ;;
*) prelock_die "state base must be an absolute path: $state_base" ;;
esac
state_directory="$state_base/gh-dash-codex-pr-review"
pr_lock_root="$state_directory/locks"
pr_lock_directory="$pr_lock_root/$lock_identity.lock"
pr_lock_owner="$pr_lock_directory/owner"
diagnostic_log_path="$state_directory/$lock_identity.log"

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
acquire_pr_lock
if [ -n "$detached_log_path" ]; then
	[ "$detached_log_path" = "$diagnostic_log_path" ] ||
		die 'dispatcher diagnostic log path does not match the PR review identity'
	refresh_dispatched_diagnostic_log "$diagnostic_log_path"
fi
prune_inactive_diagnostic_logs

for command_name in git gh herdr jq codex; do
	require_command "$command_name"
done

source_environment_count=0
for variable_name in \
	GH_DASH_SOURCE_ROOT \
	GH_DASH_SOURCE_REPO \
	GH_DASH_SOURCE_BRANCH \
	GH_DASH_SOURCE_SHA \
	GH_DASH_SOURCE_DIRTY; do
	[ -z "${!variable_name+x}" ] || source_environment_count=$((source_environment_count + 1))
done

if [ "$source_environment_count" -eq 0 ]; then
	GH_DASH_SOURCE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ||
		die 'unable to capture a source Git worktree from the current directory'
	GH_DASH_SOURCE_ROOT="$(physical_directory "$GH_DASH_SOURCE_ROOT")" ||
		die 'unable to resolve the captured source root'
	GH_DASH_SOURCE_BRANCH="$(git -C "$GH_DASH_SOURCE_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null)" ||
		die 'detached source HEAD is not supported'
	GH_DASH_SOURCE_SHA="$(git -C "$GH_DASH_SOURCE_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" ||
		die 'unable to resolve the current source commit'
	GH_DASH_SOURCE_REPO="$selected_repo"
	if source_status="$(git -C "$GH_DASH_SOURCE_ROOT" status --porcelain --untracked-files=normal 2>/dev/null)"; then
		if [ -n "$source_status" ]; then
			GH_DASH_SOURCE_DIRTY=1
		else
			GH_DASH_SOURCE_DIRTY=0
		fi
	else
		die 'unable to inspect the source checkout state'
	fi
	export \
		GH_DASH_SOURCE_ROOT \
		GH_DASH_SOURCE_REPO \
		GH_DASH_SOURCE_BRANCH \
		GH_DASH_SOURCE_SHA \
		GH_DASH_SOURCE_DIRTY
fi

for variable_name in \
	GH_DASH_SOURCE_ROOT \
	GH_DASH_SOURCE_REPO \
	GH_DASH_SOURCE_BRANCH \
	GH_DASH_SOURCE_SHA \
	GH_DASH_SOURCE_DIRTY; do
	require_environment "$variable_name"
done
case "$GH_DASH_SOURCE_DIRTY" in
0 | 1) ;;
*) die 'GH_DASH_SOURCE_DIRTY must be 0 or 1' ;;
esac
validate_commit_id "$GH_DASH_SOURCE_SHA" 'GH_DASH_SOURCE_SHA'

for variable_name in HERDR_SOCKET_PATH HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID; do
	require_environment "$variable_name"
done

[ -d "$GH_DASH_SOURCE_ROOT" ] || die "source root does not exist: $GH_DASH_SOURCE_ROOT"
source_root="$(physical_directory "$GH_DASH_SOURCE_ROOT")" || die 'unable to resolve the source root'
git_root="$(git -C "$source_root" rev-parse --show-toplevel 2>/dev/null)" ||
	die "source root is not a Git worktree: $source_root"
git_root="$(physical_directory "$git_root")" || die 'unable to resolve the Git worktree root'
[ "$git_root" = "$source_root" ] || die "captured source root does not match the Git root: $source_root"
source_common_directory="$(git_common_directory "$source_root")" ||
	die 'unable to resolve the source Git common directory'

git -C "$source_root" check-ref-format --branch "$GH_DASH_SOURCE_BRANCH" >/dev/null 2>&1 ||
	die "invalid captured source branch: $GH_DASH_SOURCE_BRANCH"
git -C "$source_root" cat-file -e "${GH_DASH_SOURCE_SHA}^{commit}" 2>/dev/null ||
	die "captured source commit is unavailable: $GH_DASH_SOURCE_SHA"

captured_repo_lower="$(printf '%s' "$GH_DASH_SOURCE_REPO" | lowercase)"
[ "$selected_repo_lower" = "$captured_repo_lower" ] ||
	die "selected pull request repository $selected_repo does not match captured repository $GH_DASH_SOURCE_REPO"

if [ "$GH_DASH_SOURCE_DIRTY" -eq 1 ]; then
	printf 'WARNING: %s: the source checkout is dirty; it will not be modified\n' "$PROGRAM" >&2
fi

source_repository_json=
capture_source_repo_json source_repository_json
printf '%s\n' "$source_repository_json" | jq -e \
	'type == "object" and
	 (.nameWithOwner | type == "string" and length > 0) and
	 (.sshUrl | type == "string" and length > 0)' >/dev/null 2>&1 ||
	die 'the source GitHub repository response is malformed'
current_repo="$(printf '%s\n' "$source_repository_json" | jq -r '.nameWithOwner')"
fetch_url="$(printf '%s\n' "$source_repository_json" | jq -r '.sshUrl')"
current_repo_lower="$(printf '%s' "$current_repo" | lowercase)"
[ "$selected_repo_lower" = "$current_repo_lower" ] ||
	die "selected pull request repository $selected_repo does not match source repository $current_repo"
[ "$captured_repo_lower" = "$current_repo_lower" ] ||
	die "captured repository $GH_DASH_SOURCE_REPO does not match source repository $current_repo"
validate_fetch_url "$fetch_url" "$current_repo_lower"

status_json=
capture_json status_json herdr status --json
if ! json_has_no_error "$status_json" ||
	! printf '%s\n' "$status_json" | jq -e \
		'.server.running == true and .server.compatible == true' >/dev/null 2>&1; then
	die 'the inherited Herdr server is not running or is incompatible'
fi

source_workspace_json=
capture_json source_workspace_json herdr workspace get "$HERDR_WORKSPACE_ID"
if ! json_has_type "$source_workspace_json" workspace_info ||
	! printf '%s\n' "$source_workspace_json" | jq -e --arg workspace_id "$HERDR_WORKSPACE_ID" \
		'.result.workspace.workspace_id == $workspace_id' >/dev/null 2>&1; then
	die 'the inherited Herdr workspace is not active'
fi

source_tab_json=
capture_json source_tab_json herdr tab get "$HERDR_TAB_ID"
if ! json_has_type "$source_tab_json" tab_info ||
	! printf '%s\n' "$source_tab_json" | jq -e \
		--arg tab_id "$HERDR_TAB_ID" \
		--arg workspace_id "$HERDR_WORKSPACE_ID" \
		'.result.tab.tab_id == $tab_id and
		 .result.tab.workspace_id == $workspace_id' >/dev/null 2>&1; then
	die 'the inherited Herdr tab does not belong to the active workspace'
fi

source_pane_json=
capture_json source_pane_json herdr pane get "$HERDR_PANE_ID"
if ! json_has_type "$source_pane_json" pane_info ||
	! printf '%s\n' "$source_pane_json" | jq -e \
		--arg pane_id "$HERDR_PANE_ID" \
		--arg tab_id "$HERDR_TAB_ID" \
		--arg workspace_id "$HERDR_WORKSPACE_ID" \
		'.result.pane.pane_id == $pane_id and
		 .result.pane.tab_id == $tab_id and
		 .result.pane.workspace_id == $workspace_id' >/dev/null 2>&1; then
	die 'the inherited Herdr pane does not belong to the active tab and workspace'
fi

agent_manifests_json=
capture_json agent_manifests_json herdr server agent-manifests --json
if ! json_has_type "$agent_manifests_json" agent_manifest_status ||
	! printf '%s\n' "$agent_manifests_json" | jq -e \
		'(.result.manifests | type) == "array" and
		 all(.result.manifests[];
		     (type == "object") and
		     (.agent | type == "string" and length > 0) and
		     (.active_version == null or
		      (.active_version | type == "string" and length > 0))) and
		 ([.result.manifests[] | select(.agent == "codex")] | length) == 1 and
		 ([.result.manifests[] | select(.agent == "codex")][0].active_version |
		  type == "string" and length > 0)' >/dev/null 2>&1; then
	die 'the Herdr server does not have an active Codex detection manifest'
fi

pr_json=
capture_json pr_json gh pr view "$pr_number" \
	--repo "$selected_repo" \
	--json number,state,headRefOid,baseRefOid,baseRefName,isCrossRepository
printf '%s\n' "$pr_json" | jq -e --arg pr_number "$pr_number" \
	'type == "object" and
	 (.number | type == "number" and tostring == $pr_number) and
	 (.state | type == "string" and length > 0) and
	 (.headRefOid | type == "string" and length > 0) and
	 (.baseRefOid | type == "string" and length > 0) and
	 (.baseRefName | type == "string" and length > 0) and
	 (.isCrossRepository | type == "boolean")' >/dev/null 2>&1 ||
	die 'the pull request metadata response is malformed or identifies another PR'
pr_head_sha="$(printf '%s\n' "$pr_json" | jq -r '.headRefOid')"
pr_base_sha="$(printf '%s\n' "$pr_json" | jq -r '.baseRefOid')"
pr_base_ref="$(printf '%s\n' "$pr_json" | jq -r '.baseRefName')"
validate_commit_id "$pr_head_sha" 'pull request head commit'
validate_commit_id "$pr_base_sha" 'pull request base commit'
git -C "$source_root" check-ref-format --branch "$pr_base_ref" >/dev/null 2>&1 ||
	die "pull request base branch is invalid: $pr_base_ref"
pr_head_sha="$(printf '%s' "$pr_head_sha" | lowercase)"

state_root="$(physical_directory "$state_directory")" || die 'unable to resolve the workflow state directory'
review_worktree_parent="$state_root/worktrees"
ensure_private_directory "$review_worktree_parent" 'PR review worktree parent directory'
review_worktree_parent="$(physical_directory "$review_worktree_parent")" ||
	die 'unable to resolve the PR review worktree parent directory'
review_worktree_path="$review_worktree_parent/$lock_identity"
workspace_label="${repository_name}#${pr_number}-review"
agent_alias="$(sanitize_agent_alias "$selected_repo" "$pr_number")"
case "$agent_alias" in
'' | [!a-z]* | *[!a-z0-9_-]*) die "unable to derive a valid Herdr agent alias: $agent_alias" ;;
esac
[ "${#agent_alias}" -le 32 ] || die "Herdr agent alias is too long: $agent_alias"

ref_root="refs/gh-dash-codex-pr-review/$lock_identity"
review_ref="$ref_root/head"
candidate_ref="$ref_root/candidate-$$"
git -C "$source_root" check-ref-format "$review_ref" >/dev/null 2>&1 ||
	die 'unable to derive a valid durable PR review ref'
git -C "$source_root" check-ref-format "$candidate_ref" >/dev/null 2>&1 ||
	die 'unable to derive a valid temporary PR review ref'
candidate_lookup_status=0
git -C "$source_root" show-ref --verify --quiet "$candidate_ref" || candidate_lookup_status=$?
case "$candidate_lookup_status" in
0) worktree_conflict "temporary PR review ref already exists: $candidate_ref" ;;
1) ;;
*) die 'unable to inspect the temporary PR review ref' ;;
esac

git -C "$source_root" fetch \
	--no-tags \
	--no-write-fetch-head \
	--no-auto-maintenance \
	--force \
	"$fetch_url" \
	"+refs/pull/${pr_number}/head:$candidate_ref" ||
	die 'unable to fetch the pull request head ref'
candidate_ref_owned=1
candidate_sha="$(git -C "$source_root" rev-parse --verify "$candidate_ref" 2>/dev/null)" ||
	die 'the fetched pull request head ref is unavailable'
validate_commit_id "$candidate_sha" 'fetched pull request head commit'
git -C "$source_root" cat-file -e "${candidate_sha}^{commit}" 2>/dev/null ||
	die 'the fetched pull request head ref is not a commit'
candidate_sha="$(printf '%s' "$candidate_sha" | lowercase)"
[ "$candidate_sha" = "$pr_head_sha" ] ||
	die 'the pull request head changed while it was being fetched; press I to retry'

load_worktree_state() {
	local listed_source_path listed_source_root listed_worktree_common_directory

	worktree_list_json=
	capture_json worktree_list_json herdr worktree list --cwd "$source_root" --json
	if ! json_has_type "$worktree_list_json" worktree_list ||
		! printf '%s\n' "$worktree_list_json" | jq -e \
			--arg workspace_id "$HERDR_WORKSPACE_ID" \
			'(.result.source | type) == "object" and
			 (.result.source.source_checkout_path | type == "string" and length > 0) and
			 (.result.source.source_workspace_id | type == "string" and length > 0) and
			 .result.source.source_workspace_id == $workspace_id and
			 (.result.worktrees | type) == "array" and
			 all(.result.worktrees[];
				(type == "object") and
				(.branch == null or
				 ((.branch | type) == "string" and (.branch | length) > 0)) and
				(.path | type == "string" and length > 0) and
				(.is_bare | type) == "boolean" and
				(.is_detached | type) == "boolean" and
				(.is_prunable | type) == "boolean" and
				(.is_linked_worktree | type) == "boolean" and
				((has("open_workspace_id") | not) or
				 .open_workspace_id == null or
				 (.open_workspace_id | type == "string" and length > 0)))' >/dev/null 2>&1; then
		die 'unexpected Herdr worktree-list response or source workspace identity'
	fi

	listed_source_path="$(printf '%s\n' "$worktree_list_json" | jq -r \
		'.result.source.source_checkout_path')"
	listed_source_root="$(physical_directory "$listed_source_path")" ||
		die 'Herdr returned an unavailable source checkout path'
	[ "$listed_source_root" = "$source_root" ] ||
		die "Herdr worktree source does not match the captured source root: $source_root"

	worktree_count="$(printf '%s\n' "$worktree_list_json" | jq -r \
		--arg path "$review_worktree_path" \
		'[.result.worktrees[] | select(.path == $path)] | length')"
	[ "$worktree_count" -le 1 ] ||
		worktree_conflict 'multiple worktrees use the deterministic PR review path'

	listed_worktree_root=
	target_open_workspace_id=
	worktree_head_sha=
	worktree_status=
	if [ "$worktree_count" -eq 0 ]; then
		[ ! -e "$review_worktree_path" ] && [ ! -L "$review_worktree_path" ] ||
			worktree_conflict "the deterministic PR review path is occupied: $review_worktree_path"
		return 0
	fi

	worktree_state="$(printf '%s\n' "$worktree_list_json" | jq -c \
		--arg path "$review_worktree_path" \
		'.result.worktrees[] | select(.path == $path)')"
	printf '%s\n' "$worktree_state" | jq -e \
		'.branch == null and
		 .is_bare == false and
		 .is_detached == true and
		 .is_prunable == false and
		 .is_linked_worktree == true' >/dev/null 2>&1 ||
		worktree_conflict 'existing PR review worktree is not a valid detached linked worktree'
	[ ! -L "$review_worktree_path" ] ||
		worktree_conflict 'the deterministic PR review worktree path is a symbolic link'
	listed_worktree_root="$(physical_directory "$review_worktree_path")" ||
		worktree_conflict 'existing PR review worktree is unavailable'
	[ "$listed_worktree_root" = "$review_worktree_path" ] ||
		worktree_conflict 'existing PR review worktree did not resolve to its deterministic path'
	listed_worktree_common_directory="$(git_common_directory "$listed_worktree_root")" ||
		worktree_conflict 'existing PR review worktree is not a Git worktree'
	[ "$listed_worktree_common_directory" = "$source_common_directory" ] ||
		worktree_conflict 'existing PR review worktree belongs to another Git repository'
	if git -C "$listed_worktree_root" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
		worktree_conflict 'existing PR review worktree is attached to a local branch'
	fi
	worktree_head_sha="$(git -C "$listed_worktree_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" ||
		worktree_conflict 'existing PR review worktree HEAD is unavailable'
	validate_commit_id "$worktree_head_sha" 'PR review worktree HEAD'
	worktree_head_sha="$(printf '%s' "$worktree_head_sha" | lowercase)"
	worktree_status="$(git -C "$listed_worktree_root" status \
		--porcelain=v1 \
		--untracked-files=all \
		--ignore-submodules=none 2>/dev/null)" ||
		worktree_conflict 'unable to inspect the PR review worktree state'
	[ -z "$worktree_status" ] ||
		worktree_conflict 'the PR review worktree is dirty; refusing to refresh or review it'
	target_open_workspace_id="$(printf '%s\n' "$worktree_state" | jq -r \
		'.open_workspace_id // empty')"
}

load_worktree_state
initial_worktree_count="$worktree_count"
initial_worktree_root="$listed_worktree_root"
initial_open_workspace_id="$target_open_workspace_id"

review_ref_lookup_status=0
git -C "$source_root" show-ref --verify --quiet "$review_ref" || review_ref_lookup_status=$?
case "$review_ref_lookup_status" in
0)
	review_ref_exists=1
	review_ref_sha="$(git -C "$source_root" rev-parse --verify "${review_ref}^{commit}" 2>/dev/null)" ||
		die 'the durable PR review ref is not a commit'
	validate_commit_id "$review_ref_sha" 'durable PR review ref'
	review_ref_sha="$(printf '%s' "$review_ref_sha" | lowercase)"
	;;
1)
	review_ref_exists=0
	review_ref_sha=
	;;
*) die 'unable to inspect the durable PR review ref' ;;
esac

if [ "$worktree_count" -eq 0 ]; then
	if [ "$review_ref_exists" -eq 0 ]; then
		git -C "$source_root" update-ref "$review_ref" "$pr_head_sha" '' ||
			worktree_conflict 'unable to create the durable PR review ref'
	else
		if [ "$review_ref_sha" != "$pr_head_sha" ]; then
			git -C "$source_root" update-ref "$review_ref" "$pr_head_sha" "$review_ref_sha" ||
				worktree_conflict 'unable to refresh the unoccupied durable PR review ref'
		fi
	fi
	release_candidate_ref || die 'unable to remove the temporary PR-head ref'
	git -C "$source_root" worktree add --detach "$review_worktree_path" "$review_ref" ||
		worktree_conflict 'unable to create the detached PR review worktree'
else
	[ "$review_ref_exists" -eq 1 ] ||
		worktree_conflict 'the PR review worktree exists without its durable review ref'
	if [ "$worktree_head_sha" != "$pr_head_sha" ]; then
		[ "$worktree_head_sha" = "$review_ref_sha" ] ||
			worktree_conflict 'the PR review worktree and durable ref have diverged'
		git -C "$listed_worktree_root" switch \
			--detach \
			--no-overwrite-ignore \
			"$candidate_ref" ||
			worktree_conflict 'unable to refresh the clean PR review worktree safely'
		refreshed_worktree_sha="$(git -C "$listed_worktree_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" ||
			worktree_conflict 'unable to verify the refreshed PR review worktree HEAD'
		refreshed_worktree_sha="$(printf '%s' "$refreshed_worktree_sha" | lowercase)"
		[ "$refreshed_worktree_sha" = "$pr_head_sha" ] ||
			worktree_conflict 'the refreshed PR review worktree does not match the pull request head'
	fi
	if [ "$review_ref_sha" != "$pr_head_sha" ]; then
		git -C "$source_root" update-ref "$review_ref" "$pr_head_sha" "$review_ref_sha" ||
			worktree_conflict 'unable to update the durable PR review ref after refreshing the worktree'
	fi
	release_candidate_ref || die 'unable to remove the temporary PR-head ref'
fi

load_worktree_state
[ "$worktree_count" -eq 1 ] ||
	worktree_conflict 'the prepared PR review worktree is not the only canonical worktree at its path'
worktree_root="$listed_worktree_root"
if [ "$initial_worktree_count" -eq 1 ]; then
	[ "$worktree_root" = "$initial_worktree_root" ] ||
		worktree_conflict 'the refreshed PR review worktree path changed unexpectedly'
fi
[ "$worktree_head_sha" = "$pr_head_sha" ] ||
	worktree_conflict 'the prepared PR review worktree does not represent the pull request head'
prepared_review_ref_sha="$(git -C "$source_root" rev-parse --verify "${review_ref}^{commit}" 2>/dev/null)" ||
	worktree_conflict 'the prepared durable PR review ref is unavailable'
prepared_review_ref_sha="$(printf '%s' "$prepared_review_ref_sha" | lowercase)"
[ "$prepared_review_ref_sha" = "$pr_head_sha" ] ||
	worktree_conflict 'the prepared durable PR review ref does not represent the pull request head'

worktree_result_json=
worktree_open_status=0
capture_json_response worktree_result_json herdr worktree open \
	--cwd "$source_root" \
	--path "$review_worktree_path" \
	--label "$workspace_label" \
	--no-focus \
	--json || worktree_open_status=$?
[ "$worktree_open_status" -eq 0 ] ||
	die "unable to open the PR review worktree; existing work was preserved: $worktree_result_json"
json_has_type "$worktree_result_json" worktree_opened ||
	die 'unexpected Herdr worktree-open response'
printf '%s\n' "$worktree_result_json" | jq -e \
	'.result.workspace.workspace_id as $workspace_id |
	 .result.tab.tab_id as $tab_id |
	 .result.root_pane.pane_id as $pane_id |
	 ($workspace_id | type == "string" and length > 0) and
	 ($tab_id | type == "string" and length > 0) and
	 ($pane_id | type == "string" and length > 0) and
	 (.result.already_open | type) == "boolean" and
	 .result.tab.workspace_id == $workspace_id and
	 .result.root_pane.workspace_id == $workspace_id and
	 .result.root_pane.tab_id == $tab_id and
	 (.result.root_pane.foreground_cwd | type == "string" and length > 0) and
	 .result.worktree.branch == null and
	 .result.worktree.is_bare == false and
	 .result.worktree.is_detached == true and
	 .result.worktree.is_prunable == false and
	 .result.worktree.is_linked_worktree == true and
	 (.result.worktree.path | type == "string" and length > 0)' >/dev/null 2>&1 ||
	die 'Herdr returned an invalid PR review worktree or workspace identity'

workspace_id="$(printf '%s\n' "$worktree_result_json" | jq -r '.result.workspace.workspace_id')"
root_tab_id="$(printf '%s\n' "$worktree_result_json" | jq -r '.result.tab.tab_id')"
root_pane_id="$(printf '%s\n' "$worktree_result_json" | jq -r '.result.root_pane.pane_id')"
root_pane_cwd="$(printf '%s\n' "$worktree_result_json" | jq -r '.result.root_pane.foreground_cwd')"
returned_worktree_path="$(printf '%s\n' "$worktree_result_json" | jq -r '.result.worktree.path')"
already_open="$(printf '%s\n' "$worktree_result_json" | jq -r '.result.already_open')"
returned_worktree_root="$(physical_directory "$returned_worktree_path")" ||
	die 'Herdr returned an unavailable PR review worktree path'
root_pane_directory="$(physical_directory "$root_pane_cwd")" ||
	die 'the PR review workspace root pane has an unavailable live directory'
[ "$returned_worktree_root" = "$worktree_root" ] ||
	die 'Herdr opened a different PR review worktree path'
[ "$root_pane_directory" = "$worktree_root" ] ||
	die 'the PR review workspace root pane is not at the PR review worktree root'
if [ -n "$initial_open_workspace_id" ]; then
	[ "$already_open" = true ] && [ "$workspace_id" = "$initial_open_workspace_id" ] ||
		worktree_conflict 'Herdr did not reuse the existing PR review workspace'
else
	[ "$already_open" = false ] ||
		worktree_conflict 'Herdr reported an unexpected pre-existing PR review workspace'
fi

load_worktree_state
[ "$worktree_count" -eq 1 ] ||
	worktree_conflict 'opened PR review worktree is no longer canonical'
[ "$listed_worktree_root" = "$worktree_root" ] ||
	worktree_conflict 'post-open PR review worktree path changed unexpectedly'
[ "$target_open_workspace_id" = "$workspace_id" ] ||
	worktree_conflict 'canonical PR review worktree is associated with another workspace'
[ "$worktree_head_sha" = "$pr_head_sha" ] ||
	worktree_conflict 'opened PR review worktree no longer represents the pull request head'

runtime_validation_error=
validate_runtime_pane() {
	local expected_tab_id="$1" expected_pane_id="$2"
	local tab_json pane_json pane_cwd pane_root response_status=0

	capture_json_response tab_json herdr tab get "$expected_tab_id" || response_status=$?
	if [ "$response_status" -ne 0 ] ||
		! json_has_type "$tab_json" tab_info ||
		! printf '%s\n' "$tab_json" | jq -e \
			--arg workspace_id "$workspace_id" \
			--arg tab_id "$expected_tab_id" \
			'.result.tab.workspace_id == $workspace_id and
			 .result.tab.tab_id == $tab_id' >/dev/null 2>&1; then
		runtime_validation_error="unable to validate agent tab $expected_tab_id: $tab_json"
		return 1
	fi

	response_status=0
	capture_json_response pane_json herdr pane get "$expected_pane_id" || response_status=$?
	if [ "$response_status" -ne 0 ] ||
		! json_has_type "$pane_json" pane_info ||
		! printf '%s\n' "$pane_json" | jq -e \
			--arg workspace_id "$workspace_id" \
			--arg tab_id "$expected_tab_id" \
			--arg pane_id "$expected_pane_id" \
			'.result.pane.workspace_id == $workspace_id and
			 .result.pane.tab_id == $tab_id and
			 .result.pane.pane_id == $pane_id and
			 (.result.pane.foreground_cwd | type == "string" and length > 0)' >/dev/null 2>&1; then
		runtime_validation_error="unable to validate agent pane $expected_pane_id: $pane_json"
		return 1
	fi
	pane_cwd="$(printf '%s\n' "$pane_json" | jq -r '.result.pane.foreground_cwd')"
	pane_root="$(physical_directory "$pane_cwd")" || {
		runtime_validation_error="agent pane has an unavailable directory: $pane_cwd"
		return 1
	}
	if [ "$pane_root" != "$worktree_root" ]; then
		runtime_validation_error="agent pane is not at the canonical PR review worktree: $pane_cwd"
		return 1
	fi
}

agent_identity_matches() {
	local document="$1" expected_type="$2" expected_name="$3" expected_kind="$4"
	local expected_workspace_id="$5" expected_tab_id="$6" expected_pane_id="$7"

	json_has_type "$document" "$expected_type" &&
		printf '%s\n' "$document" | jq -e \
			--arg name "$expected_name" \
			--arg kind "$expected_kind" \
			--arg workspace_id "$expected_workspace_id" \
			--arg tab_id "$expected_tab_id" \
			--arg pane_id "$expected_pane_id" \
			'(.result.agent | type) == "object" and
			 .result.agent.name == $name and
			 .result.agent.agent == $kind and
			 .result.agent.workspace_id == $workspace_id and
			 .result.agent.tab_id == $tab_id and
			 .result.agent.pane_id == $pane_id and
			 all([
				.result.agent.name,
				.result.agent.agent,
				.result.agent.workspace_id,
				.result.agent.tab_id,
				.result.agent.pane_id
			 ][]; type == "string" and length > 0)' >/dev/null 2>&1
}

agent_list_json=
capture_json agent_list_json herdr agent list
if ! json_has_type "$agent_list_json" agent_list ||
	! printf '%s\n' "$agent_list_json" | jq -e \
		'(.result.agents | type) == "array" and
		 all(.result.agents[];
			(type == "object") and
			(.name == null or
			 ((.name | type) == "string" and (.name | length) > 0)) and
			(.agent == null or
			 ((.agent | type) == "string" and (.agent | length) > 0)) and
			((.workspace_id | type) == "string" and (.workspace_id | length) > 0) and
			((.tab_id | type) == "string" and (.tab_id | length) > 0) and
			((.pane_id | type) == "string" and (.pane_id | length) > 0))' >/dev/null 2>&1; then
	die 'unexpected Herdr agent-list response'
fi

complete_agent_count="$(printf '%s\n' "$agent_list_json" | jq -r \
	--arg name "$agent_alias" \
	--arg workspace_id "$workspace_id" \
	--arg tab_id "$root_tab_id" \
	--arg pane_id "$root_pane_id" \
	'[.result.agents[] | select(
		.name == $name and
		.agent == "codex" and
		.workspace_id == $workspace_id and
		.tab_id == $tab_id and
		.pane_id == $pane_id
	)] | length')"
related_agent_count="$(printf '%s\n' "$agent_list_json" | jq -r \
	--arg name "$agent_alias" \
	--arg workspace_id "$workspace_id" \
	--arg tab_id "$root_tab_id" \
	--arg pane_id "$root_pane_id" \
	'[.result.agents[] | select(
		.name == $name or
		.workspace_id == $workspace_id or
		.tab_id == $tab_id or
		.pane_id == $pane_id
	)] | length')"
if [ "$complete_agent_count" -gt 1 ]; then
	agent_conflict "multiple complete Codex identities match $workspace_label"
fi
if [ "$complete_agent_count" -eq 0 ] && [ "$related_agent_count" -gt 0 ]; then
	agent_conflict "partial or coordinate-sharing agent identities conflict with $workspace_label"
fi
if [ "$complete_agent_count" -eq 1 ] && [ "$related_agent_count" -ne 1 ]; then
	agent_conflict 'the complete PR review Codex identity has conflicting related entries'
fi

agent_document=
agent_get_status=0
capture_json_response agent_document herdr agent get "$agent_alias" || agent_get_status=$?
if [ "$agent_get_status" -eq 125 ]; then
	die "agent lookup did not return exactly one JSON object; prompt not sent: $agent_document"
fi
if [ "$complete_agent_count" -eq 0 ]; then
	case "$agent_get_status" in
	0) agent_conflict "agent list and agent lookup disagree for alias $agent_alias" ;;
	*)
		json_is_error_only "$agent_document" agent_not_found ||
			agent_conflict "agent lookup failed for alias $agent_alias: $agent_document"
		;;
	esac
	agent_present=0
else
	[ "$agent_get_status" -eq 0 ] ||
		agent_conflict "agent lookup failed for listed alias $agent_alias: $agent_document"
	agent_identity_matches \
		"$agent_document" agent_info \
		"$agent_alias" codex "$workspace_id" "$root_tab_id" "$root_pane_id" ||
		agent_conflict 'agent list and lookup identities do not agree completely'
	validate_runtime_pane "$root_tab_id" "$root_pane_id" ||
		agent_conflict "$runtime_validation_error"
	agent_present=1
fi

codex_args=(
	--ask-for-approval never
	--strict-config
	--cd "$worktree_root"
	--config 'default_permissions="gh_dash_pr_review"'
	--config 'permissions.gh_dash_pr_review={extends=":read-only",network={enabled=true,domains={"github.com"="allow","api.github.com"="allow","*.githubusercontent.com"="allow"}}}'
)

if [ "$agent_present" -eq 0 ]; then
	agent_start_json=
	for ((agent_start_attempt = 1; agent_start_attempt <= AGENT_START_TOTAL_ATTEMPTS; agent_start_attempt++)); do
		agent_start_status=0
		capture_json_response agent_start_json herdr agent start "$agent_alias" \
			--kind codex \
			--pane "$root_pane_id" \
			--timeout 30000 \
			-- "${codex_args[@]}" || agent_start_status=$?
		[ "$agent_start_status" -ne 0 ] || break
		[ "$agent_start_status" -ne 125 ] ||
			die "unable to start Codex for PR review; prompt not sent: $agent_start_json"
		json_is_error_only "$agent_start_json" agent_pane_busy ||
			die "unable to start Codex for PR review; prompt not sent: $agent_start_json"
		[ "$agent_start_attempt" -lt "$AGENT_START_TOTAL_ATTEMPTS" ] ||
			die "exact target pane $root_pane_id did not become an available shell after $AGENT_START_TOTAL_ATTEMPTS total agent-start attempts; prompt not sent"
		sleep "$AGENT_START_RETRY_INTERVAL_SECONDS"
		validate_runtime_pane "$root_tab_id" "$root_pane_id" ||
			die "unable to retry Codex on exact target pane $root_pane_id: $runtime_validation_error; prompt not sent"
	done
	agent_identity_matches \
		"$agent_start_json" agent_started \
		"$agent_alias" codex "$workspace_id" "$root_tab_id" "$root_pane_id" ||
		agent_conflict 'Codex started, but its returned identity conflicts with the expected PR review agent'
	validate_runtime_pane "$root_tab_id" "$root_pane_id" ||
		agent_conflict "Codex started, but $runtime_validation_error"
fi

prompt="Review pull request ${selected_repo}#${pr_number} against its base. Keep repository access read-only: do not modify files, commit, or push.

Check for bugs, regressions, security issues, edge cases, and missing tests. Report only actionable findings with severity and file/line references.

After completing the review, publish the result in one Codex review comment on pull request ${selected_repo}#${pr_number}. Use concise Markdown ordered by severity. Include the marker <!-- gh-dash-codex-pr-review --> in the comment.

Before writing, find a comment on this PR authored by the currently authenticated GitHub user that contains that exact marker. If one exists, update it; otherwise create it. Never create a second marked comment.

If there are no actionable findings, publish a short all-clear comment and then mark the pull request as ready for review if it is currently a draft. If actionable findings exist, do not change its draft/ready state.

The only permitted GitHub mutations are creating or updating that marked review comment and, when there are no actionable findings, marking the PR ready for review. Do not change the PR title, body, labels, review state, branches, commits, or any other GitHub data."

prompt_json=
prompt_status=0
capture_json_response prompt_json herdr agent prompt "$root_pane_id" "$prompt" \
	--wait \
	--until working \
	--timeout 30000 || prompt_status=$?
[ "$prompt_status" -eq 0 ] ||
	die "PR review prompt command failed or returned an uncertain result; prompt was not retried: $prompt_json"
agent_identity_matches \
	"$prompt_json" agent_prompted \
	"$agent_alias" codex "$workspace_id" "$root_tab_id" "$root_pane_id" ||
	die 'PR review prompt result did not identify the exact Codex agent'
validate_runtime_pane "$root_tab_id" "$root_pane_id" ||
	die "PR review prompt completed but runtime identity became uncertain: $runtime_validation_error"

notify 'PR review prompt sent to the exact locally read-only Codex agent.' 'done'
exit 0
