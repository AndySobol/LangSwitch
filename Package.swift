// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LangSwitch",
    defaultLocalization: "ru",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "LangSwitch", targets: ["LangSwitch"])
    ],
    targets: [
        // Pure text logic: layouts, language decisions, spelling, trainer maths. No AppKit.
        .target(
            name: "LangSwitchCore",
            resources: [
                .copy("Resources/Frequency"), .copy("Resources/Terms"), .copy("Resources/Rules"),
                .copy("Resources/Trainer"),
            ]
        ),
        // Vendored Hunspell 1.7.6 (MPL 1.1 option), see ThirdParty/Hunspell/README.md.
        .target(
            name: "CHunspell", path: "ThirdParty/Hunspell",
            exclude: [
                "COPYING", "COPYING.LESSER", "COPYING.MPL", "license.myspell", "manifest.json", "README.md",
                "BUILDING.md", "build-static.sh",
                "src/hunspell/hunvisapi.h.in", "src/hunspell/hunversion.h.in",
            ],
            sources: ["src/hunspell"], publicHeadersPath: "include",
            cxxSettings: [.define("HUNSPELL_STATIC"), .define("BUILDING_LIBHUNSPELL")]
        ),
        // Dictionary provider: Hunspell handles + bundled RU/EN dictionaries.
        .target(
            name: "LangSwitchLexicon", dependencies: ["LangSwitchCore", "CHunspell"],
            resources: [.copy("Resources/Hunspell")]
        ),
        .executableTarget(
            name: "LangSwitch",
            dependencies: ["LangSwitchCore", "LangSwitchLexicon"]
        ),
        .testTarget(name: "LangSwitchCoreTests", dependencies: ["LangSwitchCore"]),
        .testTarget(
            name: "LangSwitchLexiconTests", dependencies: ["LangSwitchCore", "LangSwitchLexicon"],
            // Evaluation corpora: typos and colloquial words the engine is measured on, never shipped.
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx14
)
