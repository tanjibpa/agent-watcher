import Foundation

public enum HookConfiguration {
  public static func command(bridge: URL, provider: Provider) -> String {
    "'" + bridge.path.replacingOccurrences(of: "'", with: "'\\''") + "' " + provider.rawValue
  }

  public static func update(_ data: Data?, provider: Provider, bridge: URL, installing: Bool) throws
    -> Data
  {
    var root: [String: Any] = [:]
    if let data {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CocoaError(.propertyListReadCorrupt)
      }
      root = object
    }
    if let hooks = root["hooks"], !(hooks is [String: Any]) {
      throw CocoaError(.propertyListReadCorrupt)
    }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    let ownCommand = command(bridge: bridge, provider: provider)
    for key in Array(hooks.keys) {
      guard let groups = hooks[key] as? [[String: Any]] else {
        throw CocoaError(.propertyListReadCorrupt)
      }
      hooks[key] = groups.compactMap { group -> [String: Any]? in
        guard let commands = group["hooks"] as? [[String: Any]] else { return group }
        let remaining = commands.filter { ($0["command"] as? String) != ownCommand }
        if remaining.count == commands.count { return group }
        guard !remaining.isEmpty else { return nil }
        var copy = group
        copy["hooks"] = remaining
        return copy
      }
      if (hooks[key] as? [[String: Any]])?.isEmpty == true { hooks.removeValue(forKey: key) }
    }
    if installing {
      var events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
        "Stop", "PreCompact", "PostCompact",
      ]
      if provider == .claude { events += ["Notification", "PostToolUseFailure", "StopFailure"] }
      if provider == .codex { events += ["Interrupt"] }
      for event in events {
        var groups = hooks[event] as? [[String: Any]] ?? []
        var group: [String: Any] = [
          "hooks": [["type": "command", "command": ownCommand, "timeout": 2]]
        ]
        if event == "Notification" { group["matcher"] = "permission_prompt" }
        groups.append(group)
        hooks[event] = groups
      }
    }
    if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
    return try JSONSerialization.data(
      withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      + Data("\n".utf8)
  }

  public static func installed(_ data: Data?, provider: Provider, bridge: URL) -> Bool {
    guard let data,
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let hooks = root["hooks"] as? [String: [[String: Any]]]
    else { return false }
    let expected = command(bridge: bridge, provider: provider)
    return hooks["SessionStart"]?.contains(where: { group in
      (group["hooks"] as? [[String: Any]])?.contains(where: { $0["command"] as? String == expected }
      ) == true
    }) == true
  }
}
