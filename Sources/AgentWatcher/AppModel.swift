import AgentWatcherCore
import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
  @Published var agents: [Agent] = []
  @Published var receipts: [String: AttentionState] = [:]
  @Published var installed: [Provider: Bool] = [:]
  @Published var error: String?
  @Published var setupMessage: String?
  @Published var notificationsEnabled = false
  @Published var ghosttyConnected = false
  @Published var cmuxConnected = false
  @Published var settingUp = false
  var onChange: (() -> Void)?
  private let store = StateStore()
  private let ghostty = GhosttyClient()
  private let cmux = CmuxClient()
  private var targets: [String: String] = [:]
  private var bindingRetry: [String: Date] = [:]
  private var discovered: [Agent] = []
  private var nextDiscovery = Date.distantPast
  private var nextTerminalPoll = Date.distantPast
  private var nextPermissionCheck = Date.distantPast
  private var nextFocusPoll: [TerminalApplication: Date] = [:]
  private var checkedTokens: [String: String] = [:]
  private var stored: [Agent] = []
  private var storedModified: Date?
  private var loop: Task<Void, Never>?
  private var activatedObserver: NSObjectProtocol?
  private let defaults = UserDefaults.standard
  private var ghosttyAuthorized = false
  private var cmuxAuthorized = false
  private var processWatchers: [String: any DispatchSourceProcess] = [:]
  private var askedToNotify = false

  var attentionCount: Int { agents.filter { needsAttention($0) }.count }
  var anyIntegrationInstalled: Bool { installed.values.contains(true) }
  var connected: Bool { ghosttyConnected || cmuxConnected }
  var connectionSummary: String {
    let names = [ghosttyConnected ? "Ghostty" : nil, cmuxConnected ? "cmux" : nil].compactMap { $0 }
    return names.isEmpty ? "No terminal connected" : names.joined(separator: " + ") + " connected"
  }
  var sortedAgents: [Agent] {
    agents.sorted {
      let first = needsAttention($0) ? 0 : ($0.working ? 1 : 2)
      let second = needsAttention($1) ? 0 : ($1.working ? 1 : 2)
      if first != second { return first < second }
      return $0.process.startedSeconds < $1.process.startedSeconds
    }
  }

  init() {
    if let data = defaults.data(forKey: "attentionReceipts"),
      let decoded = try? JSONDecoder().decode([String: AttentionState].self, from: data)
    {
      receipts = decoded
    }
    ghosttyAuthorized = defaults.bool(forKey: "ghosttyConnected")
    cmuxAuthorized = defaults.bool(forKey: "cmuxConnected")
    refreshInstallation()
    activatedObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in await self?.refreshFocus() } }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.refresh()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  func needsAttention(_ agent: Agent) -> Bool {
    (receipts[agent.id] ?? AttentionState()).needsAttention(agent)
  }
  func unread(_ agent: Agent) -> Bool { (receipts[agent.id] ?? AttentionState()).unread(agent) }

  func refreshInstallation() {
    let installer = IntegrationInstaller()
    installed = Dictionary(
      uniqueKeysWithValues: Provider.allCases.map { ($0, installer.installed($0)) })
  }

  func installIntegrations() {
    do {
      try IntegrationInstaller().install()
      refreshInstallation()
      setupMessage =
        "Integrations installed. Restart your CLIs. In Codex, run /hooks and trust the Agent Watcher hooks."
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  func removeIntegrations() {
    do {
      try IntegrationInstaller().uninstall()
      refreshInstallation()
      setupMessage = "Integrations removed. Your other hooks were preserved. Restart any open CLIs."
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  func connectGhostty() async {
    guard !settingUp else { return }
    settingUp = true
    defer { settingUp = false }
    do {
      _ = try await ghostty.snapshot(isRunning: ghosttyRunning)
      ghosttyAuthorized = true
      ghosttyConnected = true
      defaults.set(true, forKey: "ghosttyConnected")
      bindingRetry = [:]
      error = nil
      await refresh()
    } catch { self.error = error.localizedDescription }
  }

  private var cmuxApplication: NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
      $0.bundleIdentifier == TerminalApplication.cmux.bundleIdentifier
    }
  }

  private var cmuxExecutable: URL? {
    cmuxApplication?.bundleURL?.appendingPathComponent("Contents/Resources/bin/cmux")
  }

  private var cmuxFrontmost: Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      == TerminalApplication.cmux.bundleIdentifier
  }

  func connectCmux() async {
    guard !settingUp else { return }
    settingUp = true
    defer { settingUp = false }
    do {
      guard let executable = cmuxExecutable else { throw CmuxClient.Failure.notRunning }
      _ = try await cmux.snapshot(executable: executable, isFrontmost: cmuxFrontmost)
      cmuxAuthorized = true
      cmuxConnected = true
      defaults.set(true, forKey: "cmuxConnected")
      error = nil
      await refresh()
    } catch { self.error = error.localizedDescription }
  }

  func enableNotifications() async {
    do {
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      if settings.authorizationStatus == .denied {
        if let url = URL(
          string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        {
          NSWorkspace.shared.open(url)
        }
        return
      }
      _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [
        .alert, .sound, .badge,
      ])
      await updateNotificationPermission()
    } catch { self.error = error.localizedDescription }
  }

  func focus(_ agent: Agent) async {
    do {
      guard agent.process.isAlive else {
        await refresh()
        return
      }
      switch agent.terminalApplication {
      case .ghostty:
        // Cached targets are no longer pruned every second, so a failed one is identified again.
        var focusedCached = false
        if let cached = targets[agent.id] {
          do {
            try await ghostty.focus(cached)
            focusedCached = true
          } catch { targets.removeValue(forKey: agent.id) }
        }
        if !focusedCached {
          let target = try await ghostty.identify(agent.process)
          targets[agent.id] = target
          try await ghostty.focus(target)
        }
      case .cmux:
        guard let executable = cmuxExecutable else { throw CmuxClient.Failure.notRunning }
        let snapshot = try await cmux.snapshot(executable: executable, isFrontmost: cmuxFrontmost)
        guard agent.process.isAlive, let target = snapshot.target(for: agent.process) else {
          throw CmuxClient.Failure.noTerminal
        }
        try await cmux.focus(target, executable: executable)
        cmuxApplication?.activate(options: [])
      }
      var receipt = receipts[agent.id] ?? AttentionState()
      _ = receipt.observe(agent, focused: true, notificationsEnabled: notificationsEnabled)
      receipts[agent.id] = receipt
      persistReceipts()
      error = nil
    } catch {
      targets.removeValue(forKey: agent.id)
      self.error = error.localizedDescription
    }
  }

  func focus(id: String) async {
    if let agent = agents.first(where: { $0.id == id }) { await focus(agent) }
  }

  /// Opening the list is a direct request for current state, so the gated work runs again.
  func refreshNow() async {
    nextDiscovery = .distantPast
    nextTerminalPoll = .distantPast
    nextPermissionCheck = .distantPast
    storedModified = nil
    await refresh()
  }

  /// Switching apps can change which pane is focused, so the next pass checks focus right away.
  private func refreshFocus() async {
    nextFocusPoll = [:]
    await refresh()
  }

  /// Whether a pass must ask the terminal app about its panes.
  private func needsTerminalQuery(
    _ terminal: TerminalApplication, attentive: [Agent], due: Bool
  ) -> Bool {
    let waiting = attentive.filter { $0.terminalApplication == terminal }
    if due { return true }
    if waiting.isEmpty { return false }
    // A new approval or response needs its focus known before it can notify.
    if waiting.contains(where: { checkedTokens[$0.id] != $0.attentionToken }) { return true }
    if terminal == .ghostty,
      waiting.contains(where: {
        targets[$0.id] == nil && Date() >= (bindingRetry[$0.id] ?? .distantPast)
      })
    {
      return true
    }
    // A pane can only be in focus while its app is frontmost, so a background app is left alone.
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == terminal.bundleIdentifier
    else { return false }
    return Date() >= (nextFocusPoll[terminal] ?? .distantPast)
  }

  private func markChecked(_ terminal: TerminalApplication, attentive: [Agent]) {
    nextFocusPoll[terminal] = Date().addingTimeInterval(3)
    for agent in attentive where agent.terminalApplication == terminal {
      checkedTokens[agent.id] = agent.attentionToken
    }
  }

  private var refreshing = false
  private var ghosttyRunning: Bool {
    NSWorkspace.shared.runningApplications.contains {
      $0.bundleIdentifier == "com.mitchellh.ghostty"
    }
  }

  func refresh() async {
    guard !refreshing else { return }
    refreshing = true
    defer {
      refreshing = false
      onChange?()
    }
    let previousReceipts = receipts
    do {
      // Hooks replace session files atomically, which also updates the directory's date.
      let modified =
        (try? store.sessionsDirectory.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
      if modified == nil || modified != storedModified {
        stored = try store.agents()
        storedModified = modified
      }
      var live = stored.filter { $0.process.isAlive }
      for closed in stored where !closed.process.isAlive { try store.remove(closed) }
      let reportedIDs = Set(live.map(\.id))
      // Scanning every process is the costliest local step, and hooks report most agents anyway.
      if Date() >= nextDiscovery {
        discovered = await Task.detached(priority: .utility) {
          AgentDiscovery.nativeAgents()
        }.value
        nextDiscovery = Date().addingTimeInterval(5)
      } else {
        discovered = discovered.filter { $0.process.isAlive }
      }
      live += discovered.filter { !reportedIDs.contains($0.id) }
      if live != agents { agents = live }
    } catch { self.error = "Agent status could not be read. \(error.localizedDescription)" }
    let liveIDs = Set(agents.map(\.id))
    targets = targets.filter { liveIDs.contains($0.key) }
    if receipts.keys.contains(where: { !liveIDs.contains($0) }) {
      receipts = receipts.filter { liveIDs.contains($0.key) }
    }
    bindingRetry = bindingRetry.filter { liveIDs.contains($0.key) }
    checkedTokens = checkedTokens.filter { liveIDs.contains($0.key) }
    for id in Array(processWatchers.keys) where !liveIDs.contains(id) {
      processWatchers.removeValue(forKey: id)?.cancel()
    }
    for agent in agents where processWatchers[agent.id] == nil {
      let watcher = DispatchSource.makeProcessSource(
        identifier: agent.process.pid, eventMask: .exit, queue: .main)
      watcher.setEventHandler { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          self.agents.removeAll { $0.id == agent.id }
          self.targets.removeValue(forKey: agent.id)
          self.receipts.removeValue(forKey: agent.id)
          self.processWatchers.removeValue(forKey: agent.id)?.cancel()
          try? self.store.remove(agent)
          UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [
            agent.id
          ])
          self.persistReceipts()
          self.onChange?()
        }
      }
      watcher.resume()
      processWatchers[agent.id] = watcher
    }
    // Pane focus only matters for agents that need attention, so each terminal app is queried
    // when one of its agents does, plus a periodic check that keeps the connection status current.
    let attentive = agents.filter { needsAttention($0) }
    // Permission can change in System Settings, so re-read it when it matters rather than always.
    if Date() >= nextPermissionCheck || (!notificationsEnabled && !attentive.isEmpty) {
      nextPermissionCheck = Date().addingTimeInterval(30)
      await updateNotificationPermission()
    }
    let terminalPollDue = Date() >= nextTerminalPoll
    if terminalPollDue { nextTerminalPoll = Date().addingTimeInterval(30) }
    var focusedID: String?
    if ghosttyAuthorized, ghosttyRunning {
      if needsTerminalQuery(.ghostty, attentive: attentive, due: terminalPollDue) {
        markChecked(.ghostty, attentive: attentive)
        do {
          let snapshot = try await ghostty.snapshot(isRunning: true)
          ghosttyConnected = true
          if error?.hasPrefix("Agent Watcher could not control Ghostty") == true { error = nil }
          focusedID = snapshot.focusedID
          targets = targets.filter { snapshot.terminalIDs.contains($0.value) }
          for agent in attentive
          where agent.terminalApplication == .ghostty && targets[agent.id] == nil {
            guard Date() >= (bindingRetry[agent.id] ?? .distantPast) else { continue }
            bindingRetry[agent.id] = Date().addingTimeInterval(15)
            do { targets[agent.id] = try await ghostty.identify(agent.process) } catch {
              self.error = error.localizedDescription
            }
          }
        } catch {
          ghosttyConnected = false
          self.error = error.localizedDescription
        }
      }
    } else {
      ghosttyConnected = false
    }
    var cmuxSnapshot: CmuxSnapshot?
    var pendingNotification = false
    if cmuxAuthorized, let executable = cmuxExecutable {
      if needsTerminalQuery(.cmux, attentive: attentive, due: terminalPollDue) {
        markChecked(.cmux, attentive: attentive)
        do {
          // Check app focus after the CLI read so switching apps during it
          // cannot acknowledge a response.
          cmuxSnapshot = try await cmux.snapshot(executable: executable, isFrontmost: true)
          cmuxConnected = true
        } catch {
          cmuxConnected = false
          self.error = error.localizedDescription
        }
      }
    } else {
      cmuxConnected = false
    }
    for agent in agents {
      var receipt = receipts[agent.id] ?? AttentionState()
      let focused: Bool
      let focusKnown: Bool
      switch agent.terminalApplication {
      case .ghostty:
        focused = targets[agent.id] != nil && targets[agent.id] == focusedID
        focusKnown = ghosttyConnected && targets[agent.id] != nil
      case .cmux:
        let target = cmuxSnapshot?.target(for: agent.process)
        focused =
          cmuxFrontmost && target != nil && target?.surfaceID == cmuxSnapshot?.focusedSurfaceID
        focusKnown = cmuxConnected && target != nil
      }
      if focusKnown && !focused && receipt.needsAttention(agent) && !notificationsEnabled {
        pendingNotification = true
      }
      if focusKnown,
        receipt.observe(agent, focused: focused, notificationsEnabled: notificationsEnabled)
      {
        notify(agent)
      }
      if focused || !receipt.needsAttention(agent) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [agent.id])
      }
      receipts[agent.id] = receipt
    }
    if receipts != previousReceipts { persistReceipts() }
    if pendingNotification { requestNotificationsIfNeeded() }
  }

  private func requestNotificationsIfNeeded() {
    guard !askedToNotify else { return }
    askedToNotify = true
    Task {
      let center = UNUserNotificationCenter.current()
      guard await center.notificationSettings().authorizationStatus == .notDetermined else {
        return
      }
      // An accessory app does not present the system prompt unless it is a regular app.
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
      do {
        _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        await updateNotificationPermission()
      } catch { self.error = error.localizedDescription }
      NSApp.setActivationPolicy(.accessory)
    }
  }

  private func persistReceipts() {
    if let encoded = try? JSONEncoder().encode(receipts) {
      defaults.set(encoded, forKey: "attentionReceipts")
    }
  }

  private func updateNotificationPermission() async {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    let enabled =
      settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    // Alerts held back without permission are delivered once it is granted.
    if enabled && !notificationsEnabled { checkedTokens = [:] }
    notificationsEnabled = enabled
  }

  private func notify(_ agent: Agent) {
    let content = UNMutableNotificationContent()
    let reason =
      agent.blockers.isEmpty
      ? (agent.failed ? "response failed" : "finished") : "needs your attention"
    content.title = "\(agent.provider.title) \(reason)"
    content.subtitle = agent.project
    content.body = agent.task.isEmpty ? agent.activity : agent.task
    content.sound = .default
    content.userInfo = ["agentID": agent.id]
    content.threadIdentifier = agent.id
    let request = UNNotificationRequest(identifier: agent.id, content: content, trigger: nil)
    Task {
      guard agent.process.isAlive else { return }
      do { try await UNUserNotificationCenter.current().add(request) } catch {
        self.error = "The notification could not be delivered. \(error.localizedDescription)"
      }
    }
  }
}
