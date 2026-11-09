// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DeckhandKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "DeckhandCore", targets: ["DeckhandCore"]),
        .library(name: "DeckhandSSH", targets: ["DeckhandSSH"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(name: "DeckhandCore"),
        .target(
            name: "DeckhandSSH",
            dependencies: [
                "DeckhandCore",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "DeckhandCoreTests", dependencies: ["DeckhandCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "DeckhandSSHTests", dependencies: ["DeckhandSSH", .product(name: "Citadel", package: "Citadel"), .product(name: "Crypto", package: "swift-crypto")]),
    ]
)
