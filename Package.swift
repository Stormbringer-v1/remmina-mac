// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemminaMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RemminaMac", targets: ["RemminaMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "RemminaMac",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/RemminaMac",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "RemminaMacTests",
            dependencies: ["RemminaMac"],
            path: "Tests/RemminaMacTests"
        )
    ]
)

// App bundle packaging (Info.plist, entitlements, AppIcon.icns) is handled
// by `build_app.sh`. The `swift run` workflow does not require Resources/.
// See build_app.sh and Resources/RemminaMac.entitlements for the bundle
// configuration; see README "Sandbox & External Tools" for the policy.
