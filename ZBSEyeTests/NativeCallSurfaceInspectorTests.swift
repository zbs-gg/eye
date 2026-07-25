import XCTest

final class NativeCallSurfaceInspectorTests: XCTestCase {
    func testHardMarkerQualifiesOneNativeWindow() {
        let result = NativeCallSurfaceInspector.inspect(
            snapshots: [
                .init(nodes: [.init(role: "AXStaticText", value: "Settings")]),
                .init(nodes: [
                    .init(role: "AXStaticText", value: "Participant"),
                    .init(
                        role: "AXButton",
                        title: "Hang up",
                        isEnabled: true,
                        supportsPressAction: true
                    ),
                ]),
            ]
        )

        XCTAssertTrue(result.hasCallSignature)
        XCTAssertFalse(result.authoritativeNoMatch)
    }

    func testSoftMarkersDoNotCombineAcrossWindows() {
        let result = NativeCallSurfaceInspector.inspect(
            snapshots: [
                .init(nodes: [.init(role: "AXButton", title: "Mute")]),
                .init(nodes: [.init(role: "AXButton", title: "Camera")]),
            ]
        )

        XCTAssertFalse(result.hasCallSignature)
        XCTAssertTrue(result.authoritativeNoMatch)
    }

    func testSoftControlsInsideSameWindowDoNotQualifyWithoutHardEndControl() {
        let result = NativeCallSurfaceInspector.inspect(
            snapshots: [
                .init(nodes: [
                    .init(role: "AXButton", title: "Mute"),
                    .init(role: "AXButton", title: "Participants"),
                ]),
            ]
        )

        XCTAssertFalse(result.hasCallSignature)
        XCTAssertTrue(result.authoritativeNoMatch)
    }

    func testHiddenFailedLimitedAndUntrustedScansAreNeverAuthoritativeEnds() {
        XCTAssertFalse(
            NativeCallSurfaceInspector.inspect(
                snapshots: [.init(nodes: [], isHidden: true)]
            ).authoritativeNoMatch
        )
        XCTAssertFalse(
            NativeCallSurfaceInspector.inspect(
                snapshots: [.init(nodes: [], isMinimized: true)]
            ).authoritativeNoMatch
        )
        XCTAssertFalse(
            NativeCallSurfaceInspector.inspect(
                snapshots: [.init(nodes: [], traversalSucceeded: false)]
            ).authoritativeNoMatch
        )
        XCTAssertFalse(
            NativeCallSurfaceInspector.inspect(
                snapshots: [.init(nodes: [
                    .init(role: "AXStaticText", value: "a"),
                    .init(role: "AXStaticText", value: "b"),
                ])],
                maximumNodes: 1
            ).authoritativeNoMatch
        )
        XCTAssertFalse(
            NativeCallSurfaceInspector.inspect(
                snapshots: [.init(nodes: [])],
                accessibilityTrusted: false
            ).authoritativeNoMatch
        )
    }

    func testPlainTextValueAndIdentifierNeverQualifyAsHardControls() {
        let result = NativeCallSurfaceInspector.inspect(
            snapshots: [
                .init(nodes: [
                    .init(role: "AXStaticText", title: "Hang up"),
                    .init(
                        role: "AXButton",
                        value: "Hang up",
                        isEnabled: true,
                        supportsPressAction: true
                    ),
                    .init(
                        role: "AXButton",
                        title: "Please hang up now",
                        isEnabled: true,
                        supportsPressAction: true
                    ),
                    .init(
                        role: "AXButton",
                        title: "Unrelated",
                        value: "Leave call",
                        isEnabled: true,
                        supportsPressAction: true
                    ),
                ]),
            ]
        )

        XCTAssertFalse(result.hasCallSignature)
        XCTAssertTrue(result.authoritativeNoMatch)
    }

    func testHardControlMustBeVisibleEnabledPressableButtonOrMenuButton() {
        let invalidControls: [NativeCallSurfaceInspector.NodeSnapshot] = [
            .init(
                role: "AXStaticText",
                title: "Hang up",
                isEnabled: true,
                supportsPressAction: true
            ),
            .init(
                role: "AXButton",
                title: "Hang up",
                isEnabled: false,
                supportsPressAction: true
            ),
            .init(
                role: "AXButton",
                title: "Hang up",
                isEnabled: true,
                isVisible: false,
                supportsPressAction: true
            ),
            .init(
                role: "AXButton",
                title: "Hang up",
                isEnabled: true,
                supportsPressAction: false
            ),
        ]

        for (index, control) in invalidControls.enumerated() {
            let result = NativeCallSurfaceInspector.inspect(
                snapshots: [.init(nodes: [control])]
            )
            XCTAssertFalse(result.hasCallSignature)
            if index == 0 {
                XCTAssertTrue(
                    result.authoritativeNoMatch,
                    "Hard-call words in ordinary text are not control evidence."
                )
            } else {
                XCTAssertFalse(
                    result.authoritativeNoMatch,
                    "A hard-labelled control that is temporarily unavailable cannot prove an end."
                )
            }
        }

        XCTAssertTrue(
            NativeCallSurfaceInspector.inspect(
                snapshots: [
                    .init(nodes: [
                        .init(
                            role: "AXMenuButton",
                            description: "Leave meeting",
                            isEnabled: true,
                            supportsPressAction: true
                        ),
                    ]),
                ]
            ).hasCallSignature
        )
    }

    func testDisconnectIsHardOnlyForVerifiedDiscordAndSlackBundles() {
        let disconnect = NativeCallSurfaceInspector.WindowSnapshot(
            nodes: [
                .init(
                    role: "AXButton",
                    title: "Disconnect",
                    isEnabled: true,
                    supportsPressAction: true
                ),
            ]
        )

        XCTAssertFalse(
            NativeCallSurfaceInspector.inspect(
                snapshots: [disconnect],
                bundleID: "us.zoom.xos"
            ).hasCallSignature
        )
        XCTAssertTrue(
            NativeCallSurfaceInspector.inspect(
                snapshots: [disconnect],
                bundleID: "com.hnc.Discord"
            ).hasCallSignature
        )
        XCTAssertTrue(
            NativeCallSurfaceInspector.inspect(
                snapshots: [disconnect],
                bundleID: "com.tinyspeck.slackmacgap"
            ).hasCallSignature
        )
    }

    func testSurfaceTokensAreOpaqueAndUniqueAcrossRoots() async throws {
        await NativeCallSurfaceInspector.resetSurfaceRegistryForTesting()
        let firstInserted = await NativeCallSurfaceInspector.insertSurfaceForTesting(id: 1)
        let secondInserted = await NativeCallSurfaceInspector.insertSurfaceForTesting(id: 2)
        let first = try XCTUnwrap(firstInserted)
        let second = try XCTUnwrap(secondInserted)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.count, 36)
        XCTAssertFalse(first.lowercased().contains("hang"))
        await NativeCallSurfaceInspector.discardSurface(first)
        await NativeCallSurfaceInspector.discardSurface(second)
        await NativeCallSurfaceInspector.resetSurfaceRegistryForTesting()
    }

    func testLiveEntryPointsConfineTrustProbeToDedicatedAXQueue() async {
        let result = await NativeCallSurfaceInspector.inspect(
            pid: pid_t(2_000_000_000),
            bundleID: "test.invalid"
        )
        let state = await NativeCallSurfaceInspector.revalidateSurface(
            "missing-surface-token"
        )

        XCTAssertFalse(result.hasCallSignature)
        XCTAssertEqual(state, .unknown)
    }
}
