import Darwin
import Foundation

public enum AgentDiscovery {
  public static func nativeAgents() -> [Agent] {
    let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
    guard bytes > 0 else { return [] }
    var pids = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.size + 64)
    let capacity = Int32(pids.count * MemoryLayout<Int32>.size)
    let read = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, capacity)
    guard read > 0 else { return [] }
    return nativeAgents(pids: Array(pids.prefix(Int(read) / MemoryLayout<Int32>.size)))
  }

  static func nativeAgents(pids: [Int32]) -> [Agent] {
    pids.compactMap { pid -> Agent? in
      // Most processes have no terminal, so skip them before the costlier path and tty lookups.
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
        info.e_tdev != UInt32.max
      else { return nil }
      guard let process = ProcessIdentity.read(pid), process.tty.hasPrefix("/dev/ttys") else {
        return nil
      }
      let path = process.executable.lowercased()
      let provider: Provider
      if path.hasSuffix("/codex") {
        provider = .codex
      } else if path.hasSuffix("/claude") || path.contains("/claude/") {
        provider = .claude
      } else {
        return nil
      }
      // A background server or command with piped input is not an open interactive CLI.
      var input = vnode_fdinfowithpath()
      let inputSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
      guard
        proc_pidfdinfo(pid, STDIN_FILENO, PROC_PIDFDVNODEPATHINFO, &input, inputSize) == inputSize,
        input.pvip.vip_vi.vi_stat.vst_rdev == process.ttyDevice,
        ProcessIdentity.cli(provider: provider, explicitPID: pid)?.id == process.id
      else { return nil }
      var paths = proc_vnodepathinfo()
      let pathSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
      let cwd: String
      if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, pathSize) == pathSize {
        cwd = withUnsafeBytes(of: paths.pvi_cdir.vip_path) {
          String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
      } else {
        cwd = ""
      }
      return Agent(process: process, provider: provider, sessionID: "", cwd: cwd)
    }
  }
}
