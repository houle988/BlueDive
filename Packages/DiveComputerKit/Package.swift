// swift-tools-version:6.2
//
// DiveComputerKit — BlueDive's dive computer transport and parser (replaces LibDCSwift).
// Design: Docs/ARCHITECTURE.md, owner decisions: Docs/DECISIONS.md.
//
// CLibDiveComputer is libdivecomputer (LGPL 2.1), vendored unchanged and linked
// statically, plus a small shim (shim/, include/dc_shim.h). See
// Sources/CLibDiveComputer/UPSTREAM.md for the snapshot and the sync procedure.
import PackageDescription

let package = Package(
    name: "DiveComputerKit",
    // Matches the app's deployment targets (pbxproj: iOS 18.6, macOS 15.6).
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "DiveComputerKit", targets: ["DiveComputerKit"])
    ],
    targets: [
        .target(
            name: "CLibDiveComputer",
            path: "Sources/CLibDiveComputer",
            exclude: [
                // Upstream non-source files, kept so a sync is a plain copy of the tree.
                "COPYING", "NEWS", "README", "configure.ac", "Makefile.am",
                "libdivecomputer.pc.in", "UPSTREAM.md",
                "src/Makefile.am", "src/libdivecomputer.symbols",
                "include/libdivecomputer/Makefile.am", "include/libdivecomputer/version.h.in",
                // Windows only.
                "src/serial_win32.c"
            ],
            sources: ["src", "shim"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .define("ENABLE_LOGGING"),
                .define("HAVE_PTHREAD_H"),
                .define("HAVE_CLOCK_GETTIME"),
                .define("HAVE_LOCALTIME_R"),
                .define("HAVE_GMTIME_R"),
                .define("HAVE_TIMEGM"),
                .define("HAVE_STRUCT_TM_TM_GMTOFF"),
                .define("HAVE_STRERROR_R"),
                .define("HAVE_IOKIT_SERIAL_IOSS_H", .when(platforms: [.macOS])),
                // Upstream code: size_t → unsigned int narrowing (~110 warnings), and its own
                // DEBUG log macro (context-private.h) colliding with the -DDEBUG of debug builds.
                .unsafeFlags(["-Wno-shorten-64-to-32", "-Wno-macro-redefined"])
            ],
            linkerSettings: [.linkedLibrary("m")]
        ),
        .target(
            name: "DiveComputerKit",
            dependencies: ["CLibDiveComputer"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("CoreBluetooth")]
        ),
        .testTarget(
            name: "DiveComputerKitTests",
            dependencies: ["DiveComputerKit", "CLibDiveComputer"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
