import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private var item: NSStatusItem!
  private var popover: NSPopover!
  private var model: AppModel!

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    UNUserNotificationCenter.current().delegate = self
    model = AppModel()
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.image = NSImage(
        systemSymbolName: "terminal", accessibilityDescription: "Agent Watcher")
      button.imagePosition = .imageLeading
      button.target = self
      button.action = #selector(togglePopover)
    }
    popover = NSPopover()
    popover.behavior = .transient
    popover.contentViewController = NSHostingController(
      rootView: PopoverView(model: model) { [weak self] in self?.popover.performClose(nil) })
    model.onChange = { [weak self] in self?.updateStatus() }
    updateStatus()
    if !model.anyIntegrationInstalled { showPopover() }
  }

  private func updateStatus() {
    let count = model.attentionCount
    item.button?.title = count > 0 ? " \(model.agents.count) · \(count)!" : " \(model.agents.count)"
    item.button?.toolTip = "\(model.agents.count) open agents, \(count) need attention"
    item.button?.setAccessibilityLabel(
      "Agent Watcher, \(model.agents.count) open agents, \(count) need attention")
  }

  @objc private func togglePopover() {
    if popover.isShown { popover.performClose(nil) } else { showPopover() }
  }

  private func showPopover() {
    guard let button = item.button else { return }
    model.refreshInstallation()
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
    NSApp.activate(ignoringOtherApps: true)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    guard let id = response.notification.request.content.userInfo["agentID"] as? String else {
      return
    }
    await model.focus(id: id)
  }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
