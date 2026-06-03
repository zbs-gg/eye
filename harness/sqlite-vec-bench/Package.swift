// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VecBench",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CSqliteVec",
            cSettings: [
                .define("SQLITE_CORE"),
                .define("SQLITE_VEC_STATIC"),
                .unsafeFlags(["-O2"]),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "VecBench",
            dependencies: ["CSqliteVec"]
        ),
    ]
)
