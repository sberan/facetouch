// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FaceTouch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FaceTouch",
            path: "Sources",
            exclude: ["Info.plist", "FaceTouch.entitlements"]
        )
    ]
)
