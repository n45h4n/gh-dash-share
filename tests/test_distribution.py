"""Exercise the shipped bundle in disposable homes with inert external CLIs.

No test uses the developer's gh/Codex/Herdr configuration or a live agent.
The same suite is shipped with the distribution and runs through make test.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


BUNDLE = Path(__file__).resolve().parents[1]
REAL_PATH = os.environ.get("PATH", os.defpath)
REAL_GIT = shutil.which("git")

# External mutations are inert and limited to explicitly tested onboarding.
# Even a regression in setup/doctor cannot publish or dispatch a live agent.
MOCK = r'''#!PYTHON
import json, os, pathlib, shutil, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["MOCK_BIN"])
entry = {"tool": name, "args": args, "cwd": os.getcwd(),
         "env": {k: v for k, v in os.environ.items()
                 if k.startswith("GH_DASH_SOURCE_") or k in ("GH_REPO", "DOTFILES_DIR", "GIT_SSH_COMMAND")}}
with open(os.environ["MOCK_LOG"], "a") as stream:
    stream.write(json.dumps(entry) + "\n")
def fail(message="forbidden external action"):
    print(message, file=sys.stderr)
    sys.exit(91)
def envelope(kind, key, value):
    print(json.dumps({"id": "test", "result": {"type": kind, key: value}}))
if name == "uname":
    print(os.environ.get("MOCK_ARCH", "arm64") if args == ["-m"]
          else os.environ.get("MOCK_OS", "Darwin"))
elif name == "gh":
    if args == ["--version"]:
        print("gh version 2.88.1 (test)")
    elif args[:2] == ["repo", "view"]:
        if "GH_REPO" in os.environ:
            fail("inherited GH_REPO contaminated repository resolution")
        if "nameWithOwner,sshUrl" in args:
            print(json.dumps({"nameWithOwner": "friend/target", "sshUrl": "git@github.com:friend/target.git"}))
        else:
            print("friend/target")
    elif args[:2] == ["auth", "status"]:
        if os.environ.get("MOCK_GH_AUTH") == "pending" and not (root / "gh-authenticated").exists():
            fail("AUTH_SECRET_SENTINEL should never be displayed")
        print("github.com: logged in")
    elif args[:2] == ["auth", "login"] and "--help" in args:
        print("--web --git-protocol --hostname")
    elif args == ["auth", "login", "--hostname", "github.com", "--web"]:
        print("Native mock device login: open github.com/login/device in another browser")
        (root / "gh-authenticated").write_text("yes")
    elif args[:2] == ["extension", "list"]:
        if os.environ.get("MOCK_EXTENSION") != "missing":
            print("gh dash\tdlvhdr/gh-dash\tv4.15.0")
    elif args[:2] == ["extension", "install"]:
        if args != ["extension", "install", "dlvhdr/gh-dash"]:
            fail()
        (root / "extension-installed").write_text("yes")
    elif args and args[0] == "dash":
        if "--version" in args:
            if os.environ.get("MOCK_EXTENSION") == "missing" and not (root / "extension-installed").exists():
                fail("gh-dash unavailable")
            print("gh-dash version 4.15.0")
        elif "--help" in args:
            print("--config --repo --debug --version")
        else:
            if os.environ.get("MOCK_BINDINGS"):
                config = pathlib.Path(args[args.index("--config") + 1]).read_text()
                commands = re.findall(r'command:\s*>[-+]?\s*\n\s*([^\n]+)', config)
                if len(commands) != 2:
                    fail("mock could not parse both bundled I commands")
                for command in commands:
                    command = command.replace("{{.RepoName}}", "friend/target")
                    command = command.replace("{{.PrNumber}}", "7").replace("{{.IssueNumber}}", "8")
                    completed = subprocess.run(["bash", "-c", command], check=False)
                    if completed.returncode:
                        sys.exit(completed.returncode)
    else:
        fail()
elif name == "codex":
    if args == ["--version"]:
        print("codex-cli 0.115.0")
    elif args == ["--help"]:
        print("Codex CLI: login logout --version")
    elif args[:2] == ["login", "status"]:
        if os.environ.get("MOCK_CODEX_AUTH") == "pending" and not (root / "codex-authenticated").exists():
            fail("AUTH_SECRET_SENTINEL should never be displayed")
        print("Logged in using ChatGPT")
    elif args[:1] == ["login"] and "--help" in args:
        print("--device-auth --with-api-key")
    elif args == ["login", "--device-auth"]:
        print("Native mock device login: open the Codex device page in another browser")
        (root / "codex-authenticated").write_text("yes")
    else:
        fail()
elif name == "herdr":
    issue_mode = os.environ.get("MOCK_ISSUE_WORKFLOW") == "1"
    issue_file = root / "issue-workflow.json"
    issue_state = json.loads(issue_file.read_text()) if issue_file.exists() else {}
    def issue_worktree():
        return {"branch": "agent/issue-8", "path": issue_state["path"],
                "is_bare": False, "is_detached": False, "is_prunable": False,
                "is_linked_worktree": True, "open_workspace_id": "issue-ws"}
    def issue_agent():
        return {"name": "target-8", "agent": "codex", "workspace_id": "issue-ws",
                "tab_id": "issue-tab", "pane_id": os.environ.get("MOCK_AGENT_PANE", "issue-pane"),
                "agent_status": os.environ.get("MOCK_AGENT_STATUS", issue_state.get("agent_status", "working"))}
    if args == ["--version"] or args == ["version"]:
        print("herdr version 0.20.0")
    elif "--help" in args:
        print("integration install status list codex --json --cwd --workspace --pane --kind --timeout --wait --base --branch --path server agent-manifests")
    elif args[:1] == ["integration"] and args[1:2] in (["status"], ["list"]):
        if os.environ.get("MOCK_INTEGRATION") == "pending" and not (root / "herdr-integrated").exists():
            fail("Codex integration not installed")
        print("codex: current (test fixture)")
    elif args == ["integration", "install", "codex"]:
        directory = pathlib.Path(os.environ.get("CODEX_HOME", str(pathlib.Path.home() / ".codex")))
        directory.mkdir(parents=True, exist_ok=True)
        with (directory / "config.toml").open("a") as stream:
            stream.write("# Mock native Herdr integration\n")
        (directory / "herdr-agent-state.sh").write_text("# Native mock hook\n")
        (directory / "hooks.json").write_text("{}\n")
        (root / "herdr-integrated").write_text("yes")
    elif args[:1] == ["notification"]:
        pass
    elif args[:1] == ["status"]:
        print(json.dumps({"server": {"running": True,
            "compatible": os.environ.get("MOCK_SERVER") != "incompatible"}}))
    elif args[:2] == ["workspace", "get"]:
        envelope("workspace_info", "workspace", {"workspace_id": args[2] if issue_mode else "ws"})
    elif args[:2] == ["tab", "get"]:
        envelope("tab_info", "tab", {"tab_id": args[2] if issue_mode else "tab",
            "workspace_id": "issue-ws" if issue_mode and args[2] == "issue-tab" else "ws"})
    elif args[:2] == ["pane", "get"]:
        target = issue_mode and args[2] == "issue-pane"
        envelope("pane_info", "pane", {"pane_id": "wrong" if os.environ.get("MOCK_ROUTE") == "wrong" else args[2] if issue_mode else "pane",
            "tab_id": "issue-tab" if target else "tab", "workspace_id": "issue-ws" if target else "ws",
            "foreground_cwd": issue_state["path"] if target else os.getcwd()})
    elif args[:2] == ["server", "agent-manifests"]:
        envelope("agent_manifest_status", "manifests", [{"agent": "codex",
            "active_version": None if os.environ.get("MOCK_MANIFEST") == "missing" else "1"}])
    elif issue_mode and args[:2] == ["worktree", "list"]:
        source = args[args.index("--cwd") + 1]
        print(json.dumps({"id": "test", "result": {"type": "worktree_list",
            "source": {"source_checkout_path": source, "source_workspace_id": "ws"},
            "worktrees": [issue_worktree()] if "path" in issue_state else []}}))
    elif issue_mode and args[:2] in (["worktree", "create"], ["worktree", "open"]):
        source = pathlib.Path(args[args.index("--cwd") + 1]).resolve()
        if not source.is_relative_to(root.parent):
            fail("worktree fixture escaped disposable test root")
        if args[args.index("--branch") + 1] != "agent/issue-8":
            fail("unexpected issue branch")
        if args[1] == "create":
            destination = root.parent / "issue worktree with spaces"
            subprocess.run([os.environ["REAL_GIT"], "-C", str(source), "worktree", "add",
                            str(destination), "agent/issue-8"], check=True, capture_output=True)
            issue_state["path"] = str(destination)
            issue_file.write_text(json.dumps(issue_state))
        elif "path" not in issue_state:
            fail("cannot open absent issue worktree")
        print(json.dumps({"id": "test", "result": {"type": "worktree_created" if args[1] == "create" else "worktree_opened",
            "workspace": {"workspace_id": "issue-ws"},
            "tab": {"tab_id": "issue-tab", "workspace_id": "issue-ws"},
            "root_pane": {"pane_id": "issue-pane", "tab_id": "issue-tab", "workspace_id": "issue-ws",
                          "foreground_cwd": issue_state["path"]},
            "worktree": issue_worktree()}}))
    elif issue_mode and args[:2] == ["agent", "list"]:
        envelope("agent_list", "agents", [issue_agent()] if issue_state.get("agent_started") else [])
    elif issue_mode and args[:2] == ["agent", "get"]:
        if not issue_state.get("agent_started"):
            print(json.dumps({"id": "test", "error": {"code": "agent_not_found"}}))
            sys.exit(1)
        envelope("agent_info", "agent", issue_agent())
    elif issue_mode and args[:2] == ["agent", "start"]:
        if args != ["agent", "start", "target-8", "--kind", "codex", "--pane", "issue-pane", "--timeout", "30000"]:
            fail("unexpected issue agent launch")
        issue_state["agent_started"] = True
        issue_state["agent_status"] = "idle"
        issue_file.write_text(json.dumps(issue_state))
        envelope("agent_started", "agent", issue_agent())
    elif issue_mode and args[:2] in (["agent", "prompt"], ["agent", "focus"]):
        if args[2] != "issue-pane" or not issue_state.get("agent_started"):
            fail("issue agent action escaped validated pane")
        if args[1] == "prompt":
            issue_state["agent_status"] = "working"
            issue_file.write_text(json.dumps(issue_state))
        envelope("agent_prompted" if args[1] == "prompt" else "agent_info", "agent", issue_agent())
    else:
        fail()
elif name in ("brew", "sudo", "apt-get"):
    if name == "brew" and args == ["--version"]:
        print("Homebrew 4.6.0")
    elif name == "sudo" and args[:1] == ["mkdir"] and all(
            value in ("mkdir", "-p", "-m", "755", "/etc/apt/keyrings", "/etc/apt/sources.list.d") for value in args):
        pass
    elif "install" in args or "upgrade" in args or "update" in args:
        if os.environ.get("MOCK_INSTALL_FAIL"):
            fail("simulated interrupted package installation")
        if "gh" in args:
            shutil.copyfile(root / "mock-cli", root / "gh")
            (root / "gh").chmod(0o755)
    else:
        fail()
elif name == "git":
    if "ls-remote" in args:
        if os.environ.get("MOCK_TRANSPORT") == "pending":
            fail("mock Git transport authentication failure")
        print(os.environ.get("MOCK_EFFECTIVE_URL", "git@github.com:friend/target.git")
              if "--get-url" in args else "0123456789abcdef0123456789abcdef01234567\tHEAD")
        sys.exit(0)
    if any(arg in args for arg in ("worktree", "push", "fetch", "clone", "commit", "checkout", "reset")):
        fail("unexpected Git mutation")
    os.execv(os.environ["REAL_GIT"], [os.environ["REAL_GIT"], *args])
elif name == "nohup":
    # The existing dispatchers own asynchronous execution; retain their execution
    # route but make the backend reach only its missing-Herdr safety check.
    result = subprocess.run(args, check=False)
    sys.exit(result.returncode)
elif name == "curl":
    if "-o" not in args:
        fail("unexpected download")
    url = next((argument for argument in args if argument.startswith("https://")), "")
    destination = pathlib.Path(args[args.index("-o") + 1])
    if url in ("https://chatgpt.com/codex/install.sh", "https://herdr.dev/install.sh"):
        tool = "codex" if "chatgpt.com" in url else "herdr"
        variable = "CODEX_INSTALL_DIR" if tool == "codex" else "HERDR_INSTALL_DIR"
        script = '#!/bin/sh\nset -eu\n'
        if os.environ.get("MOCK_INSTALL_FAIL"):
            script += 'echo "simulated interrupted native installation" >&2\nexit 81\n'
        else:
            script += 'destination="${' + variable + ':?}"\n'
            if tool == "codex":
                script += '[ "$CODEX_NON_INTERACTIVE" = true ]\n'
                script += 'case ":$PATH:" in *":$destination:"*) ;; *) exit 82 ;; esac\n'
                script += 'mkdir -p "$HOME/.codex"\n'
            script += 'mkdir -p "$destination"\n'
            script += 'cp "$MOCK_BIN/mock-cli" "$destination/' + tool + '"\n'
            script += 'chmod 755 "$destination/' + tool + '"\n'
        destination.write_text(script)
    elif url == "https://cli.github.com/packages/githubcli-archive-keyring.gpg":
        destination.write_bytes(b"MOCK official keyring\n")
    else:
        fail("unexpected upstream URL")
elif name == "dpkg":
    if args == ["--print-architecture"]:
        print("amd64")
    else:
        fail()
else:
    fail()
'''.replace("#!PYTHON", "#!" + sys.executable).replace(
    "import json, os, pathlib, shutil, subprocess, sys",
    "import json, os, pathlib, re, shutil, subprocess, sys",
)


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="gh-dash-share tests ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / "home with spaces"
        self.home.mkdir()
        self.bundle = self.root / "relocated bundle with spaces"
        shutil.copytree(BUNDLE, self.bundle, ignore=shutil.ignore_patterns(".git", "__pycache__"))
        self.mock = self.root / "mock bin"
        self.mock.mkdir()
        self.log = self.root / "calls.jsonl"
        mock_script = self.mock / "mock-cli"
        mock_script.write_text(MOCK)
        mock_script.chmod(0o755)
        for name in ("gh", "codex", "herdr", "uname", "brew", "curl", "sudo", "apt-get", "git", "nohup", "ssh", "dpkg"):
            (self.mock / name).symlink_to(mock_script.name)
        # A controlled PATH makes genuinely missing dependencies reproducible.
        utilities = ("bash sh env make jq python3 tar mkdir cp mv rm chmod cat find readlink dirname "
                     "basename mktemp sed awk tr stat date sleep touch ln id ps cmp head cut sort uniq "
                     "wc xargs grep install tee gzip unzip which du rmdir")
        for name in utilities.split():
            executable = sys.executable if name == "python3" else shutil.which(name, path=REAL_PATH)
            if executable and not (self.mock / name).exists():
                (self.mock / name).symlink_to(executable)
        self.env = {"HOME": str(self.home), "XDG_DATA_HOME": str(self.home / "data with spaces"),
                    "XDG_STATE_HOME": str(self.home / "state"), "XDG_CONFIG_HOME": str(self.home / "config"),
                    "PATH": str(self.home / ".local/bin") + os.pathsep + str(self.mock), "MOCK_BIN": str(self.mock), "MOCK_LOG": str(self.log),
                    "REAL_GIT": REAL_GIT or "", "LANG": "C", "TERM": "dumb",
                    "PYTHONDONTWRITEBYTECODE": "1"}
        self.installed = Path(self.env["XDG_DATA_HOME"]) / "gh-dash-share"
        self.wrapper = self.home / ".local/bin/ghd"

    def run_script(self, script, *args, cwd=None, env=None):
        return subprocess.run([str(script), *map(str, args)], cwd=cwd or self.root,
                              env=dict(self.env, **(env or {})), stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=30)

    def setup(self, **env):
        return self.run_script(self.bundle / "scripts/setup.sh", env=env)

    def interactive_setup(self, answer="n", **overrides):
        master, slave = pty.openpty()
        process = subprocess.Popen([str(self.bundle / "scripts/setup.sh")], cwd=self.root,
                                   env=dict(self.env, **overrides), stdin=slave,
                                   stdout=slave, stderr=slave, close_fds=True)
        os.close(slave)
        output = bytearray()
        deadline = time.monotonic() + 30
        try:
            # More than one prompt may be needed; every answer remains explicit.
            os.write(master, ((answer + "\n") * 12).encode())
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        block = os.read(master, 65536)
                    except OSError:
                        break
                    if not block:
                        break
                    output.extend(block)
                if process.poll() is not None and not ready:
                    break
            if process.poll() is None:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    self.fail("interactive setup did not finish; output: " + output.decode(errors="replace"))
            process.wait(timeout=5)
        finally:
            os.close(master)
            if process.poll() is None:
                process.kill()
                process.wait()
        return subprocess.CompletedProcess(process.args, process.returncode,
                                           output.decode(errors="replace"), "")

    def calls(self, tool=None):
        records = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return [record for record in records if tool is None or record["tool"] == tool]

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def install(self):
        self.assert_success(self.interactive_setup("y"))
        self.assertTrue(self.installed.is_dir())
        self.assertTrue(self.wrapper.is_file())
        self.env["PATH"] = str(self.wrapper.parent) + os.pathsep + str(self.mock)

    def source_repo(self, commit=True):
        repo = self.root / "target repo with spaces"
        repo.mkdir()
        def git(*args):
            return subprocess.run([REAL_GIT, "-C", str(repo), *args], env=dict(self.env, PATH=REAL_PATH),
                                  check=True, capture_output=True, text=True).stdout.strip()
        git("init", "-b", "feature/friend")
        git("config", "user.name", "Distribution Test")
        git("config", "user.email", "test@example.invalid")
        git("remote", "add", "origin", "https://github.com/friend/target.git")
        if commit:
            (repo / "source.txt").write_text("committed content\n")
            git("add", "source.txt")
            git("commit", "-m", "Fixture")
        return repo, git

    def issue_environment(self, repo, git, **overrides):
        return {"HERDR_SOCKET_PATH": str(self.home / "test.sock"), "HERDR_WORKSPACE_ID": "ws",
                "HERDR_TAB_ID": "tab", "HERDR_PANE_ID": "pane", "MOCK_ISSUE_WORKFLOW": "1",
                "GH_DASH_SOURCE_ROOT": str(repo), "GH_DASH_SOURCE_REPO": "friend/target",
                "GH_DASH_SOURCE_BRANCH": "feature/friend", "GH_DASH_SOURCE_SHA": git("rev-parse", "HEAD"),
                "GH_DASH_SOURCE_DIRTY": "0", **overrides}

    def assert_no_actions(self, allow_onboarding=False):
        for record in self.calls():
            args, tool = record["args"], record["tool"]
            if "--help" in args:
                continue
            if tool == "gh":
                self.assertNotIn(args[:2], (["pr", "comment"], ["pr", "ready"]))
                if not allow_onboarding:
                    self.assertNotEqual(args[:2], ["auth", "login"])
            if tool == "herdr":
                self.assertNotIn(args[:2], (["worktree", "create"], ["agent", "prompt"], ["agent", "start"]))
                if not allow_onboarding:
                    self.assertNotEqual(args[:2], ["integration", "install"] if "--help" not in args else [])
            if tool == "codex":
                self.assertNotEqual(args[:1], ["exec"])
            if tool == "git":
                self.assertNotIn("worktree", args)

    def test_exact_config_and_runtime_permissions(self):
        config = (self.bundle / "gh-dash/config.yml").read_text()
        self.assertEqual(re.findall(r"^([A-Za-z][A-Za-z0-9_]*):", config, re.M), ["defaults", "keybindings"])
        self.assertEqual(re.findall(r"key:\s*(\S+)", config), ["I", "I"])
        self.assertIn("gh-dash-codex-pr-review.sh", config)
        self.assertIn("gh-dash-codex-issue-dispatch.sh", config)
        for forbidden in ("--factory", "diffnav", "lazygit", "tuicr", "octo", "queue", "prepare", "sandbox", "$HOME/dotfiles", "repoPaths"):
            self.assertNotIn(forbidden, config)
        for relative in ("bin/ghd", "scripts/setup.sh", "scripts/doctor.sh",
                         "scripts/integrations/gh-dash/gh-dash-codex-issue.sh",
                         "scripts/integrations/gh-dash/gh-dash-codex-issue-dispatch.sh",
                         "scripts/integrations/gh-dash/gh-dash-codex-pr-review.sh",
                         "scripts/integrations/gh-dash/gh-dash-codex-pr-review-dispatch.sh"):
            self.assertTrue(os.access(self.bundle / relative, os.X_OK), relative)

    def test_clean_install_and_idempotent_second_run(self):
        self.install()
        before = (self.installed / "bin/ghd").read_bytes()
        self.assert_success(self.setup())
        self.assertEqual(before, (self.installed / "bin/ghd").read_bytes())
        self.assert_no_actions()

    def test_clean_bundle_and_update_remove_factory_assets(self):
        self.install()
        self.assertFalse((self.bundle / "tools/pepper").exists())
        obsolete = ("tools/pepper/lib/factory.py", "SOURCE_REVISION",
                    "scripts/integrations/gh-dash/gh_dash_codex_issue_context.py")
        for relative in obsolete:
            self.assertFalse((self.bundle / relative).exists(), relative)
            self.assertFalse((self.installed / relative).exists(), relative)
            file = self.installed / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("obsolete fixture\n")
        self.assert_success(self.setup())
        self.assertFalse((self.installed / "tools/pepper").exists())
        for relative in obsolete:
            self.assertFalse((self.installed / relative).exists(), relative)
        self.assert_no_actions()

    def test_runtime_survives_source_clone_removal(self):
        self.install()
        shutil.rmtree(self.bundle)
        repo, _ = self.source_repo()
        self.assert_success(self.run_script(self.wrapper, cwd=repo))
        dash = [c for c in self.calls("gh") if c["args"][:1] == ["dash"] and "--config" in c["args"]][-1]
        self.assertEqual(dash["env"]["DOTFILES_DIR"], str(self.installed))

    def test_preserves_existing_personal_configuration(self):
        settings = [self.home / ".zshrc", self.home / ".bashrc", self.home / ".gitconfig",
                    self.home / ".codex/config.toml", self.home / ".config/gh-dash/config.yml",
                    self.home / ".config/herdr/config.toml"]
        for file in settings:
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("# personal setting sentinel\n")
        self.install()
        for file in settings:
            self.assertEqual(file.read_text(), "# personal setting sentinel\n")
        self.assert_no_actions()

    def test_refuses_unrelated_runtime_directory(self):
        self.installed.mkdir(parents=True)
        sentinel = self.installed / "unrelated"
        sentinel.write_text("preserve me")
        result = self.setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(), "preserve me")
        self.assertFalse(self.wrapper.exists())

    def test_refuses_unrelated_launcher(self):
        self.wrapper.parent.mkdir(parents=True)
        self.wrapper.write_text("#!/bin/sh\necho unrelated\n")
        self.wrapper.chmod(0o755)
        result = self.setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.wrapper.read_text(), "#!/bin/sh\necho unrelated\n")

    def test_refuses_unrelated_command_on_path_and_symlinked_runtime(self):
        command = self.mock / "ghd"
        command.write_text("#!/bin/sh\necho unrelated\n")
        command.chmod(0o755)
        self.assertNotEqual(self.setup().returncode, 0)
        self.assertEqual(command.read_text(), "#!/bin/sh\necho unrelated\n")
        command.unlink()
        unrelated = self.root / "unrelated installation"
        unrelated.mkdir()
        self.installed.parent.mkdir(parents=True)
        self.installed.symlink_to(unrelated, target_is_directory=True)
        self.assertNotEqual(self.setup().returncode, 0)
        self.assertTrue(self.installed.is_symlink())
        self.assertEqual(list(unrelated.iterdir()), [])

    def test_noninteractive_missing_dependency_never_installs(self):
        (self.mock / "gh").unlink()
        result = self.setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.installed.exists())
        self.assertFalse(any("install" in c["args"] for c in self.calls("brew")))
        self.assert_no_actions()

    def test_declined_dependency_installation(self):
        (self.mock / "gh").unlink()
        result = self.interactive_setup("n")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any("install" in c["args"] for c in self.calls("brew")))
        self.assertFalse(self.installed.exists())

    def test_failed_install_then_successful_rerun(self):
        (self.mock / "gh").unlink()
        result = self.interactive_setup("y", MOCK_INSTALL_FAIL="1")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.installed.exists())
        self.assertFalse(self.wrapper.exists())
        self.assert_success(self.interactive_setup("y"))
        self.assertTrue(self.installed.is_dir())

    def test_native_installers_require_consent_and_recover_after_failure(self):
        for name in ("codex", "herdr"):
            (self.mock / name).unlink()
        shell = self.home / ".bashrc"
        shell.write_text("# preserve shell configuration\n")
        self.assertNotEqual(self.setup().returncode, 0)
        self.assertFalse(self.calls("curl"))
        self.assertNotEqual(self.interactive_setup("n").returncode, 0)
        self.assertFalse(self.calls("curl"))
        self.assertNotEqual(self.interactive_setup("y", MOCK_INSTALL_FAIL="1").returncode, 0)
        self.assertFalse(self.installed.exists())
        self.assert_success(self.interactive_setup("y"))
        self.assertTrue((self.wrapper.parent / "codex").is_file())
        self.assertTrue((self.wrapper.parent / "herdr").is_file())
        self.assertEqual(shell.read_text(), "# preserve shell configuration\n")
        urls = [argument for call in self.calls("curl") for argument in call["args"] if argument.startswith("https://")]
        self.assertIn("https://chatgpt.com/codex/install.sh", urls)
        self.assertIn("https://herdr.dev/install.sh", urls)
        self.assertFalse(self.calls("npm"))
        self.assertFalse(self.calls("node"))
        self.assert_no_actions()

    def test_native_auth_and_integration_delegate_after_consent(self):
        directory = self.home / ".codex"
        directory.mkdir()
        config = directory / "config.toml"
        config.write_text('# Existing native setting\nmodel = "user-choice"\n')
        result = self.interactive_setup("y", MOCK_GH_AUTH="pending", MOCK_CODEX_AUTH="pending", MOCK_INTEGRATION="pending")
        self.assert_success(result)
        self.assertTrue(config.read_text().startswith('# Existing native setting\nmodel = "user-choice"\n'))
        self.assertTrue((directory / "herdr-agent-state.sh").is_file())
        self.assertIn("hooks.json", result.stdout)
        self.assertIn("config.toml", result.stdout)
        self.assertIn(["auth", "login", "--hostname", "github.com", "--web"], [c["args"] for c in self.calls("gh")])
        self.assertIn(["login", "--device-auth"], [c["args"] for c in self.calls("codex")])
        self.assertIn(["integration", "install", "codex"], [c["args"] for c in self.calls("herdr")])
        self.assert_no_actions(allow_onboarding=True)

    def test_replacement_validation_preserves_working_install(self):
        self.install()
        before = (self.installed / "bin/ghd").read_bytes()
        launcher = self.bundle / "scripts/integrations/gh-dash/gh-dash-codex-issue.sh"
        launcher.write_text("#!/usr/bin/env bash\nif\n")
        result = self.setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, (self.installed / "bin/ghd").read_bytes())

    def test_mocked_ubuntu_setup(self):
        if not Path("/etc/os-release").exists() or not re.search(r'^ID=["\']?ubuntu', Path("/etc/os-release").read_text(), re.M):
            self.skipTest("Ubuntu detection reads the native os-release file")
        self.assert_success(self.interactive_setup("y", MOCK_OS="Linux", MOCK_ARCH="x86_64"))
        self.assert_no_actions()

    def test_mocked_ubuntu_official_gh_install_uses_only_inert_privileged_tools(self):
        if not Path("/etc/os-release").exists() or not re.search(r'^ID=["\']?ubuntu', Path("/etc/os-release").read_text(), re.M):
            self.skipTest("Ubuntu detection reads the native os-release file")
        (self.mock / "gh").unlink()
        self.assert_success(self.interactive_setup("y", MOCK_OS="Linux", MOCK_ARCH="x86_64"))
        self.assertTrue((self.mock / "gh").exists())
        self.assertTrue(any("https://cli.github.com/packages/githubcli-archive-keyring.gpg" in c["args"] for c in self.calls("curl")))
        actions = [c["args"] for c in self.calls("sudo")]
        self.assertIn(["apt-get", "install", "-y", "--no-install-recommends", "gh"], actions)
        self.assertTrue(any("/etc/apt/sources.list.d/github-cli.list" in args for args in actions))
        self.assert_no_actions()

    def test_missing_path_installs_but_reports_parent_shell_action(self):
        (self.home / ".codex").mkdir()
        result = self.setup(PATH=str(self.mock))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.installed.is_dir())
        self.assertIn('export PATH="$HOME/.local/bin:$PATH"', result.stdout)
        self.assert_no_actions()

    def test_noninteractive_auth_and_integration_are_pending_without_actions(self):
        (self.home / ".codex").mkdir()
        result = self.setup(MOCK_GH_AUTH="pending", MOCK_CODEX_AUTH="pending", MOCK_INTEGRATION="pending")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.installed.is_dir())
        self.assertIn("pending", result.stdout.lower())
        self.assertNotIn("AUTH_SECRET_SENTINEL", result.stdout + result.stderr)
        self.assert_no_actions()

    def test_extension_requires_consent_and_installs_only_requested_extension(self):
        (self.home / ".codex").mkdir()
        result = self.setup(MOCK_EXTENSION="missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls("gh") and any(c["args"][:2] == ["extension", "install"] for c in self.calls("gh")))
        self.assert_success(self.interactive_setup("y", MOCK_EXTENSION="missing"))
        extensions = [c["args"] for c in self.calls("gh") if c["args"][:2] == ["extension", "install"]]
        self.assertEqual(extensions, [["extension", "install", "dlvhdr/gh-dash"]])

    def test_unsupported_platform_and_architecture(self):
        for overrides in ({"MOCK_OS": "FreeBSD"}, {"MOCK_ARCH": "sparc64"}):
            with self.subTest(**overrides):
                self.assertNotEqual(self.setup(**overrides).returncode, 0)
                self.assertFalse(self.installed.exists())

    def test_launcher_captures_full_physical_snapshot_and_isolates_inheritance(self):
        self.install()
        repo, git = self.source_repo()
        link = self.root / "symlink to target"
        link.symlink_to(repo, target_is_directory=True)
        self.assert_success(self.run_script(self.wrapper, "--debug", cwd=link,
            env={"DOTFILES_DIR": "/unrelated/dotfiles", "GH_REPO": "wrong/repository"}))
        dash = [c for c in self.calls("gh") if c["args"][:1] == ["dash"] and "--config" in c["args"]][-1]
        self.assertEqual(dash["env"]["DOTFILES_DIR"], str(self.installed))
        self.assertEqual({k: dash["env"][k] for k in ("GH_DASH_SOURCE_ROOT", "GH_DASH_SOURCE_REPO",
            "GH_DASH_SOURCE_BRANCH", "GH_DASH_SOURCE_SHA", "GH_DASH_SOURCE_DIRTY")}, {
            "GH_DASH_SOURCE_ROOT": str(repo), "GH_DASH_SOURCE_REPO": "friend/target",
            "GH_DASH_SOURCE_BRANCH": "feature/friend", "GH_DASH_SOURCE_SHA": git("rev-parse", "HEAD"),
            "GH_DASH_SOURCE_DIRTY": "0"})
        self.assertIn("--debug", dash["args"])
        self.assertEqual(dash["args"][dash["args"].index("--config") + 1], str(self.installed / "gh-dash/config.yml"))

    def test_dirty_warning_and_captured_commit(self):
        self.install()
        repo, git = self.source_repo()
        captured = git("rev-parse", "HEAD")
        (repo / "source.txt").write_text("uncommitted content\n")
        result = self.run_script(self.wrapper, cwd=repo)
        self.assert_success(result)
        self.assertIn("dirty", result.stderr)
        self.assertIn("uncommitted", result.stderr)
        dash = [c for c in self.calls("gh") if c["args"][:1] == ["dash"] and "--config" in c["args"]][-1]
        self.assertEqual(dash["env"]["GH_DASH_SOURCE_SHA"], captured)
        self.assertEqual(dash["env"]["GH_DASH_SOURCE_DIRTY"], "1")

    def test_launcher_rejects_no_repo_detached_and_missing_commit(self):
        self.install()
        result = self.run_script(self.wrapper)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Git repository", result.stderr)
        repo, git = self.source_repo()
        git("checkout", "--detach", "HEAD")
        result = self.run_script(self.wrapper, cwd=repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("detached", result.stderr)
        shutil.rmtree(repo)
        empty, _ = self.source_repo(commit=False)
        result = self.run_script(self.wrapper, cwd=empty)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("commit", result.stderr)

    def test_config_replacement_arguments_are_rejected(self):
        self.install()
        repo, _ = self.source_repo()
        for arguments in (("--config", "other.yml"), ("--config=other.yml",), ("-c", "other.yml"), ("-cother.yml",)):
            with self.subTest(arguments=arguments):
                self.assertNotEqual(self.run_script(self.wrapper, *arguments, cwd=repo).returncode, 0)

    def test_both_installed_binding_routes_stop_safely_without_herdr(self):
        self.install()
        shutil.rmtree(self.bundle)
        repo, _ = self.source_repo()
        self.assert_success(self.run_script(self.wrapper, cwd=repo, env={"MOCK_BINDINGS": "1",
            "DOTFILES_DIR": "/unavailable/dotfiles"}))
        deadline = time.monotonic() + 5
        logs = []
        while time.monotonic() < deadline:
            logs = list(Path(self.env["XDG_STATE_HOME"]).glob("gh-dash-codex-*/*.log"))
            if len(logs) == 2 and all("HERDR_SOCKET_PATH" in file.read_text() for file in logs):
                break
            time.sleep(0.02)
        self.assertEqual(len(logs), 2)
        for file in logs:
            self.assertIn("HERDR_SOCKET_PATH", file.read_text())
            self.assertNotIn("/unavailable/dotfiles", file.read_text())
        self.assert_no_actions()

    def test_installed_dispatchers_resolve_bundle_without_dotfiles_environment(self):
        self.install()
        shutil.rmtree(self.bundle)
        repo, _ = self.source_repo()
        directory = self.installed / "scripts/integrations/gh-dash"
        for name in ("gh-dash-codex-issue-dispatch.sh", "gh-dash-codex-pr-review-dispatch.sh"):
            self.assert_success(self.run_script(directory / name, "friend/target", "8", cwd=repo))
        deadline = time.monotonic() + 5
        logs = []
        while time.monotonic() < deadline:
            logs = list(Path(self.env["XDG_STATE_HOME"]).glob("gh-dash-codex-*/*.log"))
            if len(logs) == 2 and all("HERDR_SOCKET_PATH" in file.read_text() for file in logs):
                break
            time.sleep(0.02)
        self.assertEqual(len(logs), 2)
        for file in logs:
            self.assertIn("HERDR_SOCKET_PATH", file.read_text())
            self.assertNotIn(str(self.home / "dotfiles"), file.read_text())
        self.assert_no_actions()

    def test_issue_starts_at_captured_commit_and_reuses_idle_agent(self):
        self.install()
        shutil.rmtree(self.bundle)
        repo, git = self.source_repo()
        route = self.issue_environment(repo, git, PYTHONPATH="/unavailable/dotfiles")
        captured = route["GH_DASH_SOURCE_SHA"]
        (repo / "source.txt").write_text("newer committed source\n")
        git("commit", "-am", "Advance source after dashboard launch")
        (repo / "source.txt").write_text("uncommitted source stays here\n")
        launcher = self.installed / "scripts/integrations/gh-dash/gh-dash-codex-issue.sh"
        self.log.write_text("")
        result = self.run_script(launcher, "friend/target", "8", cwd=repo, env=route)
        self.assert_success(result)
        worktree = self.root / "issue worktree with spaces"
        self.assertEqual(git("rev-parse", "agent/issue-8"), captured)
        self.assertEqual((worktree / "source.txt").read_text(), "committed content\n")
        self.assertEqual((repo / "source.txt").read_text(), "uncommitted source stays here\n")
        starts = [c for c in self.calls("herdr") if c["args"][:2] == ["agent", "start"]]
        self.assertEqual(len(starts), 1)
        prompts = [c for c in self.calls("herdr") if c["args"][:2] == ["agent", "prompt"]]
        self.assertEqual([c["args"] for c in prompts], [["agent", "prompt", "issue-pane",
            "Fetch issue friend/target#8 and use its body as the prompt.", "--wait", "--until", "working", "--timeout", "30000"]])
        (worktree / "source.txt").write_text("existing issue edits\n")
        result = self.run_script(launcher, "friend/target", "8", cwd=repo,
                                 env=dict(route, MOCK_AGENT_STATUS="idle"))
        self.assert_success(result)
        self.assertEqual((worktree / "source.txt").read_text(), "existing issue edits\n")
        self.assertEqual(len([c for c in self.calls("herdr") if c["args"][:2] == ["worktree", "create"]]), 1)
        self.assertEqual(len([c for c in self.calls("herdr") if c["args"][:2] == ["worktree", "open"]]), 1)
        self.assertEqual(len([c for c in self.calls("herdr") if c["args"][:2] == ["agent", "start"]]), 1)
        self.assertEqual(len([c for c in self.calls("herdr") if c["args"][:2] == ["agent", "prompt"]]), 2)
        self.assertEqual([c["args"] for c in self.calls("herdr") if c["args"][:2] == ["agent", "focus"]],
                         [["agent", "focus", "issue-pane"]])
        self.assertFalse((Path(self.env["XDG_STATE_HOME"]) / "gh-dash-codex-issue/contexts").exists())

    def test_issue_busy_blocked_and_unknown_agents_do_not_resend(self):
        self.install()
        repo, git = self.source_repo()
        route = self.issue_environment(repo, git)
        launcher = self.installed / "scripts/integrations/gh-dash/gh-dash-codex-issue.sh"
        self.assert_success(self.run_script(launcher, "friend/target", "8", cwd=repo, env=route))
        for status in ("working", "blocked", "unexpected-status"):
            with self.subTest(status=status):
                self.log.write_text("")
                result = self.run_script(launcher, "friend/target", "8", cwd=repo,
                                         env=dict(route, MOCK_AGENT_STATUS=status))
                self.assert_success(result)
                calls = self.calls("herdr")
                self.assertFalse(any(c["args"][:2] in (["agent", "start"], ["agent", "prompt"], ["worktree", "create"])
                                     for c in calls))
                self.assertEqual([c["args"] for c in calls if c["args"][:2] == ["agent", "focus"]],
                                 [["agent", "focus", "issue-pane"]])

    def test_issue_factory_argument_is_rejected_before_side_effects(self):
        directory = self.bundle / "scripts/integrations/gh-dash"
        for name in ("gh-dash-codex-issue.sh", "gh-dash-codex-issue-dispatch.sh"):
            with self.subTest(script=name):
                result = self.run_script(directory / name, "friend/target", "8", "--factory")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("usage:", result.stderr.lower())
                self.assertFalse(self.calls(), "unsupported Factory invocation called external tools")
                self.assertFalse(Path(self.env["XDG_STATE_HOME"]).exists())

    def test_issue_conflicting_agent_identity_is_retained_without_action(self):
        self.install()
        repo, git = self.source_repo()
        route = self.issue_environment(repo, git)
        launcher = self.installed / "scripts/integrations/gh-dash/gh-dash-codex-issue.sh"
        self.assert_success(self.run_script(launcher, "friend/target", "8", cwd=repo, env=route))
        self.log.write_text("")
        result = self.run_script(launcher, "friend/target", "8", cwd=repo,
                                 env=dict(route, MOCK_AGENT_PANE="unrelated-pane"))
        self.assert_success(result)
        self.assertIn("conflicting", result.stderr)
        calls = self.calls("herdr")
        self.assertFalse(any(c["args"][:2] in (["agent", "start"], ["agent", "prompt"], ["agent", "focus"], ["worktree", "create"])
                             for c in calls))

    def test_doctor_outside_herdr_is_successful_and_read_only(self):
        self.install()
        result = self.run_script(self.installed / "scripts/doctor.sh")
        self.assert_success(result)
        self.assertIn("runtime-context checks not performed", result.stdout.lower())
        self.assertNotIn("ready to launch from this context", result.stdout.lower())
        self.assert_no_actions()

    def test_doctor_without_installation_reports_incomplete_outside_herdr(self):
        result = self.run_script(self.bundle / "scripts/doctor.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("installation: incomplete", result.stdout.lower())
        self.assertIn("runtime-context checks not performed", result.stdout.lower())
        self.assertNotIn("runtime: ready to launch", result.stdout.lower())
        self.assertFalse(self.installed.exists())
        self.assert_no_actions()

    def test_doctor_pending_authentication_hides_native_output(self):
        self.install()
        for variable in ("MOCK_GH_AUTH", "MOCK_CODEX_AUTH"):
            result = self.run_script(self.installed / "scripts/doctor.sh", env={variable: "pending"})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("pending", (result.stdout + result.stderr).lower())
            self.assertNotIn("AUTH_SECRET_SENTINEL", result.stdout + result.stderr)
        self.assert_no_actions()

    def test_doctor_path_pending_and_missing_runtime_file(self):
        self.install()
        result = self.run_script(self.installed / "scripts/doctor.sh", env={"PATH": str(self.mock)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PATH", result.stdout + result.stderr)
        (self.installed / "scripts/integrations/gh-dash/gh-dash-codex-issue.sh").unlink()
        result = self.run_script(self.installed / "scripts/doctor.sh", "--integrity-only", "--bundle", self.installed)
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_actions()

    def test_doctor_context_route_server_and_detection_capability(self):
        self.install()
        repo, _ = self.source_repo()
        route = {"HERDR_SOCKET_PATH": str(self.home / "test.sock"), "HERDR_WORKSPACE_ID": "ws",
                 "HERDR_TAB_ID": "tab", "HERDR_PANE_ID": "pane"}
        result = self.run_script(self.installed / "scripts/doctor.sh", cwd=repo, env=route)
        self.assert_success(result)
        self.assertIn("ready to launch from this context", result.stdout.lower())
        transports = [call for call in self.calls("git")
                      if "ls-remote" in call["args"] and "--get-url" not in call["args"]]
        self.assertTrue(transports)
        command = transports[-1]["env"].get("GIT_SSH_COMMAND", "")
        for option in ("BatchMode=yes", "StrictHostKeyChecking=yes", "UpdateHostKeys=no", "CheckHostIP=no"):
            self.assertIn(option, command, "doctor SSH check could prompt or modify host trust")
        for flag in ("MOCK_SERVER", "MOCK_ROUTE", "MOCK_MANIFEST", "MOCK_TRANSPORT"):
            result = self.run_script(self.installed / "scripts/doctor.sh", cwd=repo,
                env=dict(route, **{flag: "incompatible" if flag == "MOCK_SERVER" else "wrong" if flag == "MOCK_ROUTE" else "pending" if flag == "MOCK_TRANSPORT" else "missing"}))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("ready to launch from this context", result.stdout.lower())
        self.assert_no_actions()

    def test_doctor_custom_ssh_is_pending_but_working_https_requires_no_ssh(self):
        self.install()
        repo, git = self.source_repo()
        route = {"HERDR_SOCKET_PATH": str(self.home / "test.sock"), "HERDR_WORKSPACE_ID": "ws",
                 "HERDR_TAB_ID": "tab", "HERDR_PANE_ID": "pane"}
        for custom in ("environment", "git configuration"):
            with self.subTest(custom=custom):
                overrides = dict(route)
                if custom == "environment":
                    overrides["GIT_SSH_COMMAND"] = "/nonexistent/custom-ssh"
                else:
                    git("config", "core.sshCommand", "/nonexistent/custom-ssh")
                self.log.write_text("")
                result = self.run_script(self.installed / "scripts/doctor.sh", cwd=repo, env=overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("custom SSH", result.stdout)
                self.assertFalse(any("ls-remote" in call["args"] and "--get-url" not in call["args"]
                                     for call in self.calls("git")), "doctor executed custom SSH transport")
                self.assert_no_actions()
        # Git URL rewriting chooses HTTPS before sshCommand or SSH availability
        # matters. A working HTTPS route must remain ready with either override.
        (self.mock / "ssh").unlink()
        self.log.write_text("")
        result = self.run_script(self.installed / "scripts/doctor.sh", cwd=repo,
            env=dict(route, MOCK_EFFECTIVE_URL="https://github.com/friend/target.git",
                     GIT_SSH_COMMAND="/nonexistent/custom-ssh"))
        self.assert_success(result)
        self.assertIn("ready to launch from this context", result.stdout.lower())
        self.assertTrue(any("ls-remote" in call["args"] and "--get-url" not in call["args"]
                            for call in self.calls("git")))
        self.assertFalse(self.calls("ssh"))
        self.assert_no_actions()


if __name__ == "__main__":
    unittest.main(verbosity=2)
