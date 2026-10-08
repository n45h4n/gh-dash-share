#!/usr/bin/env bash
set -euo pipefail

bundle="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
runtime="${XDG_DATA_HOME:-$HOME/.local/share}/gh-dash-share"
bin_directory="$HOME/.local/bin"
launcher="$bin_directory/ghd"
parent_path="$PATH"
install_marker='gh-dash-share-v1'
stage=''
backup=''
launcher_stage=''
replacement_started=0
replacement_complete=0
pending=0

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

notice() {
	printf '%s\n' "$*"
}

consent() {
	local answer
	notice "$1"
	if [ ! -t 0 ] || [ ! -t 1 ]; then
		notice 'Consent pending: rerun make setup in an interactive terminal. No approval was assumed.'
		return 1
	fi
	printf 'Proceed? [y/N] '
	IFS= read -r answer || return 1
	case "$answer" in
	y | Y | yes | YES) return 0 ;;
	*) notice 'Declined; existing configuration was preserved.'; return 1 ;;
	esac
}

cleanup() {
	local status=$?
	trap - EXIT HUP INT TERM
	if [ "$replacement_complete" -eq 0 ] && { [ "$replacement_started" -eq 1 ] || { [ -n "$backup" ] && [ -d "$backup/runtime" ]; }; }; then
		if [ -d "$runtime" ] && [ ! -L "$runtime" ] &&
			[ "$(cat "$runtime/.gh-dash-share-install" 2>/dev/null || true)" = "$install_marker" ]; then
			rm -rf -- "$runtime"
		fi
		if [ -n "$backup" ] && [ -d "$backup/runtime" ]; then
			mv -- "$backup/runtime" "$runtime" || notice "Recovery required: restore $backup/runtime to $runtime"
		fi
	fi
	[ -z "$stage" ] || rm -rf -- "$stage"
	[ -z "$launcher_stage" ] || rm -f -- "$launcher_stage"
	if [ -n "$backup" ] && [ ! -d "$backup/runtime" ]; then
		rmdir -- "$backup" 2>/dev/null || true
	fi
	exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

detect_platform() {
	local kernel architecture
	kernel="$(uname -s)"
	architecture="$(uname -m)"
	case "$architecture" in
	x86_64 | amd64 | arm64 | aarch64) ;;
	*) die "unsupported architecture: $architecture (supported: x86_64 and arm64)" ;;
	esac
	case "$kernel" in
	Darwin) platform=macos ;;
	Linux)
		[ -r /etc/os-release ] || die 'cannot identify Linux distribution; native Ubuntu Server 22.04+ is supported'
		# This file is host-owned OS metadata, not a user-provided configuration.
		# shellcheck disable=SC1091
		. /etc/os-release
		[ "${ID:-}" = ubuntu ] || die 'unsupported Linux distribution; native Ubuntu Server 22.04+ is supported'
		case "${VERSION_ID:-}" in
		[2-9][0-9].*) [ "${VERSION_ID%%.*}" -ge 22 ] || die 'Ubuntu 22.04 or later is required' ;;
		*) die 'Ubuntu 22.04 or later is required' ;;
		esac
		if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
			die 'WSL is outside this distribution; use native Ubuntu Server or macOS'
		fi
		platform=ubuntu
		;;
	*) die "unsupported operating system: $kernel (supported: macOS and native Ubuntu Server)" ;;
	esac
}

check_destinations() {
	local existing quoted expected
	case "$HOME:$runtime" in
	/*:/*) ;;
	*) die 'HOME and XDG_DATA_HOME must be absolute paths' ;;
	esac
	[ "$(id -u)" != 0 ] || die 'run make setup as your regular user, never with sudo or as root'
	if [ -e "$runtime" ] || [ -L "$runtime" ]; then
		[ -d "$runtime" ] && [ ! -L "$runtime" ] && [ -O "$runtime" ] ||
			die "refusing unrelated or unsafe installation path: $runtime"
		[ -f "$runtime/.gh-dash-share-install" ] && [ ! -L "$runtime/.gh-dash-share-install" ] &&
			[ "$(cat "$runtime/.gh-dash-share-install")" = "$install_marker" ] ||
			die "refusing unrelated existing installation directory: $runtime"
	fi
	printf -v quoted '%q' "$runtime/bin/ghd"
	expected="$(printf '#!/usr/bin/env bash\n# gh-dash-share managed launcher v1\nexec %s "$@"\n' "$quoted")"
	if [ -e "$launcher" ] || [ -L "$launcher" ]; then
		[ -f "$launcher" ] && [ ! -L "$launcher" ] && [ -O "$launcher" ] &&
			[ "$(cat "$launcher")" = "$expected" ] || die "refusing unrelated existing launcher: $launcher"
	fi
	existing="$(command -v ghd 2>/dev/null || true)"
	[ -z "$existing" ] || [ "$existing" = "$launcher" ] ||
		die "an unrelated ghd command is already on PATH: $existing; resolve the conflict before setup"
}

python_is_suitable() {
	command -v python3 >/dev/null 2>&1 &&
		python3 -I -c 'import sys; raise SystemExit(sys.version_info < (3, 9))' >/dev/null 2>&1
}

git_is_suitable() {
	command -v git >/dev/null 2>&1 || return 1
	git --version | awk 'NR == 1 {split($3,v,"."); exit !(v[1] > 2 || (v[1] == 2 && v[2] >= 29))}'
}

gh_is_suitable() {
	command -v gh >/dev/null 2>&1 || return 1
	gh --version | awk 'NR == 1 {split($3,v,"."); exit !(v[1] > 2 || (v[1] == 2 && v[2] >= 47))}'
}

install_dependencies() {
	local command_name installer directory package proposal
	local packages=()
	local installs=() upgrades=()
	for command_name in bash awk sed grep tr mkdir rmdir rm date chmod sleep nohup stat env mktemp cp mv cat dirname uname id; do
		command -v "$command_name" >/dev/null 2>&1 || die "required system utility missing: $command_name; repair OS prerequisites first"
	done
	for command_name in make jq curl tar; do
		if ! command -v "$command_name" >/dev/null 2>&1; then
			packages[${#packages[@]}]="$command_name"
		fi
	done
	git_is_suitable || packages[${#packages[@]}]=git
	python_is_suitable || packages[${#packages[@]}]=python3
	if [ "$platform" = macos ]; then
		gh_is_suitable || packages[${#packages[@]}]=gh
		if [ "${#packages[@]}" -gt 0 ]; then
			command -v brew >/dev/null 2>&1 || die 'Homebrew is required for missing dependencies; follow the macOS bootstrap instructions in README.md'
			proposal='Homebrew changes for missing/unsuitable dependencies only:'
			for package in "${packages[@]}"; do
				if brew list --versions "$package" >/dev/null 2>&1; then
					upgrades[${#upgrades[@]}]="$package"
					proposal="$proposal brew upgrade $package;"
				else
					installs[${#installs[@]}]="$package"
					proposal="$proposal brew install $package;"
				fi
			done
			if consent "$proposal No general brew update/upgrade or shell edits."; then
				if [ "${#installs[@]}" -gt 0 ]; then
					HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install "${installs[@]}"
				fi
				if [ "${#upgrades[@]}" -gt 0 ]; then
					HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew upgrade "${upgrades[@]}"
				fi
			else
				die "dependencies pending: ${packages[*]}"
			fi
		fi
	else
		[ -r /etc/ssl/certs/ca-certificates.crt ] || packages[${#packages[@]}]=ca-certificates
		if [ "${#packages[@]}" -gt 0 ]; then
			command -v sudo >/dev/null 2>&1 || die 'sudo is required to install missing Ubuntu packages; ask the host administrator'
			if consent "Use sudo apt-get update, then sudo apt-get install --no-install-recommends ${packages[*]}. This changes system packages."; then
				sudo apt-get update
				sudo apt-get install -y --no-install-recommends "${packages[@]}"
			else
				die "dependencies pending: ${packages[*]}"
			fi
		fi
		if ! gh_is_suitable; then
			command -v sudo >/dev/null 2>&1 || die 'sudo is required for the official GitHub CLI apt repository'
			if consent 'Install GitHub CLI from its official apt repository. This writes /etc/apt/keyrings/githubcli-archive-keyring.gpg and /etc/apt/sources.list.d/github-cli.list, then runs sudo apt-get update and sudo apt-get install gh.'; then
				install_github_cli_ubuntu
			else
				die 'GitHub CLI installation pending'
			fi
		fi
	fi
	python_is_suitable || die 'python3 still resolves to a version below 3.9; fix PATH to use the installed Python and rerun'
	git_is_suitable || die 'git must be version 2.29 or later; fix PATH to the suitable installation and rerun'
	gh_is_suitable || die 'gh must be version 2.47 or later; fix PATH to the suitable installation and rerun'
	for command_name in codex herdr; do
		if ! command -v "$command_name" >/dev/null 2>&1; then
			case "$command_name" in
			codex) installer='https://chatgpt.com/codex/install.sh'; directory="${CODEX_HOME:-$HOME/.codex}" ;;
			herdr) installer='https://herdr.dev/install.sh'; directory="$bin_directory" ;;
			esac
			if consent "Install $command_name using its upstream native installer ($installer). Commands go in $bin_directory; $command_name also manages its native files under $directory. No Node/npm or shell configuration changes are needed."; then
				install_native_tool "$command_name" "$installer"
			else
				die "$command_name installation pending"
			fi
		fi
		"$command_name" --version >/dev/null 2>&1 || die "$command_name is installed but cannot run; repair it using its native installer"
	done
}

install_github_cli_ubuntu() {
	local scratch repository_line
	scratch="$(mktemp -d "${TMPDIR:-/tmp}/gh-dash-share-gh.XXXXXX")"
	if ! curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$scratch/keyring.gpg"; then
		rm -rf -- "$scratch"
		return 1
	fi
	repository_line="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main"
	printf '%s\n' "$repository_line" >"$scratch/github-cli.list"
	sudo mkdir -p -m 755 /etc/apt/keyrings /etc/apt/sources.list.d
	sudo install -m 644 "$scratch/keyring.gpg" /etc/apt/keyrings/githubcli-archive-keyring.gpg
	sudo install -m 644 "$scratch/github-cli.list" /etc/apt/sources.list.d/github-cli.list
	rm -rf -- "$scratch"
	sudo apt-get update
	sudo apt-get install -y --no-install-recommends gh
}

install_native_tool() {
	local tool="$1" url="$2" scratch status=0
	[ ! -e "$bin_directory/$tool" ] && [ ! -L "$bin_directory/$tool" ] ||
		die "a $tool file exists outside PATH at $bin_directory/$tool; add it to PATH or resolve it before installation"
	scratch="$(mktemp -d "${TMPDIR:-/tmp}/gh-dash-share-native.XXXXXX")"
	if curl -fsSL "$url" -o "$scratch/install.sh"; then
		case "$tool" in
		codex)
			# The native installer skips its optional Codex launch in this mode.
			# Keeping its bin on PATH also prevents its shell-profile editor.
			PATH="$bin_directory:$PATH" CODEX_INSTALL_DIR="$bin_directory" CODEX_NON_INTERACTIVE=true sh "$scratch/install.sh" || status=$?
			;;
		herdr) HERDR_INSTALL_DIR="$bin_directory" sh "$scratch/install.sh" || status=$? ;;
		esac
	else
		status=1
	fi
	rm -rf -- "$scratch"
	[ "$status" -eq 0 ] || die "$tool installation failed; rerun make setup after resolving the upstream error"
	PATH="$PATH:$bin_directory"
	export PATH
}

install_bundle() {
	local input source relative quoted
	local inputs=(Makefile README.md .gitignore bin/ghd gh-dash/config.yml scripts/setup.sh scripts/doctor.sh scripts/doctor.py
		scripts/integrations/gh-dash/gh-dash-codex-issue-dispatch.sh
		scripts/integrations/gh-dash/gh-dash-codex-issue.sh
		scripts/integrations/gh-dash/gh-dash-codex-pr-review.sh
		scripts/integrations/gh-dash/gh-dash-codex-pr-review-dispatch.sh)
	mkdir -p -- "$(dirname "$runtime")" "$bin_directory"
	stage="$(mktemp -d "$(dirname "$runtime")/.gh-dash-share-stage.XXXXXX")"
	for input in "${inputs[@]}" 'tests/*.py'; do
		case "$input" in
		tests/*)
			# Expand only Python source files, never caches or local runtime state.
			for source in "$bundle"/$input; do
				[ -f "$source" ] && [ ! -L "$source" ] || die "missing or unsafe bundle source: $source"
				relative="${source#"$bundle"/}"
				mkdir -p -- "$stage/$(dirname "$relative")"
				cp -p -- "$source" "$stage/$relative"
			done
			;;
		*)
			[ -f "$bundle/$input" ] && [ ! -L "$bundle/$input" ] || die "missing or unsafe bundle source: $input"
			mkdir -p -- "$stage/$(dirname "$input")"
			cp -p -- "$bundle/$input" "$stage/$input"
			;;
		esac
	done
	chmod 755 "$stage/bin/ghd" "$stage/scripts/setup.sh" "$stage/scripts/doctor.sh" "$stage/scripts/integrations/gh-dash/"*.sh
	printf '%s\n' "$install_marker" >"$stage/.gh-dash-share-install"
	"$stage/scripts/doctor.sh" --bundle "$stage" --integrity-only || die 'replacement bundle failed validation; existing installation preserved'
	launcher_stage="$(mktemp "$bin_directory/.gh-dash-share-launcher.XXXXXX")"
	printf -v quoted '%q' "$runtime/bin/ghd"
	printf '#!/usr/bin/env bash\n# gh-dash-share managed launcher v1\nexec %s "$@"\n' "$quoted" >"$launcher_stage"
	chmod 755 "$launcher_stage"
	bash -n "$launcher_stage"
	# Installers can take minutes; recheck ownership before replacing anything.
	check_destinations
	backup="$(mktemp -d "$(dirname "$runtime")/.gh-dash-share-backup.XXXXXX")"
	if [ -d "$runtime" ]; then
		mv -- "$runtime" "$backup/runtime"
	fi
	replacement_started=1
	mv -- "$stage" "$runtime"
	stage=''
	mv -f -- "$launcher_stage" "$launcher"
	launcher_stage=''
	replacement_complete=1
	if [ -d "$backup/runtime" ]; then
		rm -rf -- "$backup/runtime"
	fi
	rmdir -- "$backup"
	backup=''
	notice "Installed: $runtime"
	notice "Launcher: $launcher"
}

configure_native_tools() {
	local codex_directory integration
	if ! gh auth status --hostname github.com >/dev/null 2>&1; then
		if consent 'GitHub authentication is pending. Run gh auth login --hostname github.com --web now? Follow its native device-code instructions in a browser on this or another machine. Choose Git transport yourself; setup will not configure Git credentials.'; then
			gh auth login --hostname github.com --web || pending=1
		else
			notice 'Remaining action: gh auth login --hostname github.com --web'
			pending=1
		fi
	fi
	if ! gh dash --version >/dev/null 2>&1; then
		if consent 'Install the gh-dash extension with gh extension install dlvhdr/gh-dash? Existing gh-dash configuration is preserved; ghd uses the bundled config explicitly.'; then
			gh extension install dlvhdr/gh-dash || pending=1
		else
			notice 'Remaining action: gh extension install dlvhdr/gh-dash'
			pending=1
		fi
	fi
	if ! codex login status >/dev/null 2>&1; then
		if consent 'Codex authentication is pending. Run codex login --device-auth now? Enable device-code login in ChatGPT security settings/workspace permissions first, then use a browser on this or another machine. Authentication stays in the native CLI; do not paste credentials here.'; then
			codex login --device-auth || pending=1
		else
			notice 'Remaining action: codex login --device-auth'
			pending=1
		fi
	fi
	codex_directory="${CODEX_HOME:-$HOME/.codex}"
	case "$codex_directory" in
	/*) ;;
	*) die 'CODEX_HOME must be an absolute path before integration installation' ;;
	esac
	if [ ! -d "$codex_directory" ]; then
		if [ -e "$codex_directory" ] || [ -L "$codex_directory" ]; then
			die "Codex configuration path is not a directory: $codex_directory"
		fi
		if consent "Create the Codex configuration directory $codex_directory for its native Herdr integration?"; then
			(umask 077; mkdir -p -- "$codex_directory")
		else
			notice "Remaining action: create $codex_directory, then herdr integration install codex"
			pending=1
			return
		fi
	fi
	integration="$(herdr integration status 2>/dev/null || true)"
	if ! printf '%s\n' "$integration" | grep -q '^codex: current '; then
		if consent "Run herdr integration install codex? This native installer changes $codex_directory/herdr-agent-state.sh, hooks.json, and config.toml (enabling hooks and retiring its deprecated Codex hook flag). Review native trust decisions yourself. Other settings remain owned by their native tools."; then
			herdr integration install codex || pending=1
		else
			notice 'Remaining action: herdr integration install codex'
			pending=1
		fi
	fi
}

[ "$#" -eq 0 ] || die 'usage: scripts/setup.sh (run make setup)'
detect_platform
check_destinations
install_dependencies
install_bundle
configure_native_tools
case ":$parent_path:" in
*":$bin_directory:"*) ;;
*)
	# shellcheck disable=SC2016
	notice 'For this shell, run exactly: export PATH="$HOME/.local/bin:$PATH"'
	notice 'Setup is a child process and cannot change its parent shell environment. Add that line to your chosen shell startup file yourself for future shells.'
	pending=1
	;;
esac
"$runtime/scripts/doctor.sh" --bundle "$runtime" || pending=1
if [ "$pending" -ne 0 ]; then
	notice 'Installed; authentication/setup actions remain pending. Resolve the actions above and rerun make setup or make doctor.'
	exit 1
fi
notice 'Installation and authentication checks passed. Enter a Herdr pane for your target checkout, then run ghd.'
