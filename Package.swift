// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentWatcher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentWatcher", targets: ["AgentWatcher"]),
        .executable(name: "agent-watcher-hook", targets: ["AgentWatcherHook"]),
    ],
    targets: [
        .target(name: "AgentWatcherCore"),
        .executableTarget(name: "AgentWatcher", dependencies: ["AgentWatcherCore"]),
        .executableTarget(name: "AgentWatcherHook", dependencies: ["AgentWatcherCore"]),
        .testTarget(name: "AgentWatcherCoreTests", dependencies: ["AgentWatcherCore"]),
    ]
)
