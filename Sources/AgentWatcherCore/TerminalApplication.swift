import Foundation

public enum TerminalApplication: String, Codable, CaseIterable, Sendable {
  case ghostty, cmux

  public var title: String { self == .ghostty ? "Ghostty" : "cmux" }

  public var bundleIdentifier: String {
    self == .ghostty ? "com.mitchellh.ghostty" : "com.cmuxterm.app"
  }

  func matches(executable: String) -> Bool {
    switch self {
    case .ghostty: executable.hasSuffix("/Ghostty.app/Contents/MacOS/ghostty")
    case .cmux: executable.hasSuffix("/cmux.app/Contents/MacOS/cmux")
    }
  }
}
