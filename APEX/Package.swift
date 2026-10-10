// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "APEX",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "APEX",
            targets: ["APEX"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/i-schuetz/SwiftCharts.git", .upToNextMajor(from: "0.6.5"))
    ],
    targets: [
        .target(
            name: "APEX",
            dependencies: ["SwiftCharts"]
        ),
        .testTarget(
            name: "APEXTests",
            dependencies: ["APEX"]
        )
    ]
)