// swift-tools-version: 6.2

import PackageDescription

// LiYanan2004/MarkdownView 3.0.0, kept here so its formula rendering can be
// changed; see PATCHES.md. Everything else is upstream as released.
let package = Package(
    name: "MarkdownView",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "MarkdownView", targets: ["MarkdownView"]),
    ],
    traits: [
        "LaTeX",
        .default(enabledTraits: ["LaTeX"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.3.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.3"),
        .package(url: "https://github.com/LiYanan2004/RichText.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MarkdownView",
            dependencies: [
                .product(
                    name: "Markdown",
                    package: "swift-markdown"
                ),
                .product(
                    name: "Highlightr",
                    package: "Highlightr",
                    condition: .when(platforms: [.iOS, .macOS])
                ),
                .product(
                    name: "SwiftMath",
                    package: "SwiftMath",
                    condition: .when(platforms: [.iOS, .macOS], traits: ["LaTeX"])
                ),
                .product(
                    name: "RichText",
                    package: "RichText",
                    condition: .when(platforms: [.iOS, .macOS])
                ),
            ],
            swiftSettings: [
                .define(
                    "ENABLE_MATH_RENDERING",
                    .when(platforms: [.iOS, .macOS], traits: ["LaTeX"])
                ),
            ]
        ),
    ]
)
