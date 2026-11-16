// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Inkspring",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .systemLibrary(name: "CArchive"),
        .systemLibrary(name: "CCMark"),
        .target(name: "InkspringSchedule"),
        .executableTarget(name: "Inkspring", dependencies: [
            "CSQLite", "CArchive", "CCMark", "InkspringSchedule",
            .product(name: "Sparkle", package: "Sparkle")
        ], linkerSettings: [
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
        ]),
        .testTarget(name: "InkspringTests", dependencies: ["Inkspring", "InkspringSchedule"])
    ]
)
