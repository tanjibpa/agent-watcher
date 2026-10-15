import Darwin
import Foundation

@main
struct DiscoveryProbe {
  static func main() throws {
    let agents = AgentDiscovery.nativeAgents(pids: [getppid()])
    let directory = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["AGENT_WATCHER_DATA_DIR"]!)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(agents).write(to: directory.appendingPathComponent("discovered.json"))
  }
}
