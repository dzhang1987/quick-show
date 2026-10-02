// swift-tools-version: 5.7
// Vendor 本地包：从 https://github.com/mgriebling/SwiftMath.git 1.7.3 vendoring 而来。
// 保留 SPM 包结构仅供本地测试包（mttest）路径依赖；App 构建走 project.yml 的静态库 target。
// 相对上游的本地补丁（QuickShow 项目）：
//   1. MTMathAtomFactory: atom(forCharacter:) 放行 CJK 字符（上游对 ASCII 外字符静默丢弃）
//   2. MTTypesetter: addDisplayLine 对 CJK 区间回退系统 CJK 字体（数学字体无 CJK 字形）
//   3. MathBundle: Bundle.module 双路径定位（SPM / xcodebuild 均可用）

import PackageDescription

let package = Package(
    name: "SwiftMath",
    defaultLocalization: "en",
    platforms: [.iOS("11.0"), .macOS("12.0")],
    products: [
        .library(
            name: "SwiftMath",
            targets: ["SwiftMath"]),
    ],
    targets: [
        .target(
            name: "SwiftMath",
            dependencies: [],
            resources: [
                .copy("mathFonts.bundle")
            ]),
    ]
)
