import Darwin
import Foundation

public actor CmuxClient {
  public enum Failure: LocalizedError {
    case notRunning, noTerminal
    case unavailable(String)

    public var errorDescription: String? {
      switch self {
      case .notRunning: "Open cmux to connect your agents."
      case .noTerminal:
        "The agent's exact cmux pane could not be identified. Reconnect cmux and try again."
      case .unavailable(let detail): "Agent Watcher could not connect to cmux. \(detail)"
      }
    }
  }

  public init() {}

  public func snapshot(executable: URL, isFrontmost: Bool) async throws -> CmuxSnapshot {
    let data = try await run(
      executable: executable, method: "system.tree", params: ["all_windows": true])
    return try CmuxSnapshot(data: data, isFrontmost: isFrontmost)
  }

  public func focus(_ target: CmuxSnapshot.Target, executable: URL) async throws {
    _ = try await run(
      executable: executable, method: "surface.focus",
      params: [
        "window_id": target.windowID.uuidString,
        "workspace_id": target.workspaceID.uuidString,
        "surface_id": target.surfaceID.uuidString,
      ])
  }

  private func run(executable: URL, method: String, params: [String: Any]) async throws -> Data {
    let process = Process()
    process.executableURL = executable
    let data = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
    process.arguments = ["rpc", method, String(decoding: data, as: UTF8.self)]
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let deadline = Task {
      try await Task.sleep(for: .seconds(3))
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    defer { deadline.cancel() }
    return try await withTaskCancellationHandler {
      let outputFD = output.fileHandleForReading.fileDescriptor
      let errorFD = errors.fileHandleForReading.fileDescriptor
      async let stdout = Task.detached { try Self.read(outputFD) }.value
      async let stderr = Task.detached { try Self.read(errorFD) }.value
      let (result, errorData) = try await (stdout, stderr)
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        let detail = snippet(String(decoding: errorData, as: UTF8.self), limit: 240)
        if detail.localizedCaseInsensitiveContains("access denied")
          || detail.localizedCaseInsensitiveContains("authentication required")
        {
          throw Failure.unavailable(
            "In cmux Settings > Automation, choose Automation or Password for Socket Control Mode, then reconnect."
          )
        }
        throw Failure.unavailable(
          detail.isEmpty ? "The cmux command failed or timed out. Try reconnecting." : detail)
      }
      return result
    } onCancel: {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
  }

  private static func read(_ descriptor: Int32) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { return result }
      if count < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      guard result.count + count <= 4_194_304 else {
        throw Failure.unavailable("The cmux response exceeded the size limit.")
      }
      result.append(contentsOf: buffer.prefix(count))
    }
  }
}
