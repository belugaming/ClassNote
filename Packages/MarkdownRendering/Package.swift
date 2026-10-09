// swift-tools-version: 6.1

import PackageDescription

// MarkdownView compiles its LaTeX support, and links SwiftMath, only when its
// `LaTeX` trait is on. The trait is on by default, but an Xcode project does
// not pass package traits before Xcode 26.4, so the app depended on it
// directly got neither and showed every formula as raw `$$…$$` source. Asking
// for the trait here, in a package manifest, turns it on whatever the Xcode.
let package = Package(
    name: "MarkdownRendering",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarkdownRendering", targets: ["MarkdownRendering"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/LiYanan2004/MarkdownView",
            from: "3.0.0",
            traits: ["LaTeX"]
        ),
    ],
    targets: [
        .target(
            name: "MarkdownRendering",
            dependencies: [
                .product(name: "MarkdownView", package: "MarkdownView"),
            ]
        ),
    ]
)
