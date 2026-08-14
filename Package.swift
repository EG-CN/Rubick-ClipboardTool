// swift-tools-version:5.9
// 剪贴板工具 · macOS 菜单栏应用（Swift + SwiftUI 原生）
// 用 Xcode 打开本目录（Package.swift）或命令行 swift build / swift run
import PackageDescription

let package = Package(
    name: "ClipboardTool",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClipboardTool",
            path: "Sources/ClipboardTool"
        ),
        .testTarget(
            name: "ClipboardToolTests",
            dependencies: ["ClipboardTool"],
            path: "Tests/ClipboardToolTests"
        )
    ]
)
