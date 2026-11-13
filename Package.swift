// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenSFTP",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "OpenSFTP", targets: ["OpenSFTP"])],
    targets: [
        .target(name: "SFTPPTY", linkerSettings: [.linkedLibrary("util", .when(platforms: [.linux]))]),
        .target(name: "SFTPCore", dependencies: ["SFTPPTY"]),
        .executableTarget(name: "OpenSFTP", dependencies: ["SFTPCore"], resources: [.copy("Resources/AppIcon.png")]),
        .testTarget(name: "SFTPCoreTests", dependencies: ["SFTPCore", "SFTPPTY"]),
        .testTarget(name: "OpenSFTPTests", dependencies: ["OpenSFTP", "SFTPCore"])
    ]
)
