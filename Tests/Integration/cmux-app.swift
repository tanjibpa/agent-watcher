import AppKit
import Foundation

@MainActor
final class CmuxAppProbe: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
      print("FAIL: cmux polling stopped under the AppKit run loop")
      exit(2)
    }
    Task {
      do {
        let client = CmuxClient()
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        for _ in 0..<20 {
          async let first = client.snapshot(executable: executable, isFrontmost: false)
          async let second = client.snapshot(executable: executable, isFrontmost: false)
          _ = try await (first, second)
        }
        print("PASS: cmux polling continues under the AppKit run loop")
        exit(0)
      } catch {
        print("FAIL: \(error.localizedDescription)")
        exit(1)
      }
    }
  }
}

@main
struct CmuxAppTest {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let delegate = CmuxAppProbe()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
  }
}
