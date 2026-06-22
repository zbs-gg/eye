// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZBSEyeVec",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CSqliteVec", targets: ["CSqliteVec"]),
    ],
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
    ]
)
