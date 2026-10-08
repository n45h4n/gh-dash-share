#!/usr/bin/env bash
set -euo pipefail

PROGRAM="${0##*/}"
NOTIFICATION_TITLE="gh-dash Codex issue"
AGENT_START_TOTAL_ATTEMPTS=10
AGENT_START_RETRY_INTERVAL_SECONDS=1
DIAGNOSTIC_RETENTION_SECONDS=604800
issue_log_detached=0
manager_kind=codex
manager_label=Codex
issue_lock_owned=0

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

finish_without_action() {
	local message="$1"

	printf 'INFO: %s: %s\n' "$PROGRAM" "$message" >&2
	notify "$message" request
	exit 0
}

worktree_conflict() {
	local detail="$1"

	printf 'ERROR: %s: %s\n' "$PROGRAM" "$detail" >&2
	notify "Issue worktree conflict; no changes made." request
	exit 1
}

prompt_failed() {
	local detail="$1"

	printf 'ERROR: %s: %s\n' "$PROGRAM" "$detail" >&2
	notify 'Issue prompt failed; press I to retry.' request
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
		'.error == null and
		 (.result | type) == "object" and
		 .result.type == $expected_type' >/dev/null 2>&1
}

json_has_no_error() {
	local document="$1"

	printf '%s\n' "$document" | jq -e '.error == null' >/dev/null 2>&1
}

json_is_error_only() {
	local document="$1" expected_code="$2"

	printf '%s\n' "$document" | jq -e --arg expected_code "$expected_code" \
		'.result == null and
		 (.error | type) == "object" and
		 (.error.code | type) == "string" and
		 .error.code == $expected_code' >/dev/null 2>&1
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

sanitize_agent_alias() {
	local repository_name="$1" issue_number="$2" alias

	alias="$(printf '%s' "$repository_name" | lowercase | tr -cs 'a-z0-9_-' '-')"
	alias="${alias#-}"
	alias="${alias%-}"
	[ -n "$alias" ] || alias=repo
	case "$alias" in
	[0-9_-]*) alias="repo-$alias" ;;
	esac

	# Reserve the issue suffix before truncating the repository component.
	alias="${alias:0:$((31 - ${#issue_number}))}-$issue_number"
	printf '%s\n' "$alias"
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

refresh_dispatched_issue_log() {
	[ "$issue_log_detached" -eq 1 ] || return 0
	python3 - "$log_path" <<'PY' || die "unable to refresh diagnostic log safely: $log_path"
import fcntl
import os
import stat
import sys

path = sys.argv[1]
descriptor = 1
locked = False
try:
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    locked = True
    path_info = os.lstat(path)
    output_info = os.fstat(descriptor)
    error_info = os.fstat(2)
    private = lambda value: (
        stat.S_ISREG(value.st_mode)
        and value.st_uid == os.geteuid()
        and value.st_nlink == 1
        and stat.S_IMODE(value.st_mode) == 0o600
    )
    identity = lambda value: (value.st_dev, value.st_ino)
    if not all(private(value) for value in (path_info, output_info, error_info)):
        raise OSError("diagnostic log is not a private regular file")
    if identity(path_info) != identity(output_info) or identity(output_info) != identity(error_info):
        raise OSError("diagnostic path and inherited descriptors differ")
    os.ftruncate(descriptor, 0)
    os.lseek(descriptor, 0, os.SEEK_END)
finally:
    if locked:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
PY
}

prune_inactive_issue_logs() {
	if ! python3 - "$state_directory" "$issue_lock_root" \
		"$DIAGNOSTIC_RETENTION_SECONDS" <<'PY'
import errno
import fcntl
import os
import re
import stat
import sys
import time

state_path, lock_root_path, retention_text = sys.argv[1:]
uid = os.geteuid()
cutoff = time.time() - int(retention_text)
pattern = re.compile(
    r"repo-([1-9][0-9]?)-([a-z0-9-]+)-([1-9][0-9]{0,2})-"
    r"([a-z0-9._-]+)-issue-([1-9][0-9]{0,19})[.]log"
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


def exact_identity(name):
    match = pattern.fullmatch(name)
    if match is None:
        return None
    owner_length, owner, repository_length, repository, issue = match.groups()
    if (
        int(owner_length) != len(owner)
        or len(owner) > 39
        or owner.startswith("-")
        or owner.endswith("-")
        or int(repository_length) != len(repository)
        or len(repository) > 100
        or repository in (".", "..")
    ):
        return None
    identity = name.removesuffix(".log")
    expected = f"repo-{len(owner)}-{owner}-{len(repository)}-{repository}-issue-{issue}"
    return identity if identity == expected else None


def process_is_absent(pid):
    if os.path.exists("/proc/self/stat"):
        try:
            os.stat(f"/proc/{pid}")
        except FileNotFoundError:
            return True
        except OSError:
            return False
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except (PermissionError, OSError):
        return False
    return False


def identity_is_inactive(lock_root_fd, identity):
    lock_fd = owner_fd = None
    try:
        try:
            lock_fd = os.open(
                identity + ".lock",
                os.O_RDONLY | os.O_NONBLOCK | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=lock_root_fd,
            )
        except FileNotFoundError:
            return True
        if not private_directory(os.fstat(lock_fd)) or os.listdir(lock_fd) != ["owner"]:
            return False
        owner_fd = os.open(
            "owner",
            os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW,
            dir_fd=lock_fd,
        )
        owner_info = os.fstat(owner_fd)
        if not private_file(owner_info):
            return False
        data = os.read(owner_fd, 256)
        match = re.fullmatch(rb"([1-9][0-9]{0,19})\n([0-9]{1,20})\n", data)
        if match is None:
            return False
        current = os.stat("owner", dir_fd=lock_fd, follow_symlinks=False)
        if not private_file(current) or (current.st_dev, current.st_ino) != (
            owner_info.st_dev,
            owner_info.st_ino,
        ):
            return False
        if os.listdir(lock_fd) != ["owner"]:
            return False
        return process_is_absent(int(match.group(1)))
    except OSError:
        return False
    finally:
        if owner_fd is not None:
            os.close(owner_fd)
        if lock_fd is not None:
            os.close(lock_fd)


def matches_open_file(state_fd, name, opened):
    current = os.stat(name, dir_fd=state_fd, follow_symlinks=False)
    return (
        private_file(current)
        and (current.st_dev, current.st_ino) == (opened.st_dev, opened.st_ino)
        and current.st_mtime < cutoff
    )


unsafe = 0
state_fd = lock_root_fd = None
try:
    required = ("O_DIRECTORY", "O_NOFOLLOW", "O_NONBLOCK")
    if not all(hasattr(os, name) for name in required):
        raise OSError("required no-follow file operations are unavailable")
    flags = os.O_RDONLY | os.O_NONBLOCK | os.O_DIRECTORY | os.O_NOFOLLOW
    state_fd = os.open(state_path, flags)
    lock_root_fd = os.open(lock_root_path, flags)
    if not private_directory(os.fstat(state_fd)) or not private_directory(os.fstat(lock_root_fd)):
        raise OSError("diagnostic state directories are unsafe")
    for name in os.listdir(state_fd):
        identity = exact_identity(name)
        if identity is None:
            continue
        descriptor = None
        try:
            descriptor = os.open(
                name,
                os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW,
                dir_fd=state_fd,
            )
            opened = os.fstat(descriptor)
            if not private_file(opened) or opened.st_mtime >= cutoff:
                continue
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                if error.errno in (errno.EACCES, errno.EAGAIN):
                    continue
                raise
            if not identity_is_inactive(lock_root_fd, identity):
                continue
            if not matches_open_file(state_fd, name, opened):
                continue
            os.unlink(name, dir_fd=state_fd)
        except FileNotFoundError:
            continue
        except OSError:
            unsafe += 1
        finally:
            if descriptor is not None:
                os.close(descriptor)
finally:
    if lock_root_fd is not None:
        os.close(lock_root_fd)
    if state_fd is not None:
        os.close(state_fd)

if unsafe:
    print(
        f"WARNING: skipped {unsafe} unsafe or unreadable diagnostic retention candidate(s)",
        file=sys.stderr,
    )
PY
	then
		printf 'WARNING: %s: diagnostic retention cleanup failed; launch continuing\n' "$PROGRAM" >&2
	fi
	return 0
}

release_issue_lock() {
	[ "$issue_lock_owned" -eq 1 ] || return 0
	rm -f -- "$issue_lock_owner" 2>/dev/null || true
	rmdir -- "$issue_lock_directory" 2>/dev/null || true
	issue_lock_owned=0
}

trap release_issue_lock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

[ "$#" -eq 2 ] ||
	prelock_die 'usage: gh-dash-codex-issue.sh <owner/repository> <issue-number>'

selected_repo="$1"
issue_number="$2"

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
case "$issue_number" in
'' | 0* | *[!0-9]*) prelock_die "invalid issue number: $issue_number" ;;
esac
[ "${#issue_number}" -le 20 ] || prelock_die "issue number is too large: $issue_number"

for command_name in tr mkdir rmdir rm date chmod sleep python3; do
	command -v "$command_name" >/dev/null 2>&1 ||
		prelock_die "required command not found: $command_name"
done

repository_owner_lower="$(printf '%s' "$repository_owner" | lowercase)" ||
	prelock_die 'unable to normalize the repository owner'
repository_name_lower="$(printf '%s' "$repository_name" | lowercase)" ||
	prelock_die 'unable to normalize the repository name'
selected_repo_lower="$repository_owner_lower/$repository_name_lower"
lock_identity="repo-${#repository_owner_lower}-${repository_owner_lower}-${#repository_name_lower}-${repository_name_lower}-issue-${issue_number}"
case "$lock_identity" in
'' | *[!a-z0-9._-]*) prelock_die 'unable to derive a safe issue lock identity' ;;
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
state_directory="$state_base/gh-dash-codex-issue"
issue_lock_root="$state_directory/locks"
issue_lock_directory="$issue_lock_root/$lock_identity.lock"
issue_lock_owner="$issue_lock_directory/owner"
log_path="$state_directory/$lock_identity.log"
issue_lock_deferred_signal=
if [ -n "${GH_DASH_CODEX_ISSUE_LOG_PATH+x}" ]; then
	[ "$GH_DASH_CODEX_ISSUE_LOG_PATH" = "$log_path" ] ||
		prelock_die 'dispatcher diagnostic-log identity does not match the selected issue'
	issue_log_detached=1
	unset GH_DASH_CODEX_ISSUE_LOG_PATH
fi

issue_locked() {
	local message

	message='Issue operation is locked. If no issue helper is running, remove the stale lock manually and press I again.'
	printf 'ERROR: %s: %s\nLock path: %s\n' \
		"$PROGRAM" "$message" "$issue_lock_directory" >&2
	notify "$message" request
	exit 1
}

defer_issue_lock_signal() {
	[ -n "$issue_lock_deferred_signal" ] || issue_lock_deferred_signal="$1"
}

acquire_issue_lock() {
	local gate gate_error=0 lock_status=0 now

	ensure_private_directory "$state_directory" 'workflow state directory'
	ensure_private_directory "$issue_lock_root" 'issue lock parent directory'

	issue_lock_deferred_signal=
	trap 'defer_issue_lock_signal INT' INT
	trap 'defer_issue_lock_signal TERM' TERM
	trap 'defer_issue_lock_signal HUP' HUP
	(umask 077 && mkdir -- "$issue_lock_directory") 2>/dev/null || lock_status=$?
	if [ "$lock_status" -eq 0 ]; then
		# Test-only gate for exercising the otherwise unobservable mkdir/ownership boundary.
		gate="${GH_DASH_CODEX_ISSUE_TEST_AFTER_LOCK_MKDIR_GATE:-}"
		if [ -n "$gate" ]; then
			if : >"$gate.ready"; then
				while [ ! -e "$gate.release" ] && [ -z "$issue_lock_deferred_signal" ]; do
					sleep 0.01 || true
				done
			else
				gate_error=1
			fi
		fi
		issue_lock_owned=1
	fi
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
	case "$issue_lock_deferred_signal" in
	INT) exit 130 ;;
	TERM) exit 143 ;;
	HUP) exit 129 ;;
	esac
	[ "$lock_status" -eq 0 ] || issue_locked
	[ "$gate_error" -eq 0 ] || die 'unable to enter the issue lock test gate'
	chmod 700 -- "$issue_lock_directory" || die 'unable to protect the issue lock'
	now="$(date +%s)" || die 'unable to capture the issue lock timestamp'
	case "$now" in
	'' | *[!0-9]*) die 'the system returned an invalid issue lock timestamp' ;;
	esac
	(umask 077 && printf '%s\n%s\n' "$$" "$now" >"$issue_lock_owner") ||
		die 'unable to record the issue lock owner'
}

acquire_issue_lock
refresh_dispatched_issue_log
prune_inactive_issue_logs

for command_name in git gh herdr jq; do
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
	GH_DASH_SOURCE_ROOT="$(cd "$GH_DASH_SOURCE_ROOT" && pwd -P)" ||
		die 'unable to resolve the captured source root'
	GH_DASH_SOURCE_BRANCH="$(git -C "$GH_DASH_SOURCE_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null)" ||
		die 'detached HEAD is not supported'
	GH_DASH_SOURCE_SHA="$(git -C "$GH_DASH_SOURCE_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" ||
		die 'unable to resolve the current source commit'
	GH_DASH_SOURCE_REPO="$selected_repo"
	if source_status="$(git -C "$GH_DASH_SOURCE_ROOT" status --porcelain --untracked-files=normal 2>/dev/null)"; then
		if [ -n "$source_status" ]; then
			GH_DASH_SOURCE_DIRTY=1
			printf 'WARNING: %s: the source checkout is dirty; uncommitted changes remain only in the source checkout\n' \
				"$PROGRAM" >&2
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
case "$GH_DASH_SOURCE_SHA" in
*[!0-9A-Fa-f]* | '') die 'GH_DASH_SOURCE_SHA is not a hexadecimal commit ID' ;;
esac
case "${#GH_DASH_SOURCE_SHA}" in
40 | 64) ;;
*) die 'GH_DASH_SOURCE_SHA must contain 40 or 64 hexadecimal characters' ;;
esac

require_environment HERDR_SOCKET_PATH
for variable_name in HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID; do
	require_environment "$variable_name"
done

[ -d "$GH_DASH_SOURCE_ROOT" ] || die "source root does not exist: $GH_DASH_SOURCE_ROOT"
source_root="$(cd "$GH_DASH_SOURCE_ROOT" && pwd -P)" || die 'unable to resolve the source root'
git_root="$(git -C "$source_root" rev-parse --show-toplevel 2>/dev/null)" ||
	die "source root is not a Git worktree: $source_root"
git_root="$(cd "$git_root" && pwd -P)" || die 'unable to resolve the Git worktree root'
[ "$git_root" = "$source_root" ] || die "captured source root does not match the Git root: $source_root"
source_common_directory="$(git_common_directory "$source_root")" ||
	die 'unable to resolve the source Git common directory'

git -C "$source_root" check-ref-format --branch "$GH_DASH_SOURCE_BRANCH" >/dev/null 2>&1 ||
	die "invalid captured source branch: $GH_DASH_SOURCE_BRANCH"
git -C "$source_root" cat-file -e "${GH_DASH_SOURCE_SHA}^{commit}" 2>/dev/null ||
	die "captured source commit is unavailable: $GH_DASH_SOURCE_SHA"

captured_repo_lower="$(printf '%s' "$GH_DASH_SOURCE_REPO" | lowercase)"
[ "$selected_repo_lower" = "$captured_repo_lower" ] ||
	die "selected issue repository $selected_repo does not match captured repository $GH_DASH_SOURCE_REPO"

issue_branch="agent/issue-$issue_number"
issue_branch_ref="refs/heads/$issue_branch"
workspace_label="$repository_name#$issue_number"
agent_alias="$(sanitize_agent_alias "$repository_name" "$issue_number")"
prompt="Fetch issue ${selected_repo}#${issue_number} and use its body as the prompt."
case "$agent_alias" in
'' | [!a-z]* | *[!a-z0-9_-]*) die "unable to derive a valid Herdr agent alias: $agent_alias" ;;
esac
[ "${#agent_alias}" -le 32 ] || die "Herdr agent alias is too long: $agent_alias"

current_repo="$(
	cd "$source_root" && env -u GH_REPO gh repo view --json nameWithOwner --jq '.nameWithOwner'
)" || die 'unable to resolve the source GitHub repository'
[ -n "$current_repo" ] || die 'the canonical source GitHub repository is empty'
current_repo_lower="$(printf '%s' "$current_repo" | lowercase)"
[ "$selected_repo_lower" = "$current_repo_lower" ] ||
	die "selected issue repository $selected_repo does not match source repository $current_repo"
[ "$captured_repo_lower" = "$current_repo_lower" ] ||
	die "captured repository $GH_DASH_SOURCE_REPO does not match source repository $current_repo"

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
load_manager_manifests() {
	capture_json agent_manifests_json herdr server agent-manifests --json
	if ! json_has_type "$agent_manifests_json" agent_manifest_status ||
		! printf '%s\n' "$agent_manifests_json" | jq -e \
			'(.result.manifests | type) == "array" and
			 all(.result.manifests[];
			     (type == "object") and
			     (.agent | type == "string" and length > 0) and
			     (.active_version == null or
			      (.active_version | type == "string" and length > 0)))' >/dev/null 2>&1; then
		die "the Herdr server does not have an active $manager_label detection manifest (invalid manifest response)"
	fi
}

require_manager_manifest() {
	[ -n "$agent_manifests_json" ] || load_manager_manifests
	printf '%s\n' "$agent_manifests_json" | jq -e --arg kind "$manager_kind" \
		'([.result.manifests[] | select(.agent == $kind)] | length) == 1 and
		 ([.result.manifests[] | select(.agent == $kind)][0].active_version |
		  type == "string" and length > 0)' >/dev/null 2>&1 ||
		die "the Herdr server does not have an active $manager_label detection manifest"
}

load_manager_manifests
require_manager_manifest

[ "$GH_DASH_SOURCE_BRANCH" != "$issue_branch" ] ||
	worktree_conflict "source checkout already uses $issue_branch; refusing to create another worktree"

load_worktree_state() {
	local branch_lookup_status=0 listed_source_path listed_source_root
	local listed_worktree_common_directory

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

	worktree_count="$(printf '%s\n' "$worktree_list_json" | jq -r --arg branch "$issue_branch" \
		'[.result.worktrees[] | select(.branch == $branch)] | length')"
	[ "$worktree_count" -le 1 ] ||
		worktree_conflict "multiple worktrees use branch $issue_branch"

	git -C "$source_root" show-ref --verify --quiet "$issue_branch_ref" || branch_lookup_status=$?
	case "$branch_lookup_status" in
	0) branch_exists=1 ;;
	1) branch_exists=0 ;;
	*) die "unable to inspect local branch $issue_branch" ;;
	esac

	listed_worktree_path=
	listed_worktree_root=
	target_open_workspace_id=
	if [ "$worktree_count" -eq 1 ]; then
		[ "$branch_exists" -eq 1 ] ||
			worktree_conflict "worktree for $issue_branch exists without its local branch"
		worktree_state="$(printf '%s\n' "$worktree_list_json" | jq -c --arg branch "$issue_branch" \
			'.result.worktrees[] | select(.branch == $branch)')"
		printf '%s\n' "$worktree_state" | jq -e \
			'.is_bare == false and
			 .is_detached == false and
			 .is_prunable == false and
			 .is_linked_worktree == true and
			 (.path | type == "string" and length > 0)' >/dev/null 2>&1 ||
			worktree_conflict "existing worktree for $issue_branch is not a valid linked worktree"
		listed_worktree_path="$(printf '%s\n' "$worktree_state" | jq -r '.path')"
		listed_worktree_root="$(physical_directory "$listed_worktree_path")" ||
			worktree_conflict "existing worktree for $issue_branch is unavailable"
		listed_worktree_common_directory="$(git_common_directory "$listed_worktree_root")" ||
			worktree_conflict "existing worktree for $issue_branch is not a Git worktree"
		[ "$listed_worktree_common_directory" = "$source_common_directory" ] ||
			worktree_conflict "existing worktree for $issue_branch belongs to another Git repository"
		target_open_workspace_id="$(printf '%s\n' "$worktree_state" | jq -r \
			'.open_workspace_id // empty')"
	fi
}

load_worktree_state
initial_worktree_root="$listed_worktree_root"
reusing_existing_worktree="$worktree_count"
readonly initial_worktree_root reusing_existing_worktree
if [ "$worktree_count" -eq 0 ]; then
	if [ "$branch_exists" -eq 0 ]; then
		git -C "$source_root" update-ref "$issue_branch_ref" "$GH_DASH_SOURCE_SHA" '' ||
			worktree_conflict "unable to create issue branch $issue_branch"
		created_issue_branch=1
	else
		created_issue_branch=0
	fi
	worktree_result_json=
	if ! capture_json_response worktree_result_json herdr worktree create \
		--cwd "$source_root" \
		--branch "$issue_branch" \
		--label "$workspace_label" \
		--no-focus \
		--json; then
		die "unable to create the issue worktree; existing work was preserved: $worktree_result_json"
	fi
	worktree_result_type=worktree_created
else
	created_issue_branch=0
	worktree_result_json=
	if ! capture_json_response worktree_result_json herdr worktree open \
		--cwd "$source_root" \
		--branch "$issue_branch" \
		--label "$workspace_label" \
		--no-focus \
		--json; then
		die "unable to open the existing issue worktree; existing work was preserved: $worktree_result_json"
	fi
	worktree_result_type=worktree_opened
fi

json_has_type "$worktree_result_json" "$worktree_result_type" ||
	die "unexpected Herdr $worktree_result_type response"
printf '%s\n' "$worktree_result_json" | jq -e \
	--arg branch "$issue_branch" \
	'.result.workspace.workspace_id as $workspace_id |
	 .result.tab.tab_id as $tab_id |
	 .result.root_pane.pane_id as $pane_id |
	 ($workspace_id | type == "string" and length > 0) and
	 ($tab_id | type == "string" and length > 0) and
	 ($pane_id | type == "string" and length > 0) and
	 .result.tab.workspace_id == $workspace_id and
	 .result.root_pane.workspace_id == $workspace_id and
	 .result.root_pane.tab_id == $tab_id and
	 (.result.root_pane.foreground_cwd | type == "string" and length > 0) and
	 .result.worktree.branch == $branch and
	 .result.worktree.is_bare == false and
	 .result.worktree.is_detached == false and
	 .result.worktree.is_prunable == false and
	 .result.worktree.is_linked_worktree == true and
	 (.result.worktree.path | type == "string" and length > 0)' >/dev/null 2>&1 ||
	die 'Herdr returned an invalid issue worktree or workspace identity'

workspace_id="$(printf '%s\n' "$worktree_result_json" | jq -r '.result.workspace.workspace_id')"
root_tab_id="$(printf '%s\n' "$worktree_result_json" | jq -r '.result.tab.tab_id')"
root_pane_id="$(printf '%s\n' "$worktree_result_json" | jq -r '.result.root_pane.pane_id')"
root_pane_cwd="$(printf '%s\n' "$worktree_result_json" | jq -r '.result.root_pane.foreground_cwd')"
worktree_path="$(printf '%s\n' "$worktree_result_json" | jq -r '.result.worktree.path')"
worktree_root="$(physical_directory "$worktree_path")" ||
	die 'Herdr returned an unavailable issue worktree path'
root_pane_directory="$(physical_directory "$root_pane_cwd")" ||
	die 'the issue workspace root pane has an unavailable live directory'
[ "$root_pane_directory" = "$worktree_root" ] ||
	die 'the issue workspace root pane is not at the issue worktree root'

load_worktree_state
[ "$worktree_count" -eq 1 ] ||
	worktree_conflict 'created or opened worktree is not the only canonical issue worktree'
if [ "$reusing_existing_worktree" -eq 1 ]; then
	[ "$worktree_root" = "$initial_worktree_root" ] ||
		worktree_conflict 'opened worktree path does not match the initially discovered issue worktree'
	[ "$listed_worktree_root" = "$initial_worktree_root" ] ||
		worktree_conflict 'post-open worktree path does not match the initially discovered issue worktree'
else
	[ "$listed_worktree_root" = "$worktree_root" ] ||
		worktree_conflict 'created worktree does not match the canonical issue worktree'
fi
[ "$target_open_workspace_id" = "$workspace_id" ] ||
	worktree_conflict 'canonical issue worktree is associated with another workspace'

worktree_branch="$(git -C "$worktree_root" symbolic-ref --quiet --short HEAD 2>/dev/null)" ||
	worktree_conflict 'canonical issue worktree is detached'
[ "$worktree_branch" = "$issue_branch" ] ||
	worktree_conflict "canonical issue worktree uses unexpected branch $worktree_branch"
worktree_common_directory="$(git_common_directory "$worktree_root")" ||
	worktree_conflict 'canonical issue worktree is not part of the selected repository'
[ "$worktree_common_directory" = "$source_common_directory" ] ||
	worktree_conflict 'canonical issue worktree belongs to another repository'

if [ "$created_issue_branch" -eq 1 ]; then
	created_branch_sha="$(git -C "$source_root" rev-parse --verify "${issue_branch_ref}^{commit}" 2>/dev/null)" ||
		die "unable to verify newly created issue branch $issue_branch"
	[ "$(printf '%s' "$created_branch_sha" | lowercase)" = "$(printf '%s' "$GH_DASH_SOURCE_SHA" | lowercase)" ] ||
		die "new issue branch $issue_branch does not match the captured source commit"
fi

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
		runtime_validation_error="agent pane is not at the canonical issue worktree: $pane_cwd"
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

focus_exact_agent() {
	local pane_id="$1" tab_id="$2" focus_json response_status=0

	capture_json_response focus_json herdr agent focus "$pane_id" || response_status=$?
	[ "$response_status" -eq 0 ] &&
		agent_identity_matches \
			"$focus_json" agent_info "$agent_alias" "$manager_kind" "$workspace_id" "$tab_id" "$pane_id"
}

finish_uncertain_status() {
	local detail="$1" safe_tab_id="${2:-}" safe_pane_id="${3:-}"

	printf 'WARNING: %s: %s\n' "$PROGRAM" "$detail" >&2
	if [ -n "$safe_pane_id" ]; then
		if focus_exact_agent "$safe_pane_id" "$safe_tab_id"; then
			finish_without_action "Agent status is uncertain; prompt not sent; exact $manager_label agent focused."
		fi
		printf 'WARNING: %s: unable to focus safely validated pane %s\n' \
			"$PROGRAM" "$safe_pane_id" >&2
		die "Agent status is uncertain; prompt not sent; focus failed."
	fi
	finish_without_action "Agent status is uncertain; prompt not sent."
}

finish_conflicting_identity() {
	local detail="$1"

	printf 'WARNING: %s: %s\n' "$PROGRAM" "$detail" >&2
	finish_without_action "Agent identity is ambiguous or conflicting; prompt not sent."
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
	finish_conflicting_identity "multiple complete agent identities match $workspace_label"
fi
if [ "$complete_agent_count" -eq 0 ] && [ "$related_agent_count" -gt 0 ]; then
	finish_conflicting_identity "partial or coordinate-sharing agent identities conflict with $workspace_label"
fi
if [ "$complete_agent_count" -eq 1 ] && [ "$related_agent_count" -ne 1 ]; then
	finish_conflicting_identity "the complete agent identity has conflicting related entries"
fi

agent_document=
agent_get_status=0
capture_json_response agent_document herdr agent get "$agent_alias" || agent_get_status=$?
if [ "$agent_get_status" -eq 125 ]; then
	die "agent lookup did not return exactly one JSON object; prompt not sent: $agent_document"
fi
if [ "$complete_agent_count" -eq 0 ]; then
	case "$agent_get_status" in
	0) finish_conflicting_identity "agent list and agent lookup disagree for alias $agent_alias" ;;
	*)
		json_is_error_only "$agent_document" agent_not_found ||
			finish_conflicting_identity "agent lookup failed for alias $agent_alias: $agent_document"
		;;
	esac
	agent_present=0
else
	[ "$agent_get_status" -eq 0 ] ||
		finish_conflicting_identity "agent lookup failed for listed alias $agent_alias: $agent_document"
	selected_agent_json="$(printf '%s\n' "$agent_list_json" | jq -c \
		--arg name "$agent_alias" \
		--arg workspace_id "$workspace_id" \
		--arg tab_id "$root_tab_id" \
		--arg pane_id "$root_pane_id" \
		'.result.agents[] | select(
			.name == $name and
			.agent == "codex" and
			.workspace_id == $workspace_id and
			.tab_id == $tab_id and
			.pane_id == $pane_id
		)')"
	selected_agent_name="$(printf '%s\n' "$selected_agent_json" | jq -r '.name')"
	selected_agent_kind="$(printf '%s\n' "$selected_agent_json" | jq -r '.agent')"
	selected_workspace_id="$(printf '%s\n' "$selected_agent_json" | jq -r '.workspace_id')"
	selected_tab_id="$(printf '%s\n' "$selected_agent_json" | jq -r '.tab_id')"
	selected_pane_id="$(printf '%s\n' "$selected_agent_json" | jq -r '.pane_id')"
	agent_identity_matches \
		"$agent_document" agent_info \
		"$selected_agent_name" "$selected_agent_kind" "$selected_workspace_id" \
		"$selected_tab_id" "$selected_pane_id" ||
		finish_conflicting_identity "agent list and lookup identities do not agree completely"
	agent_tab_id="$selected_tab_id"
	agent_pane_id="$selected_pane_id"
	validate_runtime_pane "$agent_tab_id" "$agent_pane_id" ||
		finish_conflicting_identity "$runtime_validation_error"
	agent_present=1
fi

send_issue_prompt() {
	local tab_id="$1" pane_id="$2" prompt_json prompt_status=0

	capture_json_response prompt_json herdr agent prompt "$pane_id" "$prompt" \
		--wait \
		--until working \
		--timeout 30000 9<&- || prompt_status=$?
	exec 9<&-
	[ "$prompt_status" -eq 0 ] ||
		prompt_failed "issue prompt command failed or returned an uncertain result: $prompt_json"
	agent_identity_matches \
		"$prompt_json" agent_prompted "$agent_alias" "$manager_kind" "$workspace_id" "$tab_id" "$pane_id" ||
		prompt_failed "issue prompt result did not identify the exact $manager_label agent"
	validate_runtime_pane "$tab_id" "$pane_id" ||
		prompt_failed "issue prompt completed but runtime identity became uncertain: $runtime_validation_error"
}

if [ "$agent_present" -eq 0 ]; then
	agent_start_json=
	for ((agent_start_attempt = 1; agent_start_attempt <= AGENT_START_TOTAL_ATTEMPTS; agent_start_attempt++)); do
		agent_start_status=0
		capture_json_response agent_start_json herdr agent start "$agent_alias" \
			--kind "$manager_kind" \
			--pane "$root_pane_id" \
			--timeout 30000 9<&- || agent_start_status=$?
		[ "$agent_start_status" -ne 0 ] || break
		[ "$agent_start_status" -ne 125 ] ||
			die "unable to start $manager_label for issue; prompt not sent: $agent_start_json"
		json_is_error_only "$agent_start_json" agent_pane_busy ||
			die "unable to start $manager_label for issue; prompt not sent: $agent_start_json"
		if [ "$agent_start_attempt" -eq "$AGENT_START_TOTAL_ATTEMPTS" ]; then
			die "exact target pane $root_pane_id did not become an available shell after $AGENT_START_TOTAL_ATTEMPTS total agent-start attempts; prompt not sent"
		fi
		sleep "$AGENT_START_RETRY_INTERVAL_SECONDS"
		validate_runtime_pane "$root_tab_id" "$root_pane_id" ||
			die "unable to retry $manager_label on exact target pane $root_pane_id: $runtime_validation_error; prompt not sent"
	done
	agent_identity_matches \
		"$agent_start_json" agent_started \
		"$agent_alias" "$manager_kind" "$workspace_id" "$root_tab_id" "$root_pane_id" ||
		finish_conflicting_identity "$manager_label started, but its returned identity conflicts with the expected issue agent"
	validate_runtime_pane "$root_tab_id" "$root_pane_id" ||
		finish_conflicting_identity "$manager_label started, but $runtime_validation_error"
	send_issue_prompt "$root_tab_id" "$root_pane_id"
	notify "Issue prompt sent. Started a new $manager_label agent for issue." "done"
	exit 0
fi

agent_status="$(printf '%s\n' "$agent_document" | jq -r \
	'if (.result.agent.agent_status | type) == "string" then .result.agent.agent_status else "__uncertain__" end')"
case "$agent_status" in
idle | done)
	send_issue_prompt "$agent_tab_id" "$agent_pane_id"
	if ! focus_exact_agent "$agent_pane_id" "$agent_tab_id"; then
		printf 'ERROR: %s: issue was resent, but the exact %s agent could not be focused\n' "$PROGRAM" "$manager_label" >&2
		notify "Issue resent to existing $manager_label agent, but focus failed." request
		exit 1
	fi
	notify "Issue resent to existing $manager_label agent and focused." "done"
	;;
working)
	if ! focus_exact_agent "$agent_pane_id" "$agent_tab_id"; then
		die "issue is already running and was not resent, but the exact $manager_label agent could not be focused"
	fi
	notify "Issue already running; prompt not resent." request
	;;
blocked)
	if ! focus_exact_agent "$agent_pane_id" "$agent_tab_id"; then
		die "issue agent is blocked and was not resent, but the exact $manager_label agent could not be focused"
	fi
	notify "Issue agent is blocked; prompt not resent." request
	;;
*)
	finish_uncertain_status \
		"agent $agent_alias returned missing, malformed, or unknown status: $agent_status" \
		"$agent_tab_id" \
		"$agent_pane_id"
	;;
esac
