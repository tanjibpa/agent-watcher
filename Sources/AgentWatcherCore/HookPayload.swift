import CryptoKit
import Foundation

public enum HookPayload {
  public static func parse(_ data: Data, provider: Provider) throws -> (HookEvent, Int32?)? {
    guard data.count <= 1_048_576,
      let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let sessionID = payload["session_id"] as? String, !sessionID.isEmpty,
      let name = payload["hook_event_name"] as? String
    else { return nil }
    // Subagent tool activity can update the parent row; subagent stops cannot finish it.
    if payload["agent_id"] != nil,
      ["Stop", "StopFailure", "SessionStart", "SessionEnd", "UserPromptSubmit"].contains(name)
    {
      return nil
    }
    let kind: EventKind
    switch name {
    case "SessionStart": kind = .session
    case "UserPromptSubmit": kind = .prompt
    case "PreToolUse": kind = .toolStart
    case "PostToolUse", "PostToolUseFailure": kind = .toolEnd
    case "PermissionRequest": kind = .approval
    case "UIPromptStart": kind = .inputStart
    case "UIPromptEnd": kind = .inputEnd
    case "Stop": kind = .complete
    case "Interrupt": kind = .interrupt
    case "StopFailure": kind = .failure
    case "PreCompact": kind = .compact
    case "PostCompact": kind = .toolEnd
    case "Notification":
      guard payload["notification_type"] as? String == "permission_prompt" else { return nil }
      kind = .approval
    default: return nil
    }
    var event = HookEvent(kind: kind, sessionID: sessionID, cwd: payload["cwd"] as? String ?? "")
    event.prompt = payload["prompt"] as? String ?? ""
    let tool = payload["tool_name"] as? String ?? ""
    let input = payload["tool_input"] as? [String: Any] ?? [:]
    // Approval events can add a description that tool-completion events omit.
    let identityInput: [String: Any]
    if let command = (input["command"] ?? input["cmd"]) as? String {
      identityInput = ["command": command]
    } else {
      identityInput = input
    }
    let canonical = try JSONSerialization.data(
      withJSONObject: identityInput, options: [.sortedKeys])
    let digest = SHA256.hash(data: Data(tool.utf8) + canonical).prefix(12).map {
      String(format: "%02x", $0)
    }.joined()
    event.toolKey = digest
    event.toolID = payload["tool_use_id"] as? String ?? digest
    event.isQuestion = ["AskUserQuestion", "request_user_input", "ask_user", "question"].contains(
      tool)
    event.activity = describe(tool: tool, input: input)
    if event.isQuestion {
      event.question = snippet(question(in: input), limit: 240)
    }
    if kind == .approval, event.isQuestion {
      // Claude Code can ask permission to show AskUserQuestion; it is still a question.
      event.activity = "Waiting for your answer"
    } else if kind == .approval {
      event.activity = "Approval needed" + (event.activity.isEmpty ? "" : ": " + event.activity)
      if name == "Notification" { event.toolKey = "notification-permission" }
    } else if kind == .inputStart || kind == .inputEnd {
      event.toolKey =
        "ui-" + (payload["kind"] as? String ?? "prompt") + "-" + (payload["title"] as? String ?? "")
      event.activity =
        "Input needed: " + snippet(payload["title"] as? String ?? "Answer the agent", limit: 120)
    } else if kind == .compact || name == "PostCompact" {
      event.toolID = "compaction"
      event.activity = "Compacting conversation"
    }
    if kind == .toolStart, event.isQuestion { event.activity = "Waiting for your answer" }
    event.activity = snippet(event.activity, limit: 180)
    return (event, (payload["cli_pid"] as? NSNumber)?.int32Value)
  }

  /// Claude Code's AskUserQuestion and Codex's request_user_input pass a `questions` array;
  /// Pi question tools usually pass a single string.
  public static func question(in input: [String: Any]) -> String {
    if let questions = input["questions"] as? [[String: Any]], let first = questions.first {
      let text = (first["question"] ?? first["header"]) as? String ?? ""
      guard !text.isEmpty else { return "" }
      return questions.count > 1 ? "\(text) (+\(questions.count - 1) more)" : text
    }
    for key in ["question", "prompt", "message", "title"] {
      if let text = input[key] as? String, !text.isEmpty { return text }
    }
    return ""
  }

  public static func describe(tool: String, input: [String: Any]) -> String {
    let path = (input["file_path"] ?? input["path"] ?? input["file"]) as? String
    let filename = path.map { URL(fileURLWithPath: $0).lastPathComponent }
    switch tool.lowercased() {
    case "read", "read_file": return "Reading " + (filename ?? "a file")
    case "edit", "write", "write_file", "apply_patch": return "Editing " + (filename ?? "files")
    case "bash", "exec_command", "shell", "shell_command":
      return "Running "
        + snippet(input["command"] as? String ?? input["cmd"] as? String ?? "a command", limit: 150)
    case "grep", "rg", "find", "glob": return "Searching files"
    case "websearch", "web_search": return "Searching the web"
    case "agent", "task", "spawn_agent": return "Waiting for a subagent"
    case "subagent":
      guard let count = input["background_count"] as? Int, count > 0 else {
        return "Waiting for a subagent"
      }
      let detail = snippet(input["background_detail"] as? String ?? "", limit: 120)
      return "Running \(count) subagent\(count == 1 ? "" : "s")"
        + (detail.isEmpty ? "" : ": " + detail)
    case "": return ""
    default: return "Using " + snippet(tool, limit: 140)
    }
  }
}
