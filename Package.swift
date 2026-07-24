// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SSHStudio",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "SSHStudio",
            dependencies: ["SwiftTerm"],
            path: "Sources/SSHStudio",
            exclude: ["Resources"]
        ),
        .executableTarget(
            name: "SSHStudioAskPass",
            dependencies: [],
            path: "Sources/SSHStudioAskPass"
        ),
        .testTarget(
            name: "SSHStudioTests",
            dependencies: ["SSHStudio"],
            path: "Tests/SSHStudioTests"
        ),
    ]
)
