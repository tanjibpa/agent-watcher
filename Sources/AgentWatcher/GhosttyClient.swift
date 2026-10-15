import AgentWatcherCore
import AppKit
import Darwin
import Foundation

struct GhosttySnapshot: Sendable {
  var focusedID: String?
  var terminalIDs: Set<String>
}

enum GhosttyError: LocalizedError {
  case notRunning
  case unavailable(String)
  case noTerminal, staleProcess

  var errorDescription: String? {
    switch self {
    case .notRunning: "Open Ghostty to connect your agents."
    case .unavailable(let detail): "Agent Watcher could not control Ghostty. \(detail)"
    case .noTerminal: "The agent’s exact Ghostty pane could not be identified. Try again."
    case .staleProcess: "This CLI has closed."
    }
  }
}

actor GhosttyClient {
  private func run(_ body: String, foundation: Bool = false) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    let imports = foundation ? "use framework \"Foundation\"\nuse scripting additions\n" : ""
    process.arguments = [
      "-e",
      "\(imports)with timeout of 2 seconds\ntell application id \"com.mitchellh.ghostty\"\n\(body)\nend tell\nend timeout",
    ]
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeout.cancel()
    guard process.terminationStatus == 0 else {
      let detail =
        String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      if detail.contains("1743") {
        throw GhosttyError.unavailable(
          "Allow Agent Watcher in System Settings > Privacy & Security > Automation.")
      }
      throw GhosttyError.unavailable(snippet(detail, limit: 200))
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
  }

  func snapshot(isRunning: Bool) throws -> GhosttySnapshot {
    guard isRunning else { throw GhosttyError.notRunning }
    let result = try run(
      """
      set activeID to "-"
      if frontmost then
          try
              set activeID to id of focused terminal of selected tab of front window
          end try
      end if
      set resultText to activeID
      repeat with term in terminals
          set resultText to resultText & linefeed & (id of term)
      end repeat
      return resultText
      """)
    let lines = result.components(separatedBy: .newlines)
    let active = lines.first.flatMap { UUID(uuidString: $0)?.uuidString }
    return GhosttySnapshot(
      focusedID: active,
      terminalIDs: Set(lines.dropFirst().compactMap { UUID(uuidString: $0)?.uuidString }))
  }

  func identify(_ identity: ProcessIdentity) throws -> String {
    guard identity.isAlive else { throw GhosttyError.staleProcess }
    let savedTitles = try run(
      """
      set titleDictionary to current application's NSMutableDictionary's dictionary()
      repeat with term in terminals
          titleDictionary's setObject:(name of term as text) forKey:(id of term as text)
      end repeat
      set dataValue to (current application's NSJSONSerialization's dataWithJSONObject:titleDictionary options:0 |error|:(missing value))
      return (current application's NSString's alloc()'s initWithData:dataValue encoding:4) as text
      """, foundation: true)
    let titles = try JSONDecoder().decode([String: String].self, from: Data(savedTitles.utf8))
    guard identity.isAlive else { throw GhosttyError.staleProcess }
    let descriptor = open(identity.tty, O_WRONLY | O_NOCTTY | O_NONBLOCK | O_NOFOLLOW)
    guard descriptor >= 0 else { throw GhosttyError.noTerminal }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, UInt32(bitPattern: info.st_rdev) == identity.ttyDevice
    else {
      throw GhosttyError.staleProcess
    }
    let marker = "agent-watcher-" + UUID().uuidString
    // A TTY title handshake identifies split panes even when their directories match.
    var previousTitle = ""
    // Ghostty 1.3 parses title-stack escapes but does not implement restoration.
    defer {
      let safeTitle = String(
        String.UnicodeScalarView(
          previousTitle.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
      try? write("\u{1b}]2;\(safeTitle)\u{7}", to: descriptor)
    }
    try write("\u{1b}]2;\(marker)\u{7}", to: descriptor)
    let result = try run(
      """
      repeat 15 times
          repeat with term in terminals
              if name of term is "\(marker)" then return id of term
          end repeat
          delay 0.02
      end repeat
      return ""
      """)
    guard identity.isAlive, let id = UUID(uuidString: result)?.uuidString else {
      throw GhosttyError.noTerminal
    }
    previousTitle = titles[id] ?? ""
    return id
  }

  func focus(_ terminalID: String) throws {
    guard let id = UUID(uuidString: terminalID)?.uuidString else { throw GhosttyError.noTerminal }
    _ = try run("focus (terminal id \"\(id)\")")
  }

  private func write(_ value: String, to descriptor: Int32) throws {
    let data = Data(value.utf8)
    let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
    guard count == data.count else { throw GhosttyError.noTerminal }
  }
}
