import XCTest

final class BrowserCallSurfaceInspectorTests: XCTestCase {
    func testClassifiesMeetZoomAndTeamsFromSameWindowHardEvidence() {
        let cases: [(String, String, BrowserCallService)] = [
            ("https://meet.google.com/abc-defg-hij", "Leave call", .googleMeet),
            ("https://us05web.zoom.us/wc/123/join", "End Meeting", .zoom),
            ("https://teams.microsoft.com/v2/", "Hang up", .microsoftTeams),
            ("https://teams.live.com/meet/123", "Положить трубку", .microsoftTeams),
        ]

        for (document, control, expectedService) in cases {
            let result = inspect([
                webDocument(document),
                button(control),
            ])
            XCTAssertTrue(result.isTrustedCall, document)
            XCTAssertEqual(result.service, expectedService, document)
        }
    }

    func testClassifiesChromiumAXURLOnTopLevelWebArea() {
        let result = inspect([
            webURL("https://meet.google.com/abc-defg-hij"),
            button("Leave call"),
        ])

        XCTAssertTrue(result.isTrustedCall)
        XCTAssertEqual(result.service, .googleMeet)
    }

    func testClassifiesZoomWebFromExactInCallWindowWhenEndControlIsUnlabelled() {
        let result = inspect([
            zoomWindow("Zoom Meeting Example"),
            webURL("https://app.zoom.us/wc/12345678901/start?fromPWA=1"),
            .init(
                role: "AXButton",
                inBrowserWebContent: true,
                webContentRootID: 0,
                webContentTreeDepth: 1
            ),
        ])

        XCTAssertTrue(result.isTrustedCall)
        XCTAssertEqual(result.service, .zoom)
        XCTAssertEqual(result.sessionDiscriminator?.count, 64)
    }

    func testClassifiesZoomWebFromChromeWindowProxyWithoutAXWebArea() {
        let route = "https://app.zoom.us/wc/12345678901/start?fromPWA=1"
        let result = inspect([
            zoomWindow("Zoom Meeting Example", document: route),
            zoomWindowProxy(document: route),
            .init(role: "AXButton"),
        ])

        XCTAssertTrue(result.isTrustedCall)
        XCTAssertEqual(result.service, .zoom)
        XCTAssertEqual(result.sessionDiscriminator?.count, 64)
    }

    func testZoomWindowProxyRequiresOneMatchingGroupAndACompleteTraversal() {
        let route = "https://app.zoom.us/wc/12345678901/start"
        let missingProxy = inspect([
            zoomWindow("Zoom Meeting Example", document: route),
        ])
        let mismatchedProxy = inspect([
            zoomWindow("Zoom Meeting Example", document: route),
            zoomWindowProxy(document: "https://app.zoom.us/wc/10987654321/start"),
        ])
        let duplicateProxy = inspect([
            zoomWindow("Zoom Meeting Example", document: route),
            zoomWindowProxy(document: route),
            zoomWindowProxy(document: route),
        ])
        let failedTraversal = BrowserCallSurfaceInspector.inspect(snapshots: [
            .init(
                nodes: [
                    zoomWindow("Zoom Meeting Example", document: route),
                    zoomWindowProxy(document: route),
                ],
                traversalSucceeded: false
            ),
        ])

        XCTAssertFalse(missingProxy.isTrustedCall)
        XCTAssertFalse(mismatchedProxy.isTrustedCall)
        XCTAssertFalse(duplicateProxy.isTrustedCall)
        XCTAssertFalse(failedTraversal.isTrustedCall)
    }

    func testZoomWindowProxyRejectsLookalikesAndNestedOrToolbarGroups() {
        let route = "https://app.zoom.us/wc/12345678901/start"
        let falsePositiveWindows: [[BrowserCallSurfaceInspector.NodeSnapshot]] = [
            [
                zoomWindow("My Zoom Meeting notes", document: route),
                zoomWindowProxy(document: route),
            ],
            [
                zoomWindow(
                    "Zoom Meeting Example",
                    document: "https://app.zoom.us.evil.example/wc/12345678901/start"
                ),
                zoomWindowProxy(document: route),
            ],
            [
                zoomWindow("Zoom Meeting Example", document: route),
                zoomWindowProxy(document: route, inBrowserChrome: true),
            ],
            [
                zoomWindow("Zoom Meeting Example", document: route),
                zoomWindowProxy(document: route, inBrowserWebContent: true),
            ],
        ]

        for (index, nodes) in falsePositiveWindows.enumerated() {
            XCTAssertFalse(inspect(nodes).isTrustedCall, "proxy false-positive fixture \(index)")
        }
    }

    func testZoomWindowFallbackRejectsPrejoinLookalikeAndLooseTitles() {
        let falsePositiveWindows: [[BrowserCallSurfaceInspector.NodeSnapshot]] = [
            [
                zoomWindow("Zoom Meeting Example"),
                webURL("https://app.zoom.us/wc/12345678901/join"),
            ],
            [
                zoomWindow("Zoom Meeting Example"),
                webURL("https://app.zoom.us/wc/not-a-session/start"),
            ],
            [
                zoomWindow("Zoom Meeting Example"),
                webURL("https://app.zoom.us.evil.example/wc/12345678901/start"),
            ],
            [
                zoomWindow("My Zoom Meeting notes"),
                webURL("https://app.zoom.us/wc/12345678901/start"),
            ],
            [
                webURL("https://app.zoom.us/wc/12345678901/start"),
                .init(
                    role: "AXWindow",
                    title: "Zoom Meeting Example",
                    inBrowserWebContent: true,
                    webContentRootID: 0,
                    webContentTreeDepth: 1
                ),
            ],
            [
                zoomWindow("Zoom Meeting Example"),
                webURL("https://app.zoom.us/wc/12345678901/start"),
                webURL("https://evil.example/not-a-call", rootID: 1),
            ],
        ]

        for (index, nodes) in falsePositiveWindows.enumerated() {
            XCTAssertFalse(inspect(nodes).isTrustedCall, "false-positive fixture \(index)")
        }
    }

    func testZoomWindowFallbackRequiresRootWindowAsFirstTraversedNode() {
        let result = inspect([
            .init(role: "AXGroup", title: "Browser root"),
            zoomWindow("Zoom Meeting Example"),
            webURL("https://app.zoom.us/wc/12345678901/start"),
        ])

        XCTAssertFalse(result.isTrustedCall)
    }

    func testAXURLCannotSupplyOriginOutsideTopLevelWebArea() {
        let nestedWebArea = inspect([
            webURL("https://meet.google.com/abc-defg-hij", depth: 2),
            button("Leave call"),
        ])
        let linkURL = inspect([
            .init(
                role: "AXLink",
                url: "https://meet.google.com/abc-defg-hij",
                inBrowserWebContent: true,
                webContentRootID: 0,
                webContentTreeDepth: 0
            ),
            button("Leave call"),
        ])

        XCTAssertFalse(nestedWebArea.isTrustedCall)
        XCTAssertFalse(linkURL.isTrustedCall)
    }

    func testTeamsAcceptsHardIdentifierWithoutDependingOnLocalizedLabel() {
        let result = inspect([
            webDocument("https://teams.microsoft.com/v2/"),
            .init(
                role: "AXButton",
                identifier: "hangup-button",
                title: "Localized label",
                inBrowserWebContent: true,
                webContentRootID: 0,
                webContentTreeDepth: 1
            ),
        ])

        XCTAssertEqual(result.service, .microsoftTeams)
    }

    func testSessionDiscriminatorIsOpaqueStableAcrossQueryAndFragment() {
        let first = inspect([
            webDocument("https://meet.google.com/abc-defg-hij?authuser=1#chat"),
            button("Leave call"),
        ])
        let second = inspect([
            webDocument("https://MEET.GOOGLE.COM/abc-defg-hij?authuser=2"),
            button("Leave call"),
        ])
        let differentCall = inspect([
            webDocument("https://meet.google.com/other-call"),
            button("Leave call"),
        ])

        XCTAssertEqual(first.sessionDiscriminator, second.sessionDiscriminator)
        XCTAssertNotEqual(first.sessionDiscriminator, differentCall.sessionDiscriminator)
        XCTAssertEqual(first.sessionDiscriminator?.count, 64)
        XCTAssertFalse(first.sessionDiscriminator?.contains("abc-defg-hij") ?? true)
        XCTAssertFalse(first.sessionDiscriminator?.contains("meet.google.com") ?? true)
        XCTAssertTrue(first.allowsCrossRootReconciliation)
    }

    func testRetainedDocumentDistinguishesSameCallFromReusedTabSuccessor() throws {
        let admitted = inspect([
            webDocument("https://meet.google.com/abc-defg-hij"),
            button("Leave call"),
        ])
        let discriminator = try XCTUnwrap(admitted.sessionDiscriminator)

        XCTAssertEqual(
            BrowserCallSurfaceInspector.retainedDocumentState(
                rawDocument: "https://meet.google.com/abc-defg-hij?authuser=1#x",
                expectedService: .googleMeet,
                expectedSessionDiscriminator: discriminator
            ),
            .same
        )
        XCTAssertEqual(
            BrowserCallSurfaceInspector.retainedDocumentState(
                rawDocument: "https://meet.google.com/other-call-id",
                expectedService: .googleMeet,
                expectedSessionDiscriminator: discriminator
            ),
            .replaced,
            "A later call in the same Dia/Chromium AXWebArea must not inherit A's rejection."
        )
        XCTAssertEqual(
            BrowserCallSurfaceInspector.retainedDocumentState(
                rawDocument: "https://calendar.google.com/calendar/u/0/r",
                expectedService: .googleMeet,
                expectedSessionDiscriminator: discriminator
            ),
            .replaced
        )
        XCTAssertEqual(
            BrowserCallSurfaceInspector.retainedDocumentState(
                rawDocument: nil,
                expectedService: .googleMeet,
                expectedSessionDiscriminator: discriminator
            ),
            .unknown
        )
    }

    func testRetainedZoomDocumentSurvivesQueryChangesButRejectsAnotherRoute() throws {
        let admitted = inspect([
            zoomWindow("Zoom Meeting Example"),
            webURL("https://app.zoom.us/wc/12345678901/start?fromPWA=1"),
        ])
        let discriminator = try XCTUnwrap(admitted.sessionDiscriminator)

        XCTAssertEqual(
            BrowserCallSurfaceInspector.retainedDocumentState(
                rawDocument: "https://app.zoom.us/wc/12345678901/start?ref=background",
                expectedService: .zoom,
                expectedSessionDiscriminator: discriminator
            ),
            .same
        )
        XCTAssertEqual(
            BrowserCallSurfaceInspector.retainedDocumentState(
                rawDocument: "https://app.zoom.us/wc/10987654321/start",
                expectedService: .zoom,
                expectedSessionDiscriminator: discriminator
            ),
            .replaced
        )
    }

    func testGenericTeamsRouteCannotReconcileAcrossDifferentAXRoots() {
        let generic = inspect([
            webDocument("https://teams.microsoft.com/v2/"),
            button("Hang up"),
        ])
        let sessionBearing = inspect([
            webDocument("https://teams.microsoft.com/l/meetup-join/opaque-session"),
            button("Hang up"),
        ])

        XCTAssertTrue(generic.isTrustedCall)
        XCTAssertFalse(generic.allowsCrossRootReconciliation)
        XCTAssertTrue(sessionBearing.isTrustedCall)
        XCTAssertTrue(sessionBearing.allowsCrossRootReconciliation)
    }

    func testRejectsPrejoinCalendarLookalikeAndQueryEmbeddedOrigins() {
        let falsePositiveWindows: [[BrowserCallSurfaceInspector.NodeSnapshot]] = [
            [
                webDocument("https://meet.google.com/abc-defg-hij"),
                button("Join now"),
            ],
            [
                webDocument("https://calendar.google.com/calendar/u/0/r"),
                button("Leave call"),
            ],
            [
                webDocument("https://meet.google.com.evil.example/abc"),
                button("Leave call"),
            ],
            [
                webDocument("https://evil.example/?next=https://meet.google.com/abc"),
                button("Leave call"),
            ],
        ]

        for nodes in falsePositiveWindows {
            XCTAssertFalse(inspect(nodes).isTrustedCall)
        }
    }

    func testRequiresOriginAndControlInSameWindow() {
        let result = BrowserCallSurfaceInspector.inspect(snapshots: [
            .init(nodes: [webDocument("https://meet.google.com/abc-defg-hij")]),
            .init(nodes: [button("Leave call")]),
        ])

        XCTAssertFalse(result.isTrustedCall)
        XCTAssertEqual(result.diagnostics.windowsVisited, 2)
    }

    func testAddressBarAloneNeverQualifiesAutomaticCall() {
        let rawURL = "https://meet.google.com/abc-defg-hij"
        let genericField = inspect([
            .init(role: "AXTextField", description: "Search", value: rawURL),
            button("Leave call"),
        ])
        XCTAssertFalse(genericField.isTrustedCall)

        let addressBar = inspect([
            .init(
                role: "AXTextField",
                description: "Address and search bar",
                value: rawURL,
                inBrowserChrome: true
            ),
            button("Leave call"),
        ])
        XCTAssertFalse(addressBar.isTrustedCall)
    }

    func testAddressBarFallbackFailsClosedWithMultipleWebContentRoots() {
        let result = inspect([
            .init(
                role: "AXTextField",
                identifier: "omnibox",
                value: "https://meet.google.com/abc-defg-hij",
                inBrowserChrome: true
            ),
            button("Leave call"),
            .init(
                role: "AXGroup",
                title: "Background side panel",
                inBrowserWebContent: true,
                webContentRootID: 1,
                webContentTreeDepth: 0
            ),
        ])

        XCTAssertFalse(result.isTrustedCall)
    }

    func testAddressBarFallbackIsNotAdmittedFromAnIncompleteWindow() {
        let result = BrowserCallSurfaceInspector.inspect(
            snapshots: [
                .init(nodes: [
                    .init(
                        role: "AXTextField",
                        identifier: "omnibox",
                        value: "https://meet.google.com/abc-defg-hij",
                        inBrowserChrome: true
                    ),
                    button("Leave call"),
                    .init(
                        role: "AXGroup",
                        title: "Unvisited second root",
                        inBrowserWebContent: true,
                        webContentRootID: 1,
                        webContentTreeDepth: 0
                    ),
                ]),
            ],
            limits: .init(
                maximumWindows: 16,
                maximumNodes: 2,
                deadlineSeconds: 1,
                messagingTimeoutSeconds: 0.05
            )
        )

        XCTAssertFalse(result.isTrustedCall)
        XCTAssertTrue(result.diagnostics.hitNodeLimit)
    }

    func testAddressBarFallbackFailsClosedAfterAXTraversalError() {
        let result = BrowserCallSurfaceInspector.inspect(
            snapshots: [
                .init(
                    nodes: [
                        .init(
                            role: "AXTextField",
                            identifier: "omnibox",
                            value: "https://meet.google.com/abc-defg-hij",
                            inBrowserChrome: true
                        ),
                        button("Leave call"),
                    ],
                    traversalSucceeded: false
                ),
            ]
        )

        XCTAssertFalse(result.isTrustedCall)
    }

    func testUntrustedDocumentVetoesSpoofedBrowserChromeAddressBar() {
        let result = inspect([
            webDocument("https://evil.example/not-a-call"),
            .init(
                role: "AXTextField",
                identifier: "omnibox",
                value: "https://meet.google.com/abc-defg-hij",
                inBrowserChrome: true
            ),
            button("Leave call"),
        ])

        XCTAssertFalse(result.isTrustedCall)
    }

    func testTrustedIframeCannotOverrideEvilTopDocument() {
        let result = inspect([
            webDocument("https://evil.example/not-a-call", depth: 0),
            webDocument("https://meet.google.com/abc-defg-hij", depth: 4),
            button("Leave call"),
        ])

        XCTAssertFalse(result.isTrustedCall)
    }

    func testTrustedIframeAloneCannotSupplyOriginToRootLevelControl() {
        let result = inspect([
            webDocument("https://meet.google.com/abc-defg-hij", depth: 4),
            button("Leave call"),
        ])

        XCTAssertFalse(result.isTrustedCall)
    }

    func testOriginAndControlMustShareTopLevelWebContentRoot() {
        let result = inspect([
            webDocument("https://meet.google.com/abc-defg-hij", rootID: 0),
            .init(
                role: "AXButton",
                title: "Leave call",
                inBrowserWebContent: true,
                webContentRootID: 1,
                webContentTreeDepth: 1
            ),
        ])

        XCTAssertFalse(result.isTrustedCall)
    }

    func testExcludedRejectedRootDoesNotHideAnotherCallInSameBrowserWindow() {
        let result = BrowserCallSurfaceInspector.inspect(
            snapshots: [
                .init(nodes: [
                    webDocument("https://meet.google.com/rejected-a", rootID: 0),
                    button("Leave call", rootID: 0),
                    webDocument("https://teams.microsoft.com/v2/", rootID: 1),
                    button("Hang up", rootID: 1),
                ]),
            ],
            excludingRootIDsByWindow: [0: [0]]
        )

        XCTAssertTrue(result.isTrustedCall)
        XCTAssertEqual(result.service, .microsoftTeams)
    }

    func testPageOwnedFakeAddressBarCannotSupplyOrigin() {
        let result = inspect([
            .init(
                role: "AXTextField",
                identifier: "omnibox",
                description: "Address and search bar",
                value: "https://meet.google.com/abc-defg-hij",
                inBrowserWebContent: true
            ),
            button("Leave call"),
        ])

        XCTAssertFalse(result.isTrustedCall)
    }

    func testCallControlMustBeVisibleEnabledAndPressable() {
        let document = webDocument("https://meet.google.com/abc-defg-hij")
        let invalidControls: [BrowserCallSurfaceInspector.NodeSnapshot] = [
            .init(
                role: "AXButton",
                title: "Leave call",
                inBrowserWebContent: true,
                webContentRootID: 0,
                webContentTreeDepth: 1,
                isEnabled: false
            ),
            .init(
                role: "AXButton",
                title: "Leave call",
                inBrowserWebContent: true,
                webContentRootID: 0,
                webContentTreeDepth: 1,
                isVisible: false
            ),
            .init(
                role: "AXButton",
                title: "Leave call",
                inBrowserWebContent: true,
                webContentRootID: 0,
                webContentTreeDepth: 1,
                supportsPressAction: false
            ),
            .init(
                role: "AXButton",
                title: "Leave call",
                inBrowserChrome: true
            ),
        ]

        for control in invalidControls {
            XCTAssertFalse(inspect([document, control]).isTrustedCall)
        }
    }

    func testWindowBudgetDoesNotInspectSeventeenthWindow() {
        var windows = Array(
            repeating: BrowserCallSurfaceInspector.WindowSnapshot(nodes: [.init(title: "decoy")]),
            count: 16
        )
        windows.append(.init(nodes: [
            webDocument("https://meet.google.com/abc-defg-hij"),
            button("Leave call"),
        ]))

        let result = BrowserCallSurfaceInspector.inspect(snapshots: windows)

        XCTAssertFalse(result.isTrustedCall)
        XCTAssertEqual(result.diagnostics.windowsVisited, 16)
        XCTAssertTrue(result.diagnostics.hitWindowLimit)
    }

    func testNodeBudgetStopsBeforeFiveHundredAndFirstNode() {
        var nodes = Array(
            repeating: BrowserCallSurfaceInspector.NodeSnapshot(title: "decoy"),
            count: 500
        )
        nodes.append(webDocument("https://meet.google.com/abc-defg-hij"))
        nodes.append(button("Leave call"))

        let result = BrowserCallSurfaceInspector.inspect(snapshots: [.init(nodes: nodes)])

        XCTAssertFalse(result.isTrustedCall)
        XCTAssertEqual(result.diagnostics.nodesVisited, 500)
        XCTAssertTrue(result.diagnostics.hitNodeLimit)
    }

    func testLargeFirstWindowCannotStarveSecondWindow() {
        let decoys = Array(
            repeating: BrowserCallSurfaceInspector.NodeSnapshot(title: "decoy"),
            count: 500
        )
        let result = BrowserCallSurfaceInspector.inspect(snapshots: [
            .init(nodes: decoys),
            .init(nodes: [
                webDocument("https://meet.google.com/abc-defg-hij"),
                button("Leave call"),
            ]),
        ])

        XCTAssertTrue(result.isTrustedCall)
        XCTAssertEqual(result.service, .googleMeet)
        XCTAssertLessThan(result.diagnostics.nodesVisited, 10)
    }

    func testDeadlineIsGlobalAcrossWindowsAndNodes() {
        var tick: UInt64 = 0
        let result = BrowserCallSurfaceInspector.inspect(
            snapshots: [
                .init(nodes: Array(
                    repeating: .init(title: "decoy"),
                    count: 20
                )),
                .init(nodes: [
                    webDocument("https://meet.google.com/abc-defg-hij"),
                    button("Leave call"),
                ]),
            ],
            limits: .init(
                maximumWindows: 16,
                maximumNodes: 500,
                deadlineSeconds: 0.000_000_003,
                messagingTimeoutSeconds: 0.05
            ),
            clock: {
                defer { tick += 1 }
                return tick
            }
        )

        XCTAssertFalse(result.isTrustedCall)
        XCTAssertTrue(result.diagnostics.timedOut)
        XCTAssertLessThan(result.diagnostics.nodesVisited, 20)
    }

    func testPositiveMatchCrossingDeadlineIsRejected() {
        var tick: UInt64 = 0
        let result = BrowserCallSurfaceInspector.inspect(
            snapshots: [
                .init(nodes: [
                    webDocument("https://meet.google.com/abc-defg-hij"),
                    button("Leave call"),
                ]),
            ],
            limits: .init(
                maximumWindows: 16,
                maximumNodes: 500,
                deadlineSeconds: 0.000_000_003,
                messagingTimeoutSeconds: 0.05
            ),
            clock: {
                defer { tick += 1 }
                return tick
            }
        )

        XCTAssertFalse(result.isTrustedCall)
        XCTAssertTrue(result.diagnostics.timedOut)
    }

    func testUntrustedAccessibilityReturnsNoEvidenceWithoutTraversal() {
        let result = BrowserCallSurfaceInspector.inspect(
            snapshots: [
                .init(nodes: [
                    webDocument("https://meet.google.com/abc-defg-hij"),
                    button("Leave call"),
                ]),
            ],
            accessibilityTrusted: false
        )

        XCTAssertFalse(result.isTrustedCall)
        XCTAssertFalse(result.diagnostics.accessibilityTrusted)
        XCTAssertEqual(result.diagnostics.nodesVisited, 0)
    }

    func testLiveEntryPointsConfineTrustProbeToDedicatedAXQueue() async {
        let result = await BrowserCallSurfaceInspector.inspect(
            pid: pid_t(2_000_000_000)
        )
        let state = await BrowserCallSurfaceInspector.revalidateControl(
            "missing-control-token",
            allowRootRebind: true
        )

        XCTAssertFalse(result.isTrustedCall)
        XCTAssertEqual(state, .unknown)
    }

    func testPinnedControlHandlesCannotBeEvictedUnderRegistryPressure() async throws {
        await BrowserCallSurfaceInspector.resetControlRegistryForTesting()

        var pinnedTokens: [String] = []
        for id in 0..<16 {
            let inserted = await BrowserCallSurfaceInspector.insertControlForTesting(
                id: id,
                pinned: true
            )
            pinnedTokens.append(
                try XCTUnwrap(inserted)
            )
        }

        let overflow = await BrowserCallSurfaceInspector.insertControlForTesting(
            id: 16,
            pinned: false
        )
        XCTAssertNil(overflow)
        let count = await BrowserCallSurfaceInspector.controlRegistryCountForTesting()
        XCTAssertEqual(count, 16)
        for token in pinnedTokens {
            let contains = await BrowserCallSurfaceInspector
                .controlRegistryContainsForTesting(token)
            XCTAssertTrue(contains)
        }
        await BrowserCallSurfaceInspector.resetControlRegistryForTesting()
    }

    func testControlTokensAreUniqueOwnershipLeasesForSameAXRoot() async throws {
        await BrowserCallSurfaceInspector.resetControlRegistryForTesting()

        let firstInserted = await BrowserCallSurfaceInspector.insertControlForTesting(
            id: 42,
            pinned: true
        )
        let first = try XCTUnwrap(firstInserted)
        let replacementInserted = await BrowserCallSurfaceInspector.insertControlForTesting(
            id: 42,
            pinned: true
        )
        let replacement = try XCTUnwrap(replacementInserted)

        XCTAssertNotEqual(first, replacement)
        await BrowserCallSurfaceInspector.discardControl(first)
        let replacementSurvived = await BrowserCallSurfaceInspector
            .controlRegistryContainsForTesting(replacement)
        XCTAssertTrue(
            replacementSurvived,
            "A stale teardown lease must not delete a later adoption of the same AX element."
        )
        await BrowserCallSurfaceInspector.resetControlRegistryForTesting()
    }

    private func inspect(
        _ nodes: [BrowserCallSurfaceInspector.NodeSnapshot]
    ) -> BrowserCallSurfaceInspection {
        BrowserCallSurfaceInspector.inspect(snapshots: [.init(nodes: nodes)])
    }

    private func button(
        _ title: String,
        rootID: Int = 0
    ) -> BrowserCallSurfaceInspector.NodeSnapshot {
        .init(
            role: "AXButton",
            title: title,
            inBrowserWebContent: true,
            webContentRootID: rootID,
            webContentTreeDepth: 1
        )
    }

    private func webDocument(
        _ value: String,
        rootID: Int = 0,
        depth: Int = 0
    ) -> BrowserCallSurfaceInspector.NodeSnapshot {
        .init(
            role: "AXWebArea",
            document: value,
            inBrowserWebContent: true,
            webContentRootID: rootID,
            webContentTreeDepth: depth
        )
    }

    private func webURL(
        _ value: String,
        rootID: Int = 0,
        depth: Int = 0
    ) -> BrowserCallSurfaceInspector.NodeSnapshot {
        .init(
            role: "AXWebArea",
            url: value,
            inBrowserWebContent: true,
            webContentRootID: rootID,
            webContentTreeDepth: depth
        )
    }

    private func zoomWindow(
        _ title: String,
        document: String? = nil
    ) -> BrowserCallSurfaceInspector.NodeSnapshot {
        .init(role: "AXWindow", title: title, document: document)
    }

    private func zoomWindowProxy(
        document: String,
        inBrowserChrome: Bool = false,
        inBrowserWebContent: Bool = false
    ) -> BrowserCallSurfaceInspector.NodeSnapshot {
        .init(
            role: "AXGroup",
            document: document,
            inBrowserChrome: inBrowserChrome,
            inBrowserWebContent: inBrowserWebContent
        )
    }
}
