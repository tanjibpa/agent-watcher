"""Exercise the built hook through a real macOS login process and pseudo-terminal."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


hook = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="agent-watcher-terminal-") as directory:
    fixture = Path(directory)
    for bundle, executable, terminal_kind in [("Ghostty.app", "ghostty", "ghostty"), ("cmux.app", "cmux", "cmux")]:
        root = fixture / terminal_kind
        terminal = root / bundle / "Contents/MacOS" / executable
        terminal.parent.mkdir(parents=True)
        subprocess.run(
            ["clang", str(Path(__file__).with_name("terminal.c")), "-o", str(terminal)],
            check=True,
        )
        for provider in ("pi", "claude", "codex"):
            cli = root / provider
            shutil.copy2(terminal, cli)
            state = root / f"state-{provider}"
            result = subprocess.run(
                [str(terminal), "terminal", str(cli), str(hook), provider],
                env={**os.environ, "AGENT_WATCHER_DATA_DIR": str(state)},
                capture_output=True,
                text=True,
                timeout=15,
                cwd=root,
            )
            assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
            snapshots = list((state / "sessions").glob("*.json"))
            assert len(snapshots) == 1, f"{provider}: login-shell hook produced no agent entry"
            agent = json.loads(snapshots[0].read_text())
            assert agent["provider"] == provider
            assert agent["terminal"] == terminal_kind
            assert agent["sessionID"] == "login-test"
            assert agent["process"]["tty"].startswith("/dev/ttys")
            assert Path(agent["process"]["executable"]).resolve() == cli.resolve()
            print(f"PASS: {terminal_kind} {provider} registers through the privileged login process")

            state = root / f"unlinked-{provider}"
            result = subprocess.run(
                [str(terminal), "terminal", str(cli), str(hook), provider],
                env={**os.environ, "AGENT_WATCHER_DATA_DIR": str(state),
                     "AGENT_WATCHER_TEST_UNLINK_EXECUTABLE": "1"},
                capture_output=True,
                text=True,
                timeout=15,
                cwd=root,
            )
            assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
            assert not cli.exists(), "fixture must remove only its own running executable"
            snapshots = list((state / "sessions").glob("*.json"))
            assert len(snapshots) == 1, f"{provider}: running CLI disappeared after its executable was removed"
            agent = json.loads(snapshots[0].read_text())
            assert agent["provider"] == provider
            assert agent["terminal"] == terminal_kind
            assert Path(agent["process"]["executable"]).resolve() == cli.resolve()
            shutil.copy2(terminal, cli)
            print(f"PASS: {terminal_kind} {provider} registers after a package upgrade removes its running executable")

        repository = Path(__file__).resolve().parents[2]
        probe = root / "discovery-probe"
        subprocess.run(
            ["swiftc", "-o", str(probe)]
            + [str(repository / "Sources/AgentWatcherCore" / name) for name in (
                "Agent.swift", "ProcessIdentity.swift", "TerminalApplication.swift", "AgentDiscovery.swift"
            )]
            + [str(Path(__file__).with_name("discovery.swift"))],
            check=True,
        )
        for provider in ("claude", "codex"):
            state = root / f"discovery-{provider}"
            result = subprocess.run(
                [str(terminal), "terminal", str(root / provider), str(probe), provider],
                env={**os.environ, "AGENT_WATCHER_DATA_DIR": str(state)},
                capture_output=True,
                text=True,
                timeout=15,
                cwd=root,
            )
            assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
            agents = json.loads((state / "discovered.json").read_text())
            assert len(agents) == 1, f"{provider}: open CLI missing before its first hook"
            assert agents[0]["provider"] == provider
            assert agents[0]["terminal"] == terminal_kind
            assert agents[0]["sessionID"] == ""
            assert Path(agents[0]["cwd"]).resolve() == root.resolve()
            assert Path(agents[0]["process"]["executable"]).resolve() == (root / provider).resolve()
            print(f"PASS: {terminal_kind} {provider} appears before publishing any hook event")

            result = subprocess.run(
                [str(terminal), "terminal", str(root / provider), str(probe), provider],
                env={**os.environ, "AGENT_WATCHER_DATA_DIR": str(state),
                     "AGENT_WATCHER_TEST_PIPE_INPUT": "1"},
                capture_output=True,
                text=True,
                timeout=15,
                cwd=root,
            )
            assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
            assert json.loads((state / "discovered.json").read_text()) == []
            print(f"PASS: {terminal_kind} {provider} background process with no terminal input is excluded")
