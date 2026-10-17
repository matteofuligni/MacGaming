// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import PackageDescription

let package = Package(
    name: "MacGaming", platforms: [.macOS(.v14)],
    products: [.executable(name: "macgaming", targets: ["MacGamingCLI"]),
               .executable(name: "MacGamingDesktop", targets: ["MacGamingApp"])],
    targets: [.target(name: "MacGamingCore"),
              .executableTarget(name: "MacGamingCLI", dependencies: ["MacGamingCore"]),
              .executableTarget(name: "MacGamingApp", dependencies: ["MacGamingCore"],
                                swiftSettings: [.unsafeFlags(["-parse-as-library"])]),
              .testTarget(name: "MacGamingCoreTests", dependencies: ["MacGamingCore"])],
    swiftLanguageModes: [.v5]
)
