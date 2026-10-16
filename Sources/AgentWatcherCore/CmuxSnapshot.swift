import Foundation

public struct CmuxSnapshot: Sendable {
  public struct Target: Equatable, Sendable {
    public let windowID: UUID
    public let workspaceID: UUID
    public let surfaceID: UUID
    public let tty: String
  }

  public let targets: [Target]
  public let focusedSurfaceID: UUID?

  public init(data: Data, isFrontmost: Bool) throws {
    let tree = try JSONDecoder().decode(Tree.self, from: data)
    var targets: [Target] = []
    for window in tree.windows {
      for workspace in window.workspaces {
        for pane in workspace.panes {
          for surface in pane.surfaces where surface.type == "terminal" {
            guard let name = surface.tty else { continue }
            let tty = name.hasPrefix("/dev/") ? String(name.dropFirst(5)) : name
            guard tty.hasPrefix("ttys"), !tty.dropFirst(4).isEmpty,
              tty.dropFirst(4).allSatisfy(\.isNumber)
            else { continue }
            targets.append(
              Target(
                windowID: window.id, workspaceID: workspace.id,
                surfaceID: surface.id, tty: "/dev/" + tty))
          }
        }
      }
    }
    self.targets = targets
    focusedSurfaceID = isFrontmost ? tree.active?.surfaceID : nil
  }

  public func target(for process: ProcessIdentity) -> Target? {
    let matches = targets.filter { $0.tty == process.tty }
    return matches.count == 1 ? matches.first : nil
  }

  private struct Tree: Decodable {
    let active: Active?
    let windows: [Window]
  }
  private struct Active: Decodable {
    let surfaceID: UUID?
    enum CodingKeys: String, CodingKey { case surfaceID = "surface_id" }
  }
  private struct Window: Decodable {
    let id: UUID
    let workspaces: [Workspace]
  }
  private struct Workspace: Decodable {
    let id: UUID
    let panes: [Pane]
  }
  private struct Pane: Decodable { let surfaces: [Surface] }
  private struct Surface: Decodable {
    let id: UUID
    let type: String
    let tty: String?
  }
}
