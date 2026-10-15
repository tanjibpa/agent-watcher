import Foundation

public struct IntegrationInstaller: Sendable {
  let home: URL
  let root: URL
  let environment: [String: String]
  let resources: URL?
  public var bridge: URL { root.appendingPathComponent("bin/agent-watcher-hook") }
  var piExtension: URL {
    let base =
      environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0) }
      ?? home.appendingPathComponent(".pi/agent")
    return base.appendingPathComponent("extensions/agent-watcher.ts").resolvingSymlinksInPath()
  }
  static let piMarker = "// Agent Watcher integration. Managed by Agent Watcher."

  public init(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    root: URL = StateStore.defaultDirectory,
    resources: URL? = Bundle.main.resourceURL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.home = home
    self.root = root
    self.environment = environment
    self.resources = resources
  }

  public func configuration(_ provider: Provider) -> URL {
    switch provider {
    case .claude:
      let base =
        environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
        ?? home.appendingPathComponent(".claude")
      return base.appendingPathComponent("settings.json").resolvingSymlinksInPath()
    case .codex:
      let base =
        environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
        ?? home.appendingPathComponent(".codex")
      return base.appendingPathComponent("hooks.json").resolvingSymlinksInPath()
    case .pi: return piExtension
    }
  }

  public func installed(_ provider: Provider) -> Bool {
    let data = try? Data(contentsOf: configuration(provider))
    if provider == .pi {
      return data.flatMap { String(data: $0, encoding: .utf8) }?.hasPrefix(Self.piMarker) == true
        && FileManager.default.isExecutableFile(atPath: bridge.path)
    }
    return HookConfiguration.installed(data, provider: provider, bridge: bridge)
      && FileManager.default.isExecutableFile(atPath: bridge.path)
  }

  public func install() throws {
    guard let resources else { throw CocoaError(.fileNoSuchFile) }
    let binary = resources.deletingLastPathComponent().appendingPathComponent(
      "MacOS/agent-watcher-hook")
    let extensionSource = resources.appendingPathComponent("agent-watcher.ts")
    let binaryData = try Data(contentsOf: binary)
    let piData = try Data(contentsOf: extensionSource)
    var writes: [(URL, Data)] = []
    for provider in [Provider.claude, .codex] {
      let url = configuration(provider)
      let data = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
      writes.append(
        (
          url,
          try HookConfiguration.update(data, provider: provider, bridge: bridge, installing: true)
        ))
    }
    if FileManager.default.fileExists(atPath: piExtension.path) {
      let existing = try String(contentsOf: piExtension, encoding: .utf8)
      guard existing.hasPrefix(Self.piMarker) else {
        throw NSError(
          domain: "AgentWatcher", code: 1,
          userInfo: [
            NSLocalizedDescriptionKey:
              "An unrelated file already exists at \(piExtension.path). Rename it before installing the Pi integration."
          ])
      }
    }
    try FileManager.default.createDirectory(
      at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try binaryData.write(to: bridge, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
    for (url, data) in writes { try writeConfiguration(data, to: url) }
    try writeConfiguration(piData, to: piExtension)
  }

  public func uninstall() throws {
    var writes: [(URL, Data)] = []
    for provider in [Provider.claude, .codex] {
      let url = configuration(provider)
      if FileManager.default.fileExists(atPath: url.path) {
        let data = try Data(contentsOf: url)
        writes.append(
          (
            url,
            try HookConfiguration.update(
              data, provider: provider, bridge: bridge, installing: false)
          ))
      }
    }
    for (url, data) in writes { try writeConfiguration(data, to: url) }
    if let content = try? String(contentsOf: piExtension, encoding: .utf8),
      content.hasPrefix(Self.piMarker)
    {
      try FileManager.default.removeItem(at: piExtension)
    }
    if FileManager.default.fileExists(atPath: bridge.path) {
      try FileManager.default.removeItem(at: bridge)
    }
  }

  private func writeConfiguration(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let previous = try? Data(contentsOf: url)
    if previous == data { return }
    var permissions: Int = 0o600
    if let previous {
      permissions =
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        ?? 0o600
      let backup = url.appendingPathExtension("agent-watcher-\(UUID().uuidString.prefix(8)).backup")
      try previous.write(to: backup, options: .withoutOverwriting)
      try FileManager.default.setAttributes(
        [.posixPermissions: permissions], ofItemAtPath: backup.path)
    }
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
  }
}
