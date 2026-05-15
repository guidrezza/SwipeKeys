// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwipeKeys",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "swipekeys", targets: ["SwipeKeys"])
    ],
    targets: [
        .executableTarget(name: "SwipeKeys")
    ]
)
