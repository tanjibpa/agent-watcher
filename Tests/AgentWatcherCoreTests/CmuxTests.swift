import Foundation
import Testing

@testable import AgentWatcherCore

struct CmuxTests {
  private func process(tty: String) -> ProcessIdentity {
    ProcessIdentity(
      pid: Int32.max, parentPID: 1, startedSeconds: 1, startedMicroseconds: 0,
      tty: tty, ttyDevice: 1, executable: "/runtime/node")
  }

  private func surface(_ id: UUID, tty: String, type: String = "terminal") -> [String: Any] {
    ["id": id.uuidString, "type": type, "tty": tty, "title": "same project"]
  }

  private func window(_ id: UUID, workspace: UUID, surfaces: [[String: Any]]) -> [String: Any] {
    [
      "id": id.uuidString,
      "workspaces": [
        [
          "id": workspace.uuidString, "panes": [["surfaces": surfaces]],
        ]
      ],
    ]
  }

  private func tree(_ windows: [[String: Any]], active: UUID) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "active": ["surface_id": active.uuidString], "windows": windows,
    ])
  }

  @Test func matchesExactTerminalsAcrossWindowsAndAcknowledgesOnlyForegroundFocus() throws {
    let first = UUID()
    let second = UUID()
    let windowA = UUID()
    let windowB = UUID()
    let workspaceA = UUID()
    let workspaceB = UUID()
    let data = try tree(
      [
        window(windowA, workspace: workspaceA, surfaces: [surface(first, tty: "ttys001")]),
        window(windowB, workspace: workspaceB, surfaces: [surface(second, tty: "/dev/ttys002")]),
      ], active: second)
    let snapshot = try CmuxSnapshot(data: data, isFrontmost: true)
    #expect(snapshot.targets.count == 2)
    #expect(snapshot.target(for: process(tty: "/dev/ttys001"))?.surfaceID == first)
    let target = try #require(snapshot.target(for: process(tty: "/dev/ttys002")))
    #expect(target.windowID == windowB)
    #expect(target.workspaceID == workspaceB)
    #expect(target.surfaceID == second)
    #expect(snapshot.focusedSurfaceID == second)
    #expect(try CmuxSnapshot(data: data, isFrontmost: false).focusedSurfaceID == nil)
  }

  @Test func doesNotGuessForDuplicateTTYsOrBrowserPanels() throws {
    let first = UUID()
    let second = UUID()
    let browser = UUID()
    let data = try tree(
      [
        window(
          UUID(), workspace: UUID(),
          surfaces: [
            surface(first, tty: "ttys001"), surface(second, tty: "ttys001"),
            surface(browser, tty: "ttys002", type: "browser"),
          ])
      ], active: browser)
    let snapshot = try CmuxSnapshot(data: data, isFrontmost: true)
    #expect(snapshot.target(for: process(tty: "/dev/ttys001")) == nil)
    #expect(snapshot.target(for: process(tty: "/dev/ttys002")) == nil)
    #expect(snapshot.focusedSurfaceID == browser)
    #expect(throws: (any Error).self) {
      try CmuxSnapshot(data: Data("{}".utf8), isFrontmost: true)
    }
  }

  @Test func oldSnapshotsRemainGhosttyAndNewSnapshotsPreserveCmux() throws {
    var agent = Agent(
      process: process(tty: "/dev/ttys001"), provider: .pi, sessionID: "s", cwd: "/src")
    agent.terminal = .cmux
    let encoded = try JSONEncoder().encode(agent)
    #expect(try JSONDecoder().decode(Agent.self, from: encoded).terminalApplication == .cmux)
    var old = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    old.removeValue(forKey: "terminal")
    let data = try JSONSerialization.data(withJSONObject: old)
    #expect(try JSONDecoder().decode(Agent.self, from: data).terminalApplication == .ghostty)
  }

  private func quote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  @Test func clientReadsAllWindowsAndFocusesWithExplicitStableIDs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = UUID()
    let second = UUID()
    let ownerWindow = UUID()
    let ownerWorkspace = UUID()
    let data = try tree(
      [
        window(UUID(), workspace: UUID(), surfaces: [surface(first, tty: "ttys001")]),
        window(ownerWindow, workspace: ownerWorkspace, surfaces: [surface(second, tty: "ttys002")]),
      ], active: first)
    let response = root.appendingPathComponent("response.json")
    try data.write(to: response)
    let log = root.appendingPathComponent("calls")
    let executable = root.appendingPathComponent("fake cmux")
    try Data(
      """
      #!/bin/sh
      printf '%s\\n' "$@" >> \(quote(log.path))
      if [ "$2" = 'system.tree' ]; then cat \(quote(response.path)); else printf '{}'; fi
      """.utf8
    ).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CmuxClient()
    let snapshot = try await client.snapshot(executable: executable, isFrontmost: false)
    let target = try #require(snapshot.target(for: process(tty: "/dev/ttys002")))
    try await client.focus(target, executable: executable)
    let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(calls.count == 6)
    #expect(calls[0] == "rpc" && calls[1] == "system.tree")
    #expect(calls[2] == #"{"all_windows":true}"#)
    #expect(calls[3] == "rpc" && calls[4] == "surface.focus")
    let params = try #require(
      try JSONSerialization.jsonObject(with: Data(calls[5].utf8)) as? [String: String])
    #expect(
      params == [
        "window_id": ownerWindow.uuidString, "workspace_id": ownerWorkspace.uuidString,
        "surface_id": second.uuidString,
      ])
  }

  @Test func socketAccessDenialIsActionableAndCommandsHaveADeadline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("cmux")
    try Data(
      "#!/bin/sh\nprintf 'Access denied - only processes started inside cmux can connect' >&2\nexit 1\n"
        .utf8
    ).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CmuxClient()
    do {
      _ = try await client.snapshot(executable: executable, isFrontmost: false)
      Issue.record("Denied socket access must not look connected")
    } catch let error as CmuxClient.Failure {
      #expect(error.localizedDescription.contains("Socket Control Mode"))
    }
    try Data("#!/bin/sh\nexec 1>&- 2>&-\nexec /bin/sleep 10\n".utf8).write(to: executable)
    do {
      _ = try await client.snapshot(executable: executable, isFrontmost: false)
      Issue.record("A stalled command must fail")
    } catch let error as CmuxClient.Failure {
      #expect(error.localizedDescription.contains("timed out"))
    }
  }
}
