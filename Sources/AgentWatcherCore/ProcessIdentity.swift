import Darwin
import Foundation

public struct ProcessIdentity: Codable, Equatable, Sendable {
  public var pid: Int32
  public var parentPID: Int32
  public var startedSeconds: UInt64
  public var startedMicroseconds: UInt64
  public var tty: String
  public var ttyDevice: UInt32
  public var executable: String

  public var id: String { "\(pid)-\(startedSeconds)-\(startedMicroseconds)" }

  public init(
    pid: Int32, parentPID: Int32, startedSeconds: UInt64, startedMicroseconds: UInt64,
    tty: String, ttyDevice: UInt32, executable: String
  ) {
    self.pid = pid
    self.parentPID = parentPID
    self.startedSeconds = startedSeconds
    self.startedMicroseconds = startedMicroseconds
    self.tty = tty
    self.ttyDevice = ttyDevice
    self.executable = executable
  }

  public static func read(_ pid: Int32) -> ProcessIdentity? {
    guard pid > 1 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    var ttyBuffer = [CChar](repeating: 0, count: 128)
    let ttyName = devname_r(
      Int32(bitPattern: info.e_tdev), S_IFCHR, &ttyBuffer, Int32(ttyBuffer.count))
    let tty = ttyName.map { "/dev/" + String(cString: $0) } ?? ""
    return ProcessIdentity(
      pid: pid, parentPID: Int32(info.pbi_ppid),
      startedSeconds: info.pbi_start_tvsec,
      startedMicroseconds: info.pbi_start_tvusec, tty: tty,
      ttyDevice: info.e_tdev,
      executable: String(
        decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
  }

  public var isAlive: Bool {
    guard let current = Self.read(pid) else { return false }
    return current.id == id && current.ttyDevice == ttyDevice && current.executable == executable
  }

  public static func cli(provider: Provider, explicitPID: Int32? = nil) -> ProcessIdentity? {
    var chain: [ProcessIdentity] = []
    var next = explicitPID ?? getppid()
    for _ in 0..<64 {
      let previous = next
      if let info = read(next) {
        chain.append(info)
        next = info.parentPID
      } else if let parent = parentPID(of: next) {
        // Ghostty's privileged login process hides full details, but exposes its parent PID.
        next = parent
      } else {
        break
      }
      if next <= 1 || next == previous { break }
    }
    guard
      let ghostty = chain.firstIndex(where: {
        $0.executable.hasSuffix("/Ghostty.app/Contents/MacOS/ghostty")
      }),
      let candidate = chain[..<ghostty].first(where: { process in
        if let explicitPID { return process.pid == explicitPID }
        let path = process.executable.lowercased()
        switch provider {
        case .claude: return path.contains("/claude/") || path.hasSuffix("/claude")
        case .codex: return path.hasSuffix("/codex")
        case .pi: return false
        }
      }), candidate.tty.hasPrefix("/dev/ttys")
    else { return nil }
    // CLI tools started by another agent are not separate interactive sessions.
    let parents = chain.drop(while: { $0.pid != candidate.pid }).dropFirst().prefix(while: {
      !$0.executable.hasSuffix("/Ghostty.app/Contents/MacOS/ghostty")
    })
    guard
      !parents.contains(where: {
        $0.executable.hasSuffix("/codex") || $0.executable.hasSuffix("/claude")
          || $0.executable.contains("/claude/")
      })
    else { return nil }
    return candidate
  }

  private static func parentPID(of pid: Int32) -> Int32? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0,
      size == MemoryLayout<kinfo_proc>.size
    else { return nil }
    return info.kp_eproc.e_ppid
  }
}
