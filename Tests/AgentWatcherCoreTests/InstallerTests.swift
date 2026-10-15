import Foundation
import Testing

@testable import AgentWatcherCore

private func installerFixture() throws -> (URL, IntegrationInstaller) {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let resources = home.appendingPathComponent("resources")
  try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
  let executables = home.appendingPathComponent("MacOS")
  try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
  try Data("test executable".utf8).write(
    to: executables.appendingPathComponent("agent-watcher-hook"))
  try Data((IntegrationInstaller.piMarker + "\nexport default function () {}\n").utf8).write(
    to: resources.appendingPathComponent("agent-watcher.ts"))
  return (
    home,
    IntegrationInstaller(
      home: home, root: home.appendingPathComponent("support"), resources: resources,
      environment: [:])
  )
}

@Test func installationAndRemovalPreserveUserFilesAndBackUpChanges() throws {
  let (home, installer) = try installerFixture()
  defer { try? FileManager.default.removeItem(at: home) }
  let claude = installer.configuration(.claude)
  try FileManager.default.createDirectory(
    at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
  let original = Data(
    #"{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"user-hook"}]}]}}"#
      .utf8)
  try original.write(to: claude)
  try installer.install()
  #expect(Provider.allCases.allSatisfy { installer.installed($0) })
  let installed = try Data(contentsOf: claude)
  try installer.install()
  #expect(try Data(contentsOf: claude) == installed)
  let backups = try FileManager.default.contentsOfDirectory(
    at: claude.deletingLastPathComponent(), includingPropertiesForKeys: nil
  )
  .filter { $0.pathExtension == "backup" }
  #expect(backups.count == 1)
  #expect(try Data(contentsOf: backups[0]) == original)
  try installer.uninstall()
  let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: claude)) as! NSDictionary
  let expected = try JSONSerialization.jsonObject(with: original) as! NSDictionary
  #expect(restored == expected)
  #expect(!FileManager.default.fileExists(atPath: installer.bridge.path))
  #expect(!FileManager.default.fileExists(atPath: installer.configuration(.pi).path))
}

@Test func invalidCodexConfigurationDoesNotPartiallyInstallClaudeHooks() throws {
  let (home, installer) = try installerFixture()
  defer { try? FileManager.default.removeItem(at: home) }
  let codex = installer.configuration(.codex)
  try FileManager.default.createDirectory(
    at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("not json".utf8).write(to: codex)
  #expect(throws: (any Error).self) { try installer.install() }
  #expect(!FileManager.default.fileExists(atPath: installer.configuration(.claude).path))
  #expect(!FileManager.default.fileExists(atPath: installer.bridge.path))
}

@Test func existingUnrelatedPiExtensionIsNotOverwritten() throws {
  let (home, installer) = try installerFixture()
  defer { try? FileManager.default.removeItem(at: home) }
  let pi = installer.configuration(.pi)
  try FileManager.default.createDirectory(
    at: pi.deletingLastPathComponent(), withIntermediateDirectories: true)
  let original = Data("my own extension".utf8)
  try original.write(to: pi)
  #expect(throws: (any Error).self) { try installer.install() }
  #expect(try Data(contentsOf: pi) == original)
  #expect(!FileManager.default.fileExists(atPath: installer.configuration(.claude).path))
}
