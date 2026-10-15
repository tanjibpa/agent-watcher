import AgentWatcherCore
import Darwin
import Foundation

// Hooks only report state. Monitoring failures must never block an agent's work.
do {
  if CommandLine.arguments.count == 2,
    let provider = Provider(rawValue: CommandLine.arguments[1])
  {
    var data = Data()
    while data.count <= 1_048_576 {
      guard
        let chunk = try FileHandle.standardInput.read(
          upToCount: min(65_536, 1_048_577 - data.count)), !chunk.isEmpty
      else { break }
      data.append(chunk)
    }
    if let (event, explicitPID) = try HookPayload.parse(data, provider: provider),
      let process = ProcessIdentity.cli(provider: provider, explicitPID: explicitPID)
    {
      try StateStore().update(process: process, provider: provider, event: event)
    }
  }
} catch {
  // stdout and stderr belong to the CLI hook protocol, not the menu bar app.
}
