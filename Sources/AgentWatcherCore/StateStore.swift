import Darwin
import Foundation

public struct StateStore: Sendable {
  public let directory: URL

  public static var defaultDirectory: URL {
    if let path = ProcessInfo.processInfo.environment["AGENT_WATCHER_DATA_DIR"], !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/AgentWatcher", isDirectory: true)
  }

  public init(directory: URL = Self.defaultDirectory) { self.directory = directory }
  public var sessionsDirectory: URL {
    directory.appendingPathComponent("sessions", isDirectory: true)
  }

  public func prepare() throws {
    try FileManager.default.createDirectory(
      at: sessionsDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  public func update(process: ProcessIdentity, provider: Provider, event: HookEvent) throws {
    guard process.isAlive else { return }
    try prepare()
    let lockURL = sessionsDirectory.appendingPathComponent(process.id + ".lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { close(descriptor) }
    let deadline = Date().addingTimeInterval(0.2)
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      guard Date() < deadline else { throw POSIXError(.EWOULDBLOCK) }
      usleep(2_000)
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    guard process.isAlive else { return }
    let url = sessionsDirectory.appendingPathComponent(process.id + ".json")
    var agent =
      (try? read(url))
      ?? Agent(
        process: process, provider: provider,
        sessionID: event.sessionID, cwd: event.cwd)
    guard agent.process == process, agent.provider == provider else { throw POSIXError(.EINVAL) }
    agent.apply(event)
    let data = try JSONEncoder().encode(agent)
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  public func agents() throws -> [Agent] {
    guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: sessionsDirectory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }.compactMap { try? read($0) }
  }

  public func remove(_ agent: Agent) throws {
    guard !agent.process.isAlive else { return }
    let lockURL = sessionsDirectory.appendingPathComponent(agent.id + ".lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
    defer { _ = flock(descriptor, LOCK_UN) }
    let url = sessionsDirectory.appendingPathComponent(agent.id + ".json")
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    try FileManager.default.removeItem(at: lockURL)
  }

  private func read(_ url: URL) throws -> Agent {
    let values = try url.resourceValues(forKeys: [
      .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      (values.fileSize ?? .max) <= 262_144
    else { throw POSIXError(.EINVAL) }
    let agent = try JSONDecoder().decode(Agent.self, from: Data(contentsOf: url))
    guard agent.version == 1, agent.id == url.deletingPathExtension().lastPathComponent else {
      throw POSIXError(.EINVAL)
    }
    return agent
  }
}
