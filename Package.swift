// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mpx",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "mpx-app", targets: ["MPX"])],
    targets: [
        .systemLibrary(name: "CMPV", pkgConfig: "mpv", providers: [.brew(["mpv"])]),
        .target(name: "PlayerLogic"),
        .executableTarget(name: "MPX", dependencies: ["CMPV", "PlayerLogic"],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("OpenGL")]),
        .testTarget(name: "PlayerLogicTests", dependencies: ["PlayerLogic"]),
        .testTarget(name: "PlaybackIntegrationTests", dependencies: ["MPX", "CMPV"])
    ],
    swiftLanguageVersions: [.v5]
)
