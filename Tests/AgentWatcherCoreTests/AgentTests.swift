import Foundation
import Testing

@testable import AgentWatcherCore

private func process() -> ProcessIdentity {
  ProcessIdentity.read(ProcessInfo.processInfo.processIdentifier)!
}

private func event(
  _ kind: EventKind, at time: TimeInterval = 100, id: String = "a", key: String = "a"
) -> HookEvent {
  var result = HookEvent(kind: kind, sessionID: "session", cwd: "/src/project")
  result.timestamp = time
  result.toolID = id
  result.toolKey = key
  result.activity = "Running tests"
  return result
}

@Test func lifecycleKeepsInitialPromptAndDoesNotExpireIdleAgents() {
  var agent = Agent(
    process: process(), provider: .codex, sessionID: "session", cwd: "/src/project", now: 1)
  var prompt = event(.prompt)
  prompt.prompt = "Fix the login redirect"
  agent.apply(prompt)
  agent.apply(event(.toolStart, at: 101))
  #expect(agent.activity == "Running tests")
  agent.apply(event(.toolEnd, at: 102))
  #expect(agent.activity == "Working")
  agent.apply(event(.complete, at: 103))
  #expect(!agent.working)
  #expect(agent.completedAt == 103)
  prompt.prompt = "yes"
  prompt.timestamp = 104
  agent.apply(prompt)
  #expect(agent.task == "Fix the login redirect")
  #expect(agent.completedAt == nil)
  #expect(agent.working)
}

@Test func parallelToolsDoNotClearAnotherToolsApproval() {
  var agent = Agent(
    process: process(), provider: .claude, sessionID: "session", cwd: "/src/project")
  agent.apply(event(.prompt))
  agent.apply(event(.toolStart, at: 101, id: "a", key: "command-a"))
  agent.apply(event(.toolStart, at: 102, id: "b", key: "command-b"))
  agent.apply(event(.approval, at: 103, id: "b", key: "command-b"))
  agent.apply(event(.toolEnd, at: 104, id: "a", key: "command-a"))
  #expect(agent.tools.count == 1)
  #expect(agent.blockers.count == 1)
  agent.apply(event(.toolEnd, at: 105, id: "b", key: "command-b"))
  #expect(agent.blockers.isEmpty)
  #expect(agent.activity == "Working")
}

@Test func staleToolStartCannotResurrectACompletedTurn() {
  var agent = Agent(process: process(), provider: .codex, sessionID: "session", cwd: "/src/project")
  agent.apply(event(.prompt))
  agent.apply(event(.complete, at: 110))
  agent.apply(event(.toolStart, at: 105))
  #expect(!agent.working)
  #expect(agent.tools.isEmpty)
}

@Test func interruptionDoesNotCreateAnUnreadCompletion() {
  var agent = Agent(process: process(), provider: .codex, sessionID: "session", cwd: "/src/project")
  agent.apply(event(.prompt))
  agent.apply(event(.approval, at: 101))
  agent.apply(event(.interrupt, at: 102))
  #expect(!agent.working)
  #expect(agent.blockers.isEmpty)
  #expect(agent.completedAt == nil)
}

@Test func focusClearsCompletionButNotAnUnresolvedPrompt() {
  var agent = Agent(process: process(), provider: .pi, sessionID: "session", cwd: "/src/project")
  agent.apply(event(.prompt))
  agent.apply(event(.inputStart, at: 101))
  var attention = AttentionState()
  let focusedPromptNotification = attention.observe(
    agent, focused: true, notificationsEnabled: true)
  #expect(!focusedPromptNotification)
  #expect(attention.needsAttention(agent))
  let seenPromptNotification = attention.observe(agent, focused: false, notificationsEnabled: true)
  #expect(!seenPromptNotification)
  agent.apply(event(.complete, at: 102))
  let completedNotification = attention.observe(agent, focused: false, notificationsEnabled: true)
  let duplicateNotification = attention.observe(agent, focused: false, notificationsEnabled: true)
  let focusedCompletionNotification = attention.observe(
    agent, focused: true, notificationsEnabled: true)
  #expect(completedNotification)
  #expect(!duplicateNotification)
  #expect(!focusedCompletionNotification)
  #expect(!attention.needsAttention(agent))
}

@Test func disabledNotificationsDoNotConsumeAttention() {
  var agent = Agent(process: process(), provider: .pi, sessionID: "session", cwd: "/src/project")
  agent.apply(event(.inputStart))
  var attention = AttentionState()
  let blocked = attention.observe(agent, focused: false, notificationsEnabled: false)
  let delivered = attention.observe(agent, focused: false, notificationsEnabled: true)
  #expect(!blocked)
  #expect(delivered)
}

@Test func onlyTheFocusedAgentIsAcknowledged() {
  var a = Agent(process: process(), provider: .pi, sessionID: "session", cwd: "/src/project")
  a.apply(event(.complete))
  var focused = AttentionState()
  var background = AttentionState()
  let focusedNotification = focused.observe(a, focused: true, notificationsEnabled: true)
  let backgroundNotification = background.observe(a, focused: false, notificationsEnabled: true)
  #expect(!focusedNotification)
  #expect(backgroundNotification)
  #expect(background.needsAttention(a))
}

@Test func providerPayloadsUseRealHookFields() throws {
  let data = Data(
    #"{"session_id":"s","cwd":"/src","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"call-1","tool_input":{"command":"bun test"}}"#
      .utf8)
  let parsed = try #require(try HookPayload.parse(data, provider: .codex))
  #expect(parsed.0.kind == .toolStart)
  #expect(parsed.0.toolID == "call-1")
  #expect(parsed.0.activity == "Running bun test")
  let subagent = Data(
    #"{"session_id":"s","cwd":"/src","hook_event_name":"Stop","agent_id":"child"}"#.utf8)
  #expect(try HookPayload.parse(subagent, provider: .claude) == nil)
  let pi = Data(
    #"{"session_id":"s","cwd":"/src","cli_pid":123,"hook_event_name":"UIPromptStart","kind":"confirm","title":"Allow deployment?"}"#
      .utf8)
  let prompt = try #require(try HookPayload.parse(pi, provider: .pi))
  #expect(prompt.0.kind == .inputStart)
  #expect(prompt.1 == 123)
  #expect(prompt.0.activity.contains("Allow deployment?"))
}

@Test func hookInstallationPreservesExistingSettingsAndIsReversible() throws {
  let original = Data(
    #"{"model":"custom","hooks":{"Stop":[{"matcher":".*","hooks":[{"type":"command","command":"my-existing-hook"}]}]}}"#
      .utf8)
  let bridge = URL(
    fileURLWithPath:
      "/Users/someone/Library/Application Support/AgentWatcher/bin/agent-watcher-hook")
  let installed = try HookConfiguration.update(
    original, provider: .claude, bridge: bridge, installing: true)
  let again = try HookConfiguration.update(
    installed, provider: .claude, bridge: bridge, installing: true)
  #expect(installed == again)
  #expect(HookConfiguration.installed(installed, provider: .claude, bridge: bridge))
  let removed = try HookConfiguration.update(
    installed, provider: .claude, bridge: bridge, installing: false)
  let restored = try JSONSerialization.jsonObject(with: removed) as! NSDictionary
  let expected = try JSONSerialization.jsonObject(with: original) as! NSDictionary
  #expect(restored == expected)
  #expect(throws: (any Error).self) {
    try HookConfiguration.update(
      Data("broken json".utf8), provider: .claude, bridge: bridge, installing: true)
  }
}

@Test func liveProcessIdentityChecksStartTime() throws {
  let current = try #require(ProcessIdentity.read(ProcessInfo.processInfo.processIdentifier))
  #expect(current.isAlive)
  var reusedPID = current
  reusedPID.startedMicroseconds += 1
  #expect(!reusedPID.isAlive)
}

@Test func simultaneousHookWritersDoNotLoseToolStarts() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = StateStore(directory: root)
  try store.update(process: process(), provider: .codex, event: event(.prompt))
  final class Failures: @unchecked Sendable {
    let lock = NSLock()
    var count = 0
    func record() {
      lock.lock()
      count += 1
      lock.unlock()
    }
  }
  let failures = Failures()
  DispatchQueue.concurrentPerform(iterations: 24) { i in
    do {
      try store.update(
        process: process(), provider: .codex,
        event: event(.toolStart, at: 101 + Double(i), id: "\(i)", key: "\(i)"))
    } catch { failures.record() }
  }
  #expect(failures.count == 0)
  #expect(try store.agents().first?.tools.count == 24)
}

@Test func piToolResultWithoutArgumentsStillResolvesItsQuestion() {
  var agent = Agent(process: process(), provider: .pi, sessionID: "session", cwd: "/src")
  var start = event(.toolStart, id: "call", key: "with-arguments")
  start.isQuestion = true
  agent.apply(start)
  agent.apply(event(.toolEnd, at: 101, id: "call", key: "without-arguments"))
  #expect(agent.blockers.isEmpty)
}

@Test func exitedProcessIsRemovedAndALateHookCannotRecreateIt() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let child = Process()
  child.executableURL = URL(fileURLWithPath: "/bin/sleep")
  child.arguments = ["30"]
  try child.run()
  defer { if child.isRunning { child.terminate() } }
  let identity = try #require(ProcessIdentity.read(child.processIdentifier))
  let store = StateStore(directory: root)
  try store.update(process: identity, provider: .codex, event: event(.session))
  let agent = try #require(try store.agents().first)
  #expect(identity.isAlive)
  child.terminate()
  child.waitUntilExit()
  #expect(!identity.isAlive)
  try store.remove(agent)
  try store.update(process: identity, provider: .codex, event: event(.complete))
  #expect(try store.agents().isEmpty)
}

@Test func approvalDescriptionsAndDelayedNotificationsDoNotLeaveStuckBlockers() throws {
  let permission = Data(
    #"{"session_id":"session","cwd":"/src","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"bun test","description":"Run tests outside the sandbox"}}"#
      .utf8)
  let completion = Data(
    #"{"session_id":"session","cwd":"/src","hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"call-1","tool_input":{"command":"bun test"}}"#
      .utf8)
  var agent = Agent(process: process(), provider: .claude, sessionID: "session", cwd: "/src")
  agent.apply(try #require(try HookPayload.parse(permission, provider: .claude)).0)
  let token = agent.attentionToken
  var delayedNotification = event(.approval, at: Date().timeIntervalSince1970)
  delayedNotification.toolKey = "notification-permission"
  agent.apply(delayedNotification)
  #expect(agent.blockers.count == 1)
  #expect(agent.attentionToken == token)
  agent.apply(try #require(try HookPayload.parse(completion, provider: .claude)).0)
  #expect(agent.blockers.isEmpty)
}

@Test func backgroundWorkClearsAnEarlierCompletionWithoutClearingUserInput() throws {
  let payload = Data(
    #"{"session_id":"session","cwd":"/src","hook_event_name":"PreToolUse","tool_name":"subagent","tool_use_id":"background","tool_input":{"background_count":2,"background_detail":"reviewer, builder"}}"#
      .utf8)
  var background = try #require(try HookPayload.parse(payload, provider: .pi)).0
  background.timestamp = 102
  #expect(background.activity == "Running 2 subagents: reviewer, builder")
  var agent = Agent(process: process(), provider: .pi, sessionID: "session", cwd: "/src")
  agent.apply(event(.prompt))
  agent.apply(event(.complete, at: 101))
  #expect(agent.completedAt == 101)
  agent.apply(background)
  #expect(agent.working)
  #expect(agent.completedAt == nil)
  #expect(agent.attentionToken == nil)
  #expect(agent.activity == "Running 2 subagents: reviewer, builder")
  agent.apply(event(.inputStart, at: 103, id: "question", key: "question"))
  let attention = agent.attentionToken
  background.timestamp = 104
  agent.apply(background)
  #expect(agent.blockers.count == 1)
  #expect(agent.attentionToken == attention)
}

@Test func questionsShowTheirTextSeparatelyFromApprovals() throws {
  let ask = Data(
    #"{"session_id":"session","cwd":"/src","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"ask-1","tool_input":{"questions":[{"question":"Which database should I use?","header":"Database","options":[{"label":"Postgres"},{"label":"SQLite"}],"multiSelect":false},{"question":"Add migrations?","header":"Migrations","options":[]}]}}"#
      .utf8)
  let permission = Data(
    #"{"session_id":"session","cwd":"/src","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database should I use?","header":"Database","options":[{"label":"Postgres"},{"label":"SQLite"}],"multiSelect":false},{"question":"Add migrations?","header":"Migrations","options":[]}]}}"#
      .utf8)
  let answered = Data(
    #"{"session_id":"session","cwd":"/src","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_use_id":"ask-1","tool_input":{"questions":[{"question":"Which database should I use?","header":"Database","options":[{"label":"Postgres"},{"label":"SQLite"}],"multiSelect":false},{"question":"Add migrations?","header":"Migrations","options":[]}]}}"#
      .utf8)
  var agent = Agent(process: process(), provider: .claude, sessionID: "session", cwd: "/src")
  agent.apply(event(.prompt))
  agent.apply(event(.approval, at: 101, id: "bash", key: "bash"))
  #expect(agent.question == nil)
  var start = try #require(try HookPayload.parse(ask, provider: .claude)).0
  start.timestamp = 102
  agent.apply(start)
  #expect(agent.question == "Which database should I use? (+1 more)")
  #expect(agent.activity == "Waiting for your answer")
  var approval = try #require(try HookPayload.parse(permission, provider: .claude)).0
  approval.timestamp = 103
  agent.apply(approval)
  #expect(agent.blockers.count == 2)
  #expect(agent.question == "Which database should I use? (+1 more)")
  var end = try #require(try HookPayload.parse(answered, provider: .claude)).0
  end.timestamp = 104
  agent.apply(end)
  #expect(agent.question == nil)
  #expect(agent.blockers.count == 1)

  let codex = Data(
    #"{"session_id":"s","cwd":"/src","hook_event_name":"PreToolUse","tool_name":"request_user_input","tool_use_id":"c","tool_input":{"questions":[{"id":"q","header":"Scope","question":"Should I update the tests too?","options":[]}]}}"#
      .utf8)
  #expect(try #require(try HookPayload.parse(codex, provider: .codex)).0.question
    == "Should I update the tests too?")
  let pi = Data(
    #"{"session_id":"s","cwd":"/src","hook_event_name":"PreToolUse","tool_name":"ask_user","tool_use_id":"p","tool_input":{"question":"Ship it?"}}"#
      .utf8)
  #expect(try #require(try HookPayload.parse(pi, provider: .pi)).0.question == "Ship it?")
}
