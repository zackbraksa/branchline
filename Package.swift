// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Branchline",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Branchline", targets: ["Branchline"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "BranchlineCore"),
        .executableTarget(
            name: "Branchline",
            dependencies: ["BranchlineCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "BranchlineCoreTests", dependencies: ["BranchlineCore"]),
        .testTarget(name: "BranchlineTests", dependencies: ["Branchline", "BranchlineCore"]),
        .testTarget(name: "BranchlineLayoutTests", dependencies: ["Branchline"])
    ]
)
