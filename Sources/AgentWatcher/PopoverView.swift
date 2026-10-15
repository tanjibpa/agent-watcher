import AgentWatcherCore
import AppKit
import ServiceManagement
import SwiftUI

struct PopoverView: View {
  @ObservedObject var model: AppModel
  @State private var showSetup = false
  @State private var confirmRemoval = false
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  var dismiss: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "terminal").font(.title3)
        Text("Agent Watcher").font(.headline)
        Spacer()
        Text("\(model.agents.count) open").foregroundStyle(.secondary)
        Button {
          showSetup.toggle()
        } label: {
          Image(systemName: "gearshape")
        }
        .buttonStyle(.borderless).help("Set up Agent Watcher")
        .accessibilityLabel("Set up Agent Watcher")
      }
      .padding(16)
      Divider()
      if showSetup || !model.anyIntegrationInstalled {
        setup.padding(16)
      } else if model.agents.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "terminal").font(.system(size: 32)).foregroundStyle(.secondary)
          Text("No agents open").font(.headline)
          Text("Start Pi, Claude Code, or Codex in Ghostty. Restart CLIs opened before setup.")
            .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(model.sortedAgents) { agent in
              AgentRow(
                agent: agent, needsAttention: model.needsAttention(agent),
                unread: model.unread(agent)
              ) {
                Task {
                  await model.focus(agent)
                  if model.error == nil { dismiss() }
                }
              }
            }
          }
          .padding(8)
        }
        .frame(height: min(CGFloat(model.agents.count) * 100 + 16, 540))
      }
      if let error = model.error {
        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }
      Divider()
      HStack {
        Circle().fill(model.connected ? Color.green : Color.secondary).frame(width: 6, height: 6)
        Text(model.connected ? "Ghostty connected" : "Ghostty not connected").font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless)
      }
      .padding(12)
    }
    .frame(width: 420)
    .fixedSize(horizontal: false, vertical: true)
    .alert("Remove Agent Watcher integrations?", isPresented: $confirmRemoval) {
      Button("Remove", role: .destructive) { model.removeIntegrations() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This removes Agent Watcher’s hooks and Pi extension. Your other CLI settings and hooks stay in place."
      )
    }
  }

  private var setup: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Set up Agent Watcher").font(.title3.weight(.semibold))
      Text(
        "Keep using your usual CLI commands. Install the integrations once to report their status to this Mac."
      )
      .foregroundStyle(.secondary)
      ForEach(Provider.allCases, id: \.self) { provider in
        HStack {
          Text(provider.title)
          Spacer()
          Label(
            model.installed[provider] == true ? "Installed" : "Not installed",
            systemImage: model.installed[provider] == true ? "checkmark.circle.fill" : "circle"
          )
          .foregroundStyle(model.installed[provider] == true ? .green : .secondary)
        }.font(.callout)
      }
      Button(model.anyIntegrationInstalled ? "Update integrations" : "Install integrations") {
        model.installIntegrations()
      }
      .buttonStyle(.borderedProminent)
      if let message = model.setupMessage { Text(message).font(.callout).textSelection(.enabled) }
      Text(
        "In Codex, run /hooks and trust the Agent Watcher hooks. Restart your CLIs after installing or updating."
      )
      .font(.caption).foregroundStyle(.secondary)
      Text(
        "For Codex 0.162 or later, first run `codex features disable daemon_auto_start` in your shell so each CLI reports its own status."
      )
      .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      Divider()
      Button(model.connected ? "Reconnect Ghostty" : "Connect Ghostty") {
        Task { await model.connectGhostty() }
      }
      .disabled(model.settingUp)
      Text(
        "Allow Agent Watcher to control Ghostty when macOS asks. This lets you return to the exact tab or split pane."
      )
      .font(.caption).foregroundStyle(.secondary)
      Button(model.notificationsEnabled ? "Notification settings…" : "Enable notifications") {
        if model.notificationsEnabled {
          if let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
          {
            NSWorkspace.shared.open(url)
          }
        } else {
          Task { await model.enableNotifications() }
        }
      }
      Text(
        "Approvals, questions, and unread completions notify you. The focused agent stays quiet."
      )
      .font(.caption).foregroundStyle(.secondary)
      Toggle("Launch at login", isOn: $launchAtLogin)
        .onChange(of: launchAtLogin) { _, enabled in
          do {
            if enabled {
              try SMAppService.mainApp.register()
            } else {
              try SMAppService.mainApp.unregister()
            }
          } catch {
            model.error = "Launch at login could not be changed. \(error.localizedDescription)"
          }
          launchAtLogin = SMAppService.mainApp.status == .enabled
        }
      if model.anyIntegrationInstalled {
        Button("Remove integrations…", role: .destructive) { confirmRemoval = true }.buttonStyle(
          .borderless)
        Button("Back to agents") { showSetup = false }
      }
    }
  }
}

private struct AgentRow: View {
  let agent: Agent
  let needsAttention: Bool
  let unread: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 7) {
          Circle().fill(color).frame(width: 7, height: 7)
          Text(agent.provider.title).fontWeight(.semibold)
          Text(agent.project).foregroundStyle(.secondary).lineLimit(1)
          Spacer(minLength: 0)
          Text(status).font(.caption).foregroundStyle(color)
          Image(systemName: "arrow.up.forward").font(.caption2).foregroundStyle(.tertiary)
        }
        Text(agent.task.isEmpty ? "No prompt yet" : agent.task).lineLimit(1).truncationMode(.tail)
        Text(agent.activity).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(
          .middle)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(agent.cwd + "\n" + agent.task + "\n" + agent.activity)
    .accessibilityLabel(
      "\(agent.provider.title), \(agent.project), \(status), \(agent.task), \(agent.activity)"
    )
    .accessibilityHint("Focus this agent’s Ghostty pane")
  }

  private var status: String {
    if agent.sessionID.isEmpty { return "Waiting for status" }
    if !agent.blockers.isEmpty { return "Needs input" }
    if unread { return agent.failed ? "Failed" : "Finished" }
    return agent.working ? "Working" : "Idle"
  }
  private var color: Color { needsAttention ? .orange : (agent.working ? .blue : .secondary) }
}
