// swift-tools-version: 5.9
//
// Flutter 3.44+ can integrate iOS plugins through Swift Package Manager.
// CocoaPods builds use ../algorithmx_flutter.podspec and compile the exact
// same Sources tree, so there is only one copy of the native SDK to maintain.

import PackageDescription

let package = Package(
    name: "algorithmx_flutter",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "algorithmx-flutter", targets: ["algorithmx_flutter"])
    ],
    dependencies: [
        // Flutter places this package beside plugin packages while resolving
        // the app. It supplies the `Flutter` module imported by our bridge.
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "algorithmx_flutter",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            // The native SDK's Apple privacy manifest (synced with the sources).
            resources: [.copy("NativeSDK/PrivacyInfo.xcprivacy")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
