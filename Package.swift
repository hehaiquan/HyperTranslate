// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HyperTranslate",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "HyperTranslate", targets: ["HyperTranslate"])],
    targets: [
        .target(name: "HyperTranslateCore", resources: [.copy("Resources/Dictionary.sqlite")]),
        .executableTarget(name: "HyperTranslate", dependencies: ["HyperTranslateCore"]),
        .testTarget(name: "HyperTranslateCoreTests", dependencies: ["HyperTranslateCore"]),
        .testTarget(name: "HyperTranslateAppTests", dependencies: ["HyperTranslate"])
    ],
    swiftLanguageModes: [.v5]
)
