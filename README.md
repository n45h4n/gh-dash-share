# gh-dash-share

```sh
git clone https://github.com/n45h4n/gh-dash-share.git
cd gh-dash-share
make setup
```

Complete the native login/integration steps offered by setup. If setup reports a
PATH action, run `export PATH="$HOME/.local/bin:$PATH"` in your current shell.
Then, from a terminal **outside Herdr**, open your target repository:

```sh
cd /path/to/your/repository
herdr --session my-project
```

Inside its shell pane, confirm you are in that repository and run:

```sh
ghd
```

Select an issue and press uppercase **I** to implement it through Codex. Select a
PR and press uppercase **I** to review it through Codex. The selected item must
belong to the source repository captured by `ghd`; the existing helpers enforce
that identity. Review Codex's native repository trust and permission prompts
yourself. Setup adds no model, effort, trust, or permission overrides.

If you already have a Herdr session, run this from an existing Herdr shell pane
to create and focus a workspace associated with the target checkout:

```sh
herdr workspace create --cwd /path/to/your/repository --label my-project --focus
```

Run `ghd` in the **new workspace's shell pane**. Do not launch nested `herdr`
inside an existing pane. These commands were checked against Herdr 0.9.3's native
help and its [onboarding guide](https://herdr.dev/agent-guide.md). A fresh session
may show Herdr's own onboarding screen before its shell appears.

## Bootstrap on macOS

Supported architectures are Intel x86_64 and Apple Silicon arm64. Git and Make
must exist before the clone/setup commands can run. Apple's Command Line Tools
provide them:

```sh
xcode-select --install
```

Complete Apple's installer. If tools are missing, setup uses Homebrew for only
the required packages. Install Homebrew first using its
[official instructions](https://brew.sh/) and apply the `brew shellenv` command
it prints for your machine. Setup does not install Homebrew or change your shell
startup files. It disables Homebrew's automatic update/cleanup and offers a
targeted upgrade only when an installed required formula is unsuitable; it does
not run a general `brew upgrade`.

## Bootstrap on native Ubuntu Server

Supported: Ubuntu 22.04 or newer, x86_64 or arm64. WSL and other Linux
distributions are outside this distribution's support. Start as a regular user
with sudo access, not as root:

```sh
sudo apt-get update
sudo apt-get install --no-install-recommends git make ca-certificates
```

These are unavoidable prerequisites for cloning and running `make setup`.
Setup offers apt installation for missing tools and the
[official GitHub CLI apt repository](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)
when GitHub CLI needs installation. It shows the packages and privileged changes
before asking for consent. Do not use `sudo make setup`.

For a remote server, SSH in normally, then run setup and Herdr on the server.
Herdr works through the terminal; a graphical desktop is unnecessary. Use a
terminal type installed on the server (for example `xterm-256color` if your
terminal's private terminfo is unavailable). You can detach from Herdr with its
default `ctrl+b`, then `q`, and reattach with `herdr --session my-project`.

## Installation and authentication

Setup checks tools first and reuses suitable installations. The runtime needs
Bash, Git 2.29+, Make, GitHub CLI 2.47+, jq, Python 3.9+, Codex, Herdr, and the standard
system utilities used by the dispatchers. Python supports diagnostics and safe
log handling; no pip packages are needed.
The GitHub CLI minimum avoids the community Ubuntu 2.45/2.46 releases' deprecated
API failures documented by [GitHub CLI](https://github.com/cli/cli/blob/trunk/docs/install_linux.md#ubuntu-community).
Curl and tar support the native installers. The selected Codex method needs no
Node/npm. Setup uses the
[upstream Codex standalone installer](https://learn.chatgpt.com/docs/codex/cli)
and [Herdr installer](https://herdr.dev/install.sh), placing new commands in
`~/.local/bin`. Existing installations whose capabilities fail doctor need
deliberate repair/update through their own installer; setup does not silently
upgrade unrelated software.

Every package install, privileged operation, login, and configuration change
requires explicit consent. With no interactive terminal, setup reports the
remaining action and exits unsuccessfully instead of waiting or assuming yes.
A pending login/integration/PATH action can leave a valid runtime installed;
rerunning setup completes onboarding. It is safe to run outside a target Git
repository and outside Herdr.

GitHub API authentication is checked quietly. To log in yourself:

```sh
gh auth login --hostname github.com --web
```

Follow the CLI's one-time device code and URL in a browser on your laptop if the
server is headless. GitHub CLI's transport choice is separate from access needed
by Git itself. Setup installs the extension, with consent, when it is missing:

```sh
gh extension install dlvhdr/gh-dash
```

Codex authentication stays in Codex:

```sh
codex login --device-auth
```

Enable device-code login in your ChatGPT security settings or workspace
permissions first, then open its URL and enter its one-time code in your own
browser. Where device login is unavailable, use native `codex login` with a
browser, or OpenAI's documented SSH callback forwarding flow. See
[official authentication guidance](https://learn.chatgpt.com/docs/auth). Do not
paste credentials into these scripts or share your authentication files. Setup
does not collect or log login output; the native CLIs control their own storage.

After establishing `${CODEX_HOME:-$HOME/.codex}`, setup offers:

```sh
herdr integration install codex
```

This changes Codex's native hook/configuration files: `herdr-agent-state.sh`,
`hooks.json`, and hook settings in `config.toml`. The native Herdr installer owns
this operation and preserves other settings; we do not implement a second
config editor. Review any native decisions yourself. Check with
`herdr integration status`.

## Git transport for PR reviews

The existing PR worker fetches GitHub's `sshUrl`, including when `origin` uses
HTTPS. With the default SSH transport, configure your own GitHub SSH key and
verify GitHub's host key using
[GitHub's SSH instructions](https://docs.github.com/en/authentication/connecting-to-github-with-ssh).
Then check in your target checkout:

```sh
git ls-remote "$(gh repo view --json sshUrl --jq .sshUrl)" HEAD
```

If you already use authenticated HTTPS, you can deliberately route this URL
through Git's native rewriting instead. These optional commands change your Git
credential configuration and the target repository's local config; review them
before running:

```sh
gh auth setup-git --hostname github.com
# In the target checkout; this also applies to its linked worktrees.
git config url."https://github.com/".insteadOf 'git@github.com:'
git ls-remote --get-url "$(gh repo view --json sshUrl --jq .sshUrl)"
git ls-remote "$(gh repo view --json sshUrl --jq .sshUrl)" HEAD
```

No SSH key is required when the effective transport is working HTTPS. Setup
does not change Git credential helpers, Git remotes, URL rewriting, or SSH
configuration. Doctor checks the effective transport only inside a target
Herdr context, using bounded, read-only `git ls-remote` and no terminal prompts.
With default SSH it requires pre-established host trust; it does not accept host
keys or create them as a side effect. A custom `GIT_SSH`, `GIT_SSH_COMMAND`, or
Git `core.sshCommand` needs manual transport verification; doctor skips executing
it and reports pending.

## What the workflows do

Issue **I** creates or reuses an `agent/issue-N` implementation worktree and
starts or reuses Codex through Herdr. It dispatches asynchronously and retains
the workers' existing identity, conflict, worktree reuse, server compatibility,
and diagnostic checks. The distribution contains only the issue implementation
and PR review integrations. It does not include Pepper/Factory workflows,
queues, Supervisors, or Docker sandbox infrastructure.

PR **I is not read-only**. It opens/reuses a PR review worktree and asks Codex to
review the selected PR. The existing prompt can publish or update the review
comment carrying the marker `<!-- gh-dash-codex-pr-review -->`. Under its existing
all-clear conditions it can also mark a draft PR ready. Review runs use your
own GitHub identity and permissions.

`ghd` captures the physical source root, canonical GitHub repository, branch,
commit SHA, and dirty status **before** opening gh-dash. New issue worktrees
contain the captured committed snapshot; uncommitted/untracked changes stay in
your source checkout. A dirty checkout produces a warning. Detached HEAD and
repositories without a commit are rejected. Later changes in the source checkout
do not replace the captured snapshot. Invoke `ghd` from the target checkout,
not from this distribution's clone.

The bundled config includes existing defaults and exactly the two custom I
bindings. Personal config files are preserved. `ghd` explicitly selects its
bundled config and refuses config override flags; ordinary flags such as
`--debug`, `--cpuprofile PATH`, `--help`, and `--version` are forwarded.

## Managed files, diagnostics, and updates

Setup copies the runtime into
`${XDG_DATA_HOME:-$HOME/.local/share}/gh-dash-share/`, with a
`.gh-dash-share-install` ownership marker, and installs the managed wrapper
`~/.local/bin/ghd`. The clone can move or be removed afterwards. Updates replace
only this project's marked runtime and exact managed wrapper after validating
the staged bundle. An unrelated installation directory or `ghd` command is
refused. Do not store personal files in the managed runtime.

Setup also manages only the missing dependency installations you approve,
GitHub CLI's extension installation, your explicitly requested native logins,
and the Codex directory/native Herdr integration above. On Ubuntu an approved
GitHub CLI installation writes
`/etc/apt/keyrings/githubcli-archive-keyring.gpg` and
`/etc/apt/sources.list.d/github-cli.list`. It never copies the maintainer's
credentials or personal config. Existing gh-dash, Herdr, shell and unrelated
Codex settings are preserved.

If `~/.local/bin` is missing from PATH, the exact action in your current shell is:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Add that line to your chosen shell's startup file yourself for future shells.
A child setup process cannot update its parent shell environment. Reopen/reload
the shell before retrying `ghd` if another command shadows it.

```sh
make doctor
```

Doctor separates **installed**, **authentication/setup pending**, and **ready to
launch from this context**. Outside Herdr it skips runtime-context checks and
explains how to enter a pane. Inside Herdr it checks the inherited route, active
compatible server, Codex detection manifest, target repository, and Git transport.
It never creates worktrees, sends prompts, writes PR comments, or marks PRs ready.
It returns nonzero for required failed/pending checks.

Dispatcher diagnostics live in
`${XDG_STATE_HOME:-$HOME/.local/state}/gh-dash-codex-issue/` and
`${XDG_STATE_HOME:-$HOME/.local/state}/gh-dash-codex-pr-review/`. Dispatch reports
the relevant log path. Herdr's default-session logs are under
`~/.config/herdr/`; named-session logs live under its `sessions/NAME/` directory.

To update from your retained clone:

```sh
git pull --ff-only
make setup
```

`make help` lists the four standalone targets. `make test` uses disposable homes
and Git repositories with mocked external tools; it needs Bash, Git, Make, jq,
and Python 3.9+. It does not install packages or authenticate/run agents.

## Maintainer: development

This repository is now the source of truth for gh-dash-share. Make changes here
to the launcher, setup/doctor scripts, gh-dash configuration, workers, and tests.
No dotfiles checkout or export step is required.

Keep the existing runtime-relative directory layout when updating the workers.

Before committing changes, review the diff and run the focused checks:

```sh
git diff --check
make test
# For changes to the launcher or setup/doctor shell scripts:
bash -n bin/ghd scripts/setup.sh scripts/doctor.sh
shellcheck -x bin/ghd scripts/setup.sh scripts/doctor.sh
```

Commit and push reviewed changes to this repository. Users update their clone
with `git pull --ff-only`, then run `make setup` to refresh the installed copy.
There is no background updater or automatic cross-repository sync.

Installation instructions were checked against upstream documentation and native
CLI help on 2026-10-08. Mocked macOS/Ubuntu coverage is not native verification.
Native macOS and Ubuntu Server installation and live Herdr/Codex onboarding still
need verification by users on those hosts.
