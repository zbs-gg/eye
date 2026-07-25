import XCTest

final class BrowserCallAdmissionIntegrationTests: XCTestCase {
    private struct ServiceFixture {
        let name: String
        let url: String
        let control: BrowserCallSurfaceInspector.NodeSnapshot
        let expected: BrowserCallService
    }

    func testChromeDiaEdgeCrossMeetZoomTeamsThroughGroupingAXAndPolicy() throws {
        let browsers = [
            "com.google.Chrome",
            "company.thebrowser.dia",
            "com.microsoft.edgemac",
        ]
        let services = [
            ServiceFixture(
                name: "Meet",
                url: "https://meet.google.com/abc-defg-hij",
                control: button(title: "Leave call"),
                expected: .googleMeet
            ),
            ServiceFixture(
                name: "Zoom",
                url: "https://us05web.zoom.us/wc/123456789/join",
                control: button(title: "End Meeting"),
                expected: .zoom
            ),
            ServiceFixture(
                name: "Teams",
                url: "https://teams.microsoft.com/l/meetup-join/opaque-session",
                control: button(identifier: "hangup-button", title: "Localized"),
                expected: .microsoftTeams
            ),
        ]

        for (browserIndex, bundleID) in browsers.enumerated() {
            for (serviceIndex, service) in services.enumerated() {
                let rootPID = Int32(10_000 + browserIndex)
                let helperPID = Int32(20_000 + serviceIndex)
                let identity = try XCTUnwrap(
                    CallAudioOwnerResolution.resolve(
                        ancestors: [
                            .init(
                                pid: helperPID,
                                bundleID: "\(bundleID).helper",
                                executableName: "Chromium Helper"
                            ),
                            .init(pid: rootPID, bundleID: bundleID, executableName: nil),
                        ],
                        currentProcessID: 999
                    )
                )
                let group = try XCTUnwrap(
                    CallAudioProcessGrouping.groups(from: [
                        sample(
                            objectID: 1,
                            pid: helperPID,
                            identity: identity,
                            input: true,
                            output: false
                        ),
                        sample(
                            objectID: 2,
                            pid: helperPID + 100,
                            identity: identity,
                            input: false,
                            output: true
                        ),
                    ]).only
                )
                let inspection = BrowserCallSurfaceInspector.inspect(snapshots: [
                    .init(nodes: [
                        webURL(service.url),
                        service.control,
                    ]),
                ])
                XCTAssertEqual(
                    inspection.service,
                    service.expected,
                    "\(bundleID) × \(service.name)"
                )

                let fingerprint = "\(browserIndex)-\(serviceIndex)"
                let evidence = try XCTUnwrap(
                    BrowserCallAdmission.evidence(
                        group: group,
                        inspection: inspection,
                        observedAt: 10,
                        monotonicNow: 10,
                        fingerprint: fingerprint
                    ),
                    "\(bundleID) × \(service.name)"
                )
                var policy = CallDetectionPolicy()
                XCTAssertEqual(
                    policy.reduce(evidence),
                    .start(fingerprint: fingerprint),
                    "\(bundleID) × \(service.name)"
                )
            }
        }
    }

    func testMeetZoomAndTeamsPrejoinSurfacesAreRejected() throws {
        let prejoin = [
            ("https://meet.google.com/abc-defg-hij", "Join now"),
            ("https://us05web.zoom.us/wc/123456789/join", "Join"),
            ("https://teams.microsoft.com/l/meetup-join/opaque-session", "Join now"),
        ]
        let group = try XCTUnwrap(twoSidedGroup(bundleID: "company.thebrowser.dia"))

        for (url, label) in prejoin {
            let inspection = BrowserCallSurfaceInspector.inspect(snapshots: [
                .init(nodes: [
                    webURL(url),
                    button(title: label),
                ]),
            ])
            XCTAssertFalse(inspection.isTrustedCall, url)
            XCTAssertNil(
                BrowserCallAdmission.evidence(
                    group: group,
                    inspection: inspection,
                    observedAt: 10,
                    monotonicNow: 10,
                    fingerprint: "prejoin"
                ),
                url
            )
        }
    }

    func testDiaAssistantInputPlusPlaybackOutputCannotPromoteTrustedPrejoinOrigin() throws {
        let identity = try XCTUnwrap(
            CallAudioOwnerResolution.resolve(
                ancestors: [
                    .init(
                        pid: 301,
                        bundleID: "company.thebrowser.dia.helper",
                        executableName: "Dia Helper"
                    ),
                    .init(
                        pid: 300,
                        bundleID: "company.thebrowser.dia",
                        executableName: "Dia"
                    ),
                ],
                currentProcessID: 999
            )
        )
        let group = try XCTUnwrap(
            CallAudioProcessGrouping.groups(from: [
                sample(
                    objectID: 11,
                    pid: 301,
                    identity: identity,
                    input: true,
                    output: false
                ),
                sample(
                    objectID: 12,
                    pid: 302,
                    identity: identity,
                    input: false,
                    output: true
                ),
            ]).only
        )
        XCTAssertTrue(group.inputActive)
        XCTAssertTrue(group.outputActive)

        let inspection = BrowserCallSurfaceInspector.inspect(snapshots: [
            .init(nodes: [
                webURL("https://meet.google.com/abc-defg-hij"),
                button(title: "Join now"),
            ]),
        ])
        XCTAssertFalse(inspection.isTrustedCall)
        XCTAssertNil(
            BrowserCallAdmission.evidence(
                group: group,
                inspection: inspection,
                observedAt: 10,
                monotonicNow: 10,
                fingerprint: "assistant-plus-podcast"
            )
        )
    }

    private func twoSidedGroup(bundleID: String) -> CallAudioApplicationGroup? {
        CallAudioProcessGrouping.groups(from: [
            .init(
                audioObjectID: 1,
                pid: 11,
                rootPID: 10,
                ownerBundleID: bundleID,
                ownerKind: .browser,
                inputActive: true,
                outputActive: false
            ),
            .init(
                audioObjectID: 2,
                pid: 12,
                rootPID: 10,
                ownerBundleID: bundleID,
                ownerKind: .browser,
                inputActive: false,
                outputActive: true
            ),
        ]).only
    }

    private func sample(
        objectID: UInt32,
        pid: Int32,
        identity: CallAudioApplicationIdentity,
        input: Bool,
        output: Bool
    ) -> CallAudioProcessSample {
        .init(
            audioObjectID: objectID,
            pid: pid,
            rootPID: identity.rootPID,
            ownerBundleID: identity.bundleID,
            ownerKind: identity.kind,
            inputActive: input,
            outputActive: output
        )
    }

    private func webURL(_ value: String) -> BrowserCallSurfaceInspector.NodeSnapshot {
        .init(
            role: "AXWebArea",
            url: value,
            inBrowserWebContent: true,
            webContentRootID: 0,
            webContentTreeDepth: 0
        )
    }

    private func button(
        identifier: String? = nil,
        title: String
    ) -> BrowserCallSurfaceInspector.NodeSnapshot {
        .init(
            role: "AXButton",
            identifier: identifier,
            title: title,
            inBrowserWebContent: true,
            webContentRootID: 0,
            webContentTreeDepth: 1
        )
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
