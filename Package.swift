// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SouchastnikCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SouchastnikCore", targets: ["SouchastnikCore"]),
        .library(name: "SouchastnikAssets", targets: ["SouchastnikAssets"])
    ],
    targets: [
        .target(name: "SouchastnikCore"),
        .target(name: "SouchastnikAssets", dependencies: ["SouchastnikCore"]),
        .testTarget(name: "SouchastnikCoreTests", dependencies: ["SouchastnikCore"]),
        .testTarget(name: "SouchastnikAssetsTests", dependencies: ["SouchastnikAssets"])
    ]
)
