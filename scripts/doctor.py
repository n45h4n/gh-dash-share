#!/usr/bin/env python3
"""Read-only installation and inherited Herdr route checks. No dispatch."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def output(argv, environment=None):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=15, env=environment)
        return result.stdout if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def authenticated(argv):
    # Native authentication status may contain credential details; never collect it.
    try:
        return subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=20).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def integrity(bundle):
    workers = bundle / "scripts/integrations/gh-dash"
    required = [bundle / "Makefile", bundle / "README.md",
                bundle / "gh-dash/config.yml", bundle / "scripts/doctor.py"]
    executables = [bundle / "bin/ghd", bundle / "scripts/setup.sh", bundle / "scripts/doctor.sh"]
    executables += [workers / name for name in (
        "gh-dash-codex-issue.sh", "gh-dash-codex-issue-dispatch.sh",
        "gh-dash-codex-pr-review.sh", "gh-dash-codex-pr-review-dispatch.sh")]
    for path in required + executables:
        if path.is_symlink() or not path.is_file():
            raise ValueError("missing regular bundle file: " + str(path))
    for path in executables:
        if not os.access(path, os.X_OK):
            raise ValueError("bundle entrypoint is not executable: " + str(path))
        if output(["bash", "-n", str(path)]) is None:
            raise ValueError("bundle entrypoint failed Bash syntax check: " + str(path))
    config = (bundle / "gh-dash/config.yml").read_text()
    if (len(re.findall(r"^\s+- key: I\s*$", config, re.M)) != 2
            or config.count("gh-dash-codex-pr-review.sh") != 1
            or config.count("gh-dash-codex-issue-dispatch.sh") != 1
            or any(token in config for token in (
                "--factory", "$HOME/dotfiles", "diffnav", "repoPaths:", "pager:",
                "universal:", "octo", "tuicr", "lazygit", "sandbox"))):
        raise ValueError("bundle config does not contain the two isolated I routes")
    compile((bundle / "scripts/doctor.py").read_bytes(), str(bundle / "scripts/doctor.py"), "exec")


def route_check():
    def document(argv, kind=None):
        raw = output(["herdr", *argv])
        try:
            value = json.loads(raw)
        except (TypeError, ValueError):
            raise ValueError("Herdr returned no valid JSON for " + " ".join(argv))
        if not isinstance(value, dict) or value.get("error") is not None:
            raise ValueError("Herdr route check failed: " + " ".join(argv))
        if kind is not None and (
            set(value) != {"id", "result"} or not isinstance(value.get("id"), str)
            or not value["id"] or not isinstance(value.get("result"), dict)
            or value["result"].get("type") != kind
        ):
            raise ValueError("Herdr response type mismatch: " + " ".join(argv))
        return value

    names = ("HERDR_SOCKET_PATH", "HERDR_WORKSPACE_ID", "HERDR_TAB_ID", "HERDR_PANE_ID")
    if not all(os.environ.get(name) for name in names):
        raise ValueError("incomplete inherited Herdr socket/workspace/tab/pane context")
    status = document(["status", "--json"])
    server = status.get("server", {})
    if not isinstance(server, dict) or server.get("running") is not True or server.get("compatible") is not True:
        raise ValueError("inherited Herdr server is not running or is incompatible")
    workspace, tab, pane = (os.environ[name] for name in names[1:])
    documents = (
        (["workspace", "get", workspace], "workspace_info", "workspace", {"workspace_id": workspace}),
        (["tab", "get", tab], "tab_info", "tab", {"tab_id": tab, "workspace_id": workspace}),
        (["pane", "get", pane], "pane_info", "pane",
         {"pane_id": pane, "tab_id": tab, "workspace_id": workspace}),
    )
    for argv, kind, field, identity in documents:
        actual = document(argv, kind).get("result", {}).get(field, {})
        if not isinstance(actual, dict) or any(actual.get(key) != value for key, value in identity.items()):
            raise ValueError("inherited Herdr " + field + " identity mismatch")
    manifests = document(["server", "agent-manifests", "--json"], "agent_manifest_status")
    entries = manifests.get("result", {}).get("manifests")
    if not isinstance(entries, list) or not all(
        isinstance(item, dict) and isinstance(item.get("agent"), str) and item["agent"]
        and (item.get("active_version") is None
             or isinstance(item["active_version"], str) and item["active_version"])
        for item in entries
    ):
        raise ValueError("invalid Herdr agent detection manifest response")
    codex = [entry for entry in entries if entry.get("agent") == "codex"]
    if len(codex) != 1 or not codex[0].get("active_version"):
        raise ValueError("Herdr server has no active Codex detection manifest")
    root = output(["git", "rev-parse", "--show-toplevel"])
    if not root:
        raise ValueError("enter the target Git repository in this Herdr pane before running ghd")
    if not output(["git", "symbolic-ref", "--quiet", "--short", "HEAD"]):
        raise ValueError("detached HEAD is not supported")
    if not output(["git", "rev-parse", "--verify", "HEAD^{commit}"]):
        raise ValueError("target repository has no committed snapshot")
    raw = output(["env", "-u", "GH_REPO", "gh", "repo", "view", "--json", "nameWithOwner,sshUrl"])
    try:
        repository = json.loads(raw)
        fetch_url = repository["sshUrl"]
        if not isinstance(repository.get("nameWithOwner"), str) or not repository["nameWithOwner"]:
            raise ValueError()
        if not isinstance(fetch_url, str) or not fetch_url.startswith(("git@github.com:", "ssh://git@github.com/")):
            raise ValueError()
    except (TypeError, ValueError, KeyError):
        raise ValueError("cannot resolve the target GitHub repository and PR fetch URL")
    # The canonical PR worker requests sshUrl. Git's configured insteadOf rules
    # may route it over HTTPS; inspect that effective URL before requiring SSH.
    effective_url = output(["git", "ls-remote", "--get-url", fetch_url])
    if not effective_url:
        raise ValueError("cannot inspect the PR Git transport")
    environment = os.environ.copy()
    environment["GIT_TERMINAL_PROMPT"] = "0"
    if effective_url.startswith(("git@", "ssh://")):
        if shutil.which("ssh") is None:
            raise ValueError("PR Git transport requires ssh; install OpenSSH or configure HTTPS rewriting as in README")
        if ("GIT_SSH_COMMAND" in environment or "GIT_SSH" in environment
                or output(["git", "config", "--get", "core.sshCommand"])):
            raise ValueError("custom SSH transport requires manual verification; doctor will not execute a custom command that could change host trust")
        # Freeze existing host trust during this diagnostic; native SSH can add
        # address/key records even after a strictly authenticated connection.
        environment["GIT_SSH_COMMAND"] = (
            "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes"
            " -o UpdateHostKeys=no -o CheckHostIP=no"
        )
    if output(["git", "ls-remote", fetch_url, "HEAD"], environment) is None:
        raise ValueError("PR Git transport authentication/trust pending; follow README and verify git ls-remote yourself")
    print("OK: PR Git transport authenticated (read-only ls-remote)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--integrity-only", action="store_true")
    modes.add_argument("--installation-only", action="store_true")
    args = parser.parse_args()
    bundle = args.bundle or Path(os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local/share")) / "gh-dash-share"
    failures = []

    def check(ok, success, failure):
        print(("OK: " + success) if ok else ("FAIL: " + failure))
        if not ok:
            failures.append(failure)
        return ok

    try:
        integrity(bundle)
        print("OK: installed bundle/config/entrypoint integrity: " + str(bundle))
    except (OSError, ValueError, SyntaxError) as error:
        check(False, "", "bundle integrity: " + str(error))
    if args.integrity_only:
        return int(bool(failures))

    for name in ("bash", "git", "make", "gh", "jq", "python3", "codex", "herdr", "curl", "tar",
                 "env", "tr", "mkdir", "rmdir", "rm", "date", "chmod", "sleep", "nohup", "stat"):
        check(shutil.which(name), name + " available", name + " missing; run make setup")
    for name in ("git", "gh", "jq", "codex", "herdr"):
        text = output([name, "--version"])
        check(bool(text and text.strip()), name + " version responds", name + " version check failed")
    git_version = output(["git", "--version"]) or ""
    match = re.search(r"git version (\d+)\.(\d+)", git_version)
    check(match and tuple(map(int, match.groups())) >= (2, 29),
          "Git supports --no-write-fetch-head", "Git >= 2.29 required for PR fetch isolation")
    gh_version = output(["gh", "--version"]) or ""
    match = re.search(r"gh version (\d+)\.(\d+)", gh_version)
    check(match and tuple(map(int, match.groups())) >= (2, 47),
          "GitHub CLI meets supported version", "GitHub CLI >= 2.47 required; older Ubuntu versions have deprecated API failures")
    for argv, tokens, label in (
        (["codex", "login", "--help"], ("--device-auth",), "Codex device login"),
        (["herdr", "worktree", "create", "--help"], ("--base", "--cwd", "--branch"), "Herdr worktree create"),
        (["herdr", "worktree", "open", "--help"], ("--cwd", "--path"), "Herdr worktree open"),
        (["herdr", "agent", "start", "--help"], ("--kind", "--pane", "--timeout"), "Herdr agent start"),
        (["herdr", "agent", "prompt", "--help"], ("--wait", "--timeout"), "Herdr agent prompt"),
        (["herdr", "integration", "install", "--help"], ("codex",), "Herdr Codex integration installer"),
        (["gh", "dash", "--help"], ("--config",), "gh-dash extension"),
    ):
        text = output(argv) or ""
        check(all(token in text for token in tokens), label + " available", label + " capability missing")
    installation_failed = bool(failures)
    print("Installation: " + ("incomplete" if installation_failed else "installed"))
    if args.installation_only:
        return int(bool(failures))

    check(authenticated(["gh", "auth", "status", "--hostname", "github.com"]),
          "GitHub authenticated", "GitHub authentication/setup pending: gh auth login --hostname github.com --web")
    check(authenticated(["codex", "login", "status"]),
          "Codex authenticated", "Codex authentication/setup pending: codex login --device-auth")
    integration = output(["herdr", "integration", "status"]) or ""
    lines = [line for line in integration.splitlines() if line.startswith("codex:")]
    check(len(lines) == 1 and lines[0].startswith("codex: current "),
          "Herdr Codex integration current", "Herdr Codex integration setup pending: herdr integration install codex")
    launcher = Path.home() / ".local/bin/ghd"
    active = shutil.which("ghd")
    expected_wrapper = output([
        "bash", "-c", 'printf \'#!/usr/bin/env bash\n# gh-dash-share managed launcher v1\nexec %q "$@"\n\' "$1"',
        "gh-dash-share-doctor", str(bundle / "bin/ghd"),
    ])
    try:
        managed = (not launcher.is_symlink() and launcher.read_text() == expected_wrapper
                   and (bundle / ".gh-dash-share-install").read_text() == "gh-dash-share-v1\n")
    except OSError:
        managed = False
    check(active and Path(active).resolve() == launcher.resolve() and managed,
          "managed launcher resolves on PATH", 'launcher PATH/setup pending: export PATH="$HOME/.local/bin:$PATH"; run make setup if ghd is absent')
    setup_pending = bool(failures) and not installation_failed
    print("Authentication/setup: " + ("pending" if setup_pending or installation_failed else "complete"))

    if any(os.environ.get(name) for name in (
        "HERDR_SOCKET_PATH", "HERDR_WORKSPACE_ID", "HERDR_TAB_ID", "HERDR_PANE_ID"
    )):
        try:
            route_check()
            print("OK: inherited Herdr route, compatible server, source repository and Codex detection")
        except (OSError, ValueError) as error:
            check(False, "", "runtime context: " + str(error))
        if not failures:
            print("Runtime: ready to launch from this context")
        else:
            print("Runtime: context checks failed or setup pending")
    else:
        print("Runtime-context checks not performed: outside Herdr. In a target checkout run herdr, then run ghd in its pane.")
    print("Git transport authentication is separate from CLI login; see README before the first PR review fetch.")
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())
