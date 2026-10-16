# Agent Watcher

See your open Pi, Claude Code, and Codex CLIs in the macOS menu bar, then return to the exact Ghostty or cmux tab or split pane with one click.

- One entry per live CLI, including idle sessions and agents in split panes.
- The CLI name, project, shortened initial prompt, status, and current tool activity in each entry.
- Attention indicators for approvals, questions, and unread completed responses.
- Notifications that stay quiet for the focused agent.
- Automatic removal when a CLI exits, even if its terminal tab stays open.
- Your usual `pi`, `claude`, and `codex` commands, with one-time integration setup and no persistent helper daemon.

This is a development preview.
Live terminal navigation and macOS notification delivery still need manual verification before a signed public release.

## Requirements

- macOS 14 or later on Apple silicon or Intel.
- [Ghostty](https://ghostty.org/download) 1.3 or later with AppleScript support enabled, or [cmux](https://cmux.com/).
  The cmux integration is validated against version 0.65.1.
- Pi, Claude Code, or Codex CLI installed on the same Mac.
- Xcode with the Swift 6 toolchain if you build from source.

The integration baseline is Pi 1.2.0, Claude Code 2.1.300, and Codex CLI 0.162.1.
Earlier CLI versions are not validated.
Agents must run directly in Ghostty or cmux on your Mac.
Remote SSH sessions and tmux are outside the supported setup.

## Install

### Build from source

With Xcode installed and its command-line tools selected, run:

```sh
git clone https://github.com/tanjibpa/agent-watcher.git
cd agent-watcher
UNIVERSAL=1 bash scripts/build-app.sh
```

The build creates `dist/Agent Watcher.app` and `dist/AgentWatcher.zip` for both Apple silicon and Intel Macs.
To build only for your Mac's architecture, omit `UNIVERSAL=1`.

1. In Finder, open the repository's `dist` folder.
2. Drag **Agent Watcher.app** into **Applications**.
3. Open **Agent Watcher** from **Applications**.
4. Click the terminal icon in the macOS menu bar to open the agent list.

Agent Watcher has no Dock icon or main window.
You can also try the build before copying it into Applications:

```sh
open "dist/Agent Watcher.app"
```

### Download a development build

1. Open the repository's [Build and test workflow](https://github.com/tanjibpa/agent-watcher/actions/workflows/ci.yml).
2. Select a successful run for `main`.
3. Download the **AgentWatcher-development** artifact.
4. Extract the downloaded archive, then extract `AgentWatcher.zip` inside it.
5. Drag **Agent Watcher.app** into **Applications** and open it.

These builds use an ad hoc signature and are not notarized by Apple.
If macOS blocks a downloaded development build that you trust, follow [Apple's instructions for opening an app from an unidentified developer](https://support.apple.com/en-us/102445).
There is no signed release installer yet.

## Set up your CLIs

1. Open Agent Watcher from **Applications**, then click its terminal icon in the menu bar.
2. Click **Install integrations**.
   To reopen setup later, click the gear button labeled **Set up Agent Watcher**.
3. If you use Codex, run this command once in your shell:

   ```sh
   codex features disable daemon_auto_start
   ```

   In Codex, run `/hooks` and trust the Agent Watcher hooks.
   Agent Watcher does not grant this trust automatically.
4. Restart Pi, Claude Code, and Codex sessions opened before setup so they load the integrations.
5. Connect the terminal apps you use.
   For Ghostty, click **Connect Ghostty** and allow macOS Automation access.
   For cmux, open **cmux Settings > Automation**, set **Socket Control Mode** to **Automation** or **Password**, then click **Connect cmux** in Agent Watcher.
   Automation mode permits local apps running as your macOS user to control cmux through its socket.
   Password mode uses the credentials already configured for the cmux CLI.
6. If you want notifications, click **Enable notifications** and allow them.
7. Click **Back to agents** to see your sessions.
   Optionally enable **Launch at login** to start Agent Watcher when you sign in to your Mac.

Codex needs a separate runtime for each CLI so hooks can identify the correct terminal.
Its shared background server does not provide the originating terminal identity in hook events.
The feature setting above keeps your normal `codex` command unchanged.

Setup preserves unrelated settings and hooks, and creates a sibling `.agent-watcher-<id>.backup` file for changed configuration files.
It installs these integrations:

| CLI | Configuration or extension |
| --- | --- |
| Claude Code | Hooks in `~/.claude/settings.json` |
| Codex | Hooks in `~/.codex/hooks.json` |
| Pi | Extension at `~/.pi/agent/extensions/agent-watcher.ts` |

The short-lived hook executable is installed at `~/Library/Application Support/AgentWatcher/bin/agent-watcher-hook`.
You do not need a wrapper command or a separate background service.
Agent Watcher does not approve commands or change CLI permission policies.

Custom configuration roots work through `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, and `PI_CODING_AGENT_DIR` when those variables are present in the app's launch environment.
A Finder-launched app does not inherit variables set only in your shell configuration.

## Usage

1. Open a Ghostty or cmux tab or split pane and launch `pi`, `claude`, or `codex` as usual.
2. Click Agent Watcher's terminal icon in the menu bar.
3. Find your session by its CLI name, project, or shortened initial prompt.
4. Click the entry to return to that session's terminal tab or split pane.

Each entry identifies its terminal app and shows the current activity, such as reading a file, editing files, or running a command.
The list keeps open CLIs even when they are waiting for another message.
Sessions in both terminal apps appear in the same list.
When you exit a CLI or close its pane, its entry disappears.

| Status | Meaning |
| --- | --- |
| **Working** | The agent is handling a request or running tools. |
| **Needs input** | An approval or question needs your response. |
| **Finished** | A completed response has not been viewed in its pane. |
| **Failed** | The CLI reported a failed response that has not been viewed. |
| **Idle** | The CLI is open and waiting for your next message. |
| **Waiting for status** | A Claude Code or Codex process was found before its first hook event. |

Focusing an agent acknowledges its completed response but does not resolve an unanswered question or approval.
With notifications enabled, background agents can notify you about input requests and completed responses.
Clicking a notification returns you to that agent's pane.
Notifications wait if Agent Watcher cannot determine which pane has focus.

Subagents stay within their parent CLI's entry.
With `pi-subagents` 0.78.0, active background work keeps the parent Pi session **Working**, with an active count and available agent or step labels in the activity line.
Reloading Pi recovers background work that is already running.

## Update

1. Quit Agent Watcher, then replace the app in **Applications** with your new build.
2. Open the updated app and click the gear button.
3. Click **Update integrations** to refresh the installed hooks and Pi extension.
4. Restart your CLIs so they load the update.
   For a Pi session with running subagents, use `/reload` to load the extension without closing the session.

If you build from source, run `git pull --ff-only` in the repository and repeat the build command before replacing the app.

## Troubleshooting

### I cannot find Agent Watcher

Open **Agent Watcher** from **Applications**.
Look for the terminal icon in the macOS menu bar, not the Dock.
Click the icon to see the list or setup screen.
Enable **Launch at login** in setup if you want it to start automatically.

### The list is empty or a session is missing

Open setup and confirm that your CLI's integration is marked **Installed**.
Click **Update integrations**, then restart the CLI in Ghostty or cmux.
For Pi, `/reload` also loads the current extension.
Agent Watcher lists local CLIs with verified terminal-app process ancestry, rather than saved conversations or agent subprocesses.

For Codex, confirm that you disabled `daemon_auto_start` and trusted the hooks through `/hooks`.
A newly opened Codex session can show **Waiting for status** until you send its first prompt.

### Pi is idle while background subagents are working

Update Agent Watcher, click **Update integrations**, then run `/reload` in Pi.
Background status tracking is validated with `pi-subagents` 0.78.0.
Other subagent extensions must expose compatible status events to report this activity.

### Clicking an entry does not focus Ghostty

Open Ghostty, then click **Connect Ghostty** or **Reconnect Ghostty** in Agent Watcher's setup.
Check **System Settings > Privacy & Security > Automation** and allow Agent Watcher to control Ghostty.
If you disabled Ghostty's AppleScript support, enable `macos-applescript` in your Ghostty configuration and restart Ghostty.
See [Ghostty's AppleScript documentation](https://ghostty.org/docs/features/applescript) for its configuration and permissions.

### cmux entries cannot be opened or connected

In **cmux Settings > Automation**, choose **Automation** or **Password** for **Socket Control Mode**, then click **Reconnect cmux** in Agent Watcher.
The default **cmux processes only** mode rejects external apps such as Agent Watcher.
Agent Watcher uses the CLI bundled with the running cmux app, so it does not need `cmux` on your shell path.
Existing Agent Watcher hooks work in both terminals.
Restart existing CLIs or run `/reload` in Pi after updating the integrations.

### Notifications do not appear

Click **Enable notifications** in setup or open **Notification settings…** and allow Agent Watcher's notifications.
The focused agent stays quiet.
Agent Watcher also waits to notify until the agent's terminal app is connected and it can determine focus.

## Uninstall

1. Quit your CLI sessions.
2. In Agent Watcher's setup, turn off **Launch at login**.
3. Click **Remove integrations…** and confirm removal.
4. If you changed Codex's runtime setting for Agent Watcher, optionally restore its shared-server default:

   ```sh
   codex features enable daemon_auto_start
   ```

5. Quit Agent Watcher, then delete it from **Applications**.

Integration removal deletes Agent Watcher's hook commands, Pi extension, and installed hook executable while preserving unrelated CLI settings.
Configuration backup files remain available beside the original files.

## Privacy and tracking

Tracking stays on your Mac.
Agent Watcher does not call a model, send telemetry, or upload transcripts.
Snapshots under `~/Library/Application Support/AgentWatcher/sessions` contain the working directory, a shortened initial prompt, and shortened tool activity.
Notifications include the project and task label.
The app stores completion acknowledgments in local preferences and deletes snapshots when their CLI exits.

Claude Code and Codex report lifecycle events through the native hook executable.
Pi reports through its TypeScript extension using the same local protocol.
Process identity includes the process ID and start time, and registration verifies its terminal app ancestry and terminal device.
The app watches process exits and reconciles the list every second.
It can discover native Claude Code and Codex processes before their first hook event.
Concurrent hook updates use file locks and atomic replacement.
Monitoring failures do not block agent tools or add anything to the model's context.

Ghostty navigation briefly writes a terminal-title marker to identify the exact pane, caches its terminal ID, and restores the original title.
For cmux, the app reads terminal devices and stable window, workspace, and surface IDs through its bundled CLI.
Clicking an agent focuses the exact cmux surface, even after moving it to another workspace.
Background polling does not change focus.
The app does not choose a pane by its working directory, so agents in the same project remain separate.

## Development

The Swift package has no external dependencies.
`AgentWatcherCore` owns state transitions, hook parsing, process identity, persistence, and integration setup.
`AgentWatcher` owns the menu bar UI, terminal navigation, and notifications.

```sh
swift test
python3 Tests/Integration/terminal.test.py .build/debug/agent-watcher-hook
node --experimental-strip-types --test Tests/Integration/pi.test.mjs
swift format lint --strict --recursive Sources Tests/AgentWatcherCoreTests Tests/Integration/discovery.swift
UNIVERSAL=1 bash scripts/build-app.sh
```

The terminal integration test needs Python 3 and macOS.
The Pi integration test needs Node.js 22.18 or later.
Set `AGENT_WATCHER_DATA_DIR` to an isolated directory when testing the app and hooks together.

Before a release, manually verify:

1. Start two agents in the same working directory in different split panes in each terminal app.
   Also test agents in separate cmux windows and workspaces.
2. Confirm each entry focuses its own pane and restores its original title.
3. Trigger an approval, an interactive question, tool activity, and completion in each supported CLI.
4. Confirm a focused agent stays quiet while a background agent notifies you.
5. Click a notification and verify it selects the correct pane.
6. Quit one CLI, leave its tab open, and verify its entry disappears.
7. Force-quit a CLI, then restart Agent Watcher and verify stale entries are removed.
8. Verify installation and removal alongside existing hooks and after moving the app into Applications.

## Publish a signed release

Build a universal app with a Developer ID Application certificate and a configured `notarytool` keychain profile:

```sh
export CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export APP_VERSION='0.1.0'
bash scripts/notarize.sh agent-watcher-notary
```

The script signs the app and hook executable, submits the archive for notarization, staples the accepted ticket, and recreates `dist/AgentWatcher.zip`.
Attach that archive to a GitHub release after the manual checks pass.

## License

[MIT](LICENSE).
