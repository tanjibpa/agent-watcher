import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
  case claude, codex, pi

  public var title: String {
    switch self {
    case .claude: "Claude Code"
    case .codex: "Codex"
    case .pi: "Pi"
    }
  }
}

public enum EventKind: String, Codable, Sendable {
  case session, prompt, toolStart, toolEnd, approval, inputStart, inputEnd
  case complete, interrupt, failure, compact
}

public struct HookEvent: Sendable {
  public var kind: EventKind
  public var sessionID: String
  public var cwd: String
  public var prompt = ""
  public var toolID = ""
  public var toolKey = ""
  public var activity = ""
  public var isQuestion = false
  public var question = ""
  public var timestamp = Date().timeIntervalSince1970

  public init(kind: EventKind, sessionID: String, cwd: String) {
    self.kind = kind
    self.sessionID = sessionID
    self.cwd = cwd
  }
}

public struct Activity: Codable, Equatable, Sendable {
  public var key: String
  public var toolID: String
  public var text: String
  public var startedAt: TimeInterval
  /// The question text when this blocker is the agent asking you something; empty if the CLI gave none.
  public var question: String? = nil
}

public struct Agent: Codable, Identifiable, Equatable, Sendable {
  public var version = 1
  public var process: ProcessIdentity
  public var provider: Provider
  public var terminal: TerminalApplication?
  public var sessionID: String
  public var cwd: String
  public var task = ""
  public var working = false
  public var tools: [String: Activity] = [:]
  public var blockers: [String: Activity] = [:]
  public var completedAt: TimeInterval?
  public var failed = false
  public var attentionToken: String?
  public var updatedAt: TimeInterval
  public var turnStartedAt: TimeInterval = 0
  public var stoppedAt: TimeInterval = 0

  public var id: String { process.id }
  public var terminalApplication: TerminalApplication { terminal ?? .ghostty }
  public var project: String {
    cwd.isEmpty ? "Unknown project" : URL(fileURLWithPath: cwd).lastPathComponent
  }
  /// The most recent unanswered question, or nil when the agent is not asking one.
  public var question: String? {
    blockers.values.filter { $0.question != nil }.max(by: { $0.startedAt < $1.startedAt })?
      .question
  }
  public var activity: String {
    if sessionID.isEmpty { return "Waiting for the CLI to report status" }
    if let blocker = blockers.values.max(by: { $0.startedAt < $1.startedAt }) {
      return blocker.text
    }
    if failed { return "Response failed" }
    if let tool = tools.values.max(by: { $0.startedAt < $1.startedAt }) { return tool.text }
    return working ? "Working" : "Waiting for your next message"
  }

  public init(
    process: ProcessIdentity, provider: Provider, sessionID: String, cwd: String,
    now: TimeInterval = Date().timeIntervalSince1970
  ) {
    self.process = process
    self.provider = provider
    terminal = process.terminalApplication
    self.sessionID = sessionID
    self.cwd = cwd
    updatedAt = now
  }

  public mutating func apply(_ event: HookEvent) {
    if sessionID != event.sessionID {
      guard event.kind == .session || event.kind == .prompt else { return }
      guard event.timestamp >= updatedAt else { return }
      self = Agent(
        process: process, provider: provider, sessionID: event.sessionID,
        cwd: event.cwd, now: event.timestamp)
    }
    if !event.cwd.isEmpty { cwd = event.cwd }
    updatedAt = max(updatedAt, event.timestamp)
    let activity = Activity(
      key: event.toolKey, toolID: event.toolID, text: event.activity, startedAt: event.timestamp,
      question: event.isQuestion ? event.question : nil)
    switch event.kind {
    case .session:
      break
    case .prompt:
      guard event.timestamp >= turnStartedAt else { return }
      if task.isEmpty { task = snippet(event.prompt, limit: 180) }
      working = true
      failed = false
      tools = [:]
      blockers = [:]
      completedAt = nil
      attentionToken = nil
      turnStartedAt = event.timestamp
    case .toolStart, .compact:
      guard event.timestamp >= stoppedAt else { return }
      working = true
      failed = false
      completedAt = nil
      if blockers.isEmpty { attentionToken = nil }
      tools[event.toolID] = activity
      if event.isQuestion {
        blockers[event.toolKey] = activity
        attentionToken = "input-\(event.timestamp)-\(event.toolKey)"
      }
    case .toolEnd:
      tools.removeValue(forKey: event.toolID)
      blockers = blockers.filter { $0.key != event.toolKey && $0.value.toolID != event.toolID }
      blockers.removeValue(forKey: "notification-permission")
      if blockers.isEmpty { attentionToken = nil }
    case .approval, .inputStart:
      guard event.timestamp >= stoppedAt else { return }
      if event.toolKey == "notification-permission", !blockers.isEmpty { return }
      working = true
      blockers[event.toolKey] = activity
      attentionToken = "input-\(event.timestamp)-\(event.toolKey)"
    case .inputEnd:
      blockers.removeValue(forKey: event.toolKey)
      if blockers.isEmpty { attentionToken = nil }
    case .complete, .failure, .interrupt:
      guard event.timestamp >= turnStartedAt, event.timestamp >= stoppedAt else { return }
      working = false
      tools = [:]
      blockers = [:]
      stoppedAt = event.timestamp
      failed = event.kind == .failure
      completedAt = event.kind == .interrupt ? nil : event.timestamp
      attentionToken = completedAt.map { "complete-\($0)" }
    }
  }
}

public func snippet(_ value: String, limit: Int = 140) -> String {
  let clean = value.unicodeScalars.filter {
    !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
  }
  let text = String(String.UnicodeScalarView(clean)).split(whereSeparator: \.isWhitespace).joined(
    separator: " ")
  return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
}

public struct AttentionState: Codable, Equatable, Sendable {
  public var readThrough: TimeInterval = 0
  public var notifiedToken: String?

  public init() {}

  public func unread(_ agent: Agent) -> Bool {
    (agent.completedAt ?? 0) > readThrough
  }

  public func needsAttention(_ agent: Agent) -> Bool {
    !agent.blockers.isEmpty || unread(agent)
  }

  public mutating func observe(_ agent: Agent, focused: Bool, notificationsEnabled: Bool) -> Bool {
    if focused, let completed = agent.completedAt { readThrough = max(readThrough, completed) }
    guard needsAttention(agent), let token = agent.attentionToken else { return false }
    if focused {
      // A prompt already seen in its pane must not notify when you switch away.
      notifiedToken = token
      return false
    }
    guard notificationsEnabled, token != notifiedToken else { return false }
    notifiedToken = token
    return true
  }
}
