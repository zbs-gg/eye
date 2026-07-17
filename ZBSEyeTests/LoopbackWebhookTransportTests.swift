import CryptoKit
import Foundation
import Security
import XCTest

final class LoopbackWebhookTransportTests: XCTestCase {
    func testEndpointCanonicalizationAcceptsLocalhostAndRejectsEveryOtherRoute() throws {
        XCTAssertEqual(
            try CallAutomationEndpoint.canonicalURL(from: "http://localhost:8765/hooks/call")
                .absoluteString,
            "http://127.0.0.1:8765/hooks/call"
        )
        XCTAssertEqual(
            try CallAutomationEndpoint.canonicalURL(
                from: "http://127.0.0.1:65535/"
            ).absoluteString,
            "http://127.0.0.1:65535/"
        )

        for invalid in [
            "https://127.0.0.1:8765/hook",
            "http://127.0.0.2:8765/hook",
            "http://[::1]:8765/hook",
            "http://example.com:8765/hook",
            "http://user:pass@127.0.0.1:8765/hook",
            "http://127.0.0.1/hook",
            "http://127.0.0.1:80/hook",
            "http://127.0.0.1:8765/hook?secret=yes",
            "http://127.0.0.1:8765/hook#fragment",
            "http://127.0.0.1:8765/%2e%2e/private",
        ] {
            XCTAssertThrowsError(
                try CallAutomationEndpoint.canonicalURL(from: invalid),
                "accepted \(invalid)"
            )
        }
    }

    func testDeliveryBuildsSignedBoundedCredentialFreeRequest() async throws {
        let http = CapturingWebhookHTTPTransport(
            result: .success(
                ProviderHTTPTransportResponse(statusCode: 204, headers: [:], body: Data())
            )
        )
        let transport = LoopbackWebhookTransport(
            http: http,
            secrets: StaticCallAutomationSecretProvider(value: "test-secret"),
            nowSeconds: { 1_700_000_000 }
        )

        let result = await transport.deliver(Self.delivery(endpointHost: "localhost"))

        XCTAssertEqual(result, .delivered(statusCode: 204))
        let capturedRequest = await http.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url.absoluteString, "http://127.0.0.1:8765/hooks/call")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/cloudevents+json")
        XCTAssertEqual(request.headers["X-ZBS-Eye-Event-ID"], Self.eventID)
        XCTAssertEqual(request.headers["X-ZBS-Eye-Delivery-Timestamp"], "1700000000")
        XCTAssertNotNil(request.headers["X-ZBS-Eye-Signature"])
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertNil(request.headers["Cookie"])
        XCTAssertEqual(request.timeout, .seconds(5))
        XCTAssertEqual(request.maximumResponseBytes, 16 * 1_024)
        XCTAssertEqual(request.maximumErrorBytes, 16 * 1_024)
        let body = try XCTUnwrap(request.body)
        XCTAssertLessThanOrEqual(body.count, 64 * 1_024)
        XCTAssertEqual(
            request.headers["X-ZBS-Eye-Signature"],
            Self.expectedSignature(
                secret: "test-secret",
                timestampSeconds: 1_700_000_000,
                body: body
            )
        )
    }

    func testProductionSessionConfigurationHasNoAmbientState() {
        let configuration = URLSessionProviderHTTPTransport.makeConfiguration()

        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.waitsForConnectivity)

        let loopback = URLSessionProviderHTTPTransport.makeConfiguration(
            disablesSystemProxy: true
        )
        XCTAssertEqual(loopback.connectionProxyDictionary as? NSDictionary, [:] as NSDictionary)
    }

    func testStatusAndTransportFailuresClassifyDeliveredRetryOrBlocked() async {
        let cases: [(Result<ProviderHTTPTransportResponse, Error>, CallAutomationDeliveryResult)] = [
            (.success(.init(statusCode: 200, headers: [:], body: Data())), .delivered(statusCode: 200)),
            (.success(.init(statusCode: 408, headers: [:], body: Data())), .retry(afterMs: nil, errorCode: "http_408")),
            (.success(.init(statusCode: 425, headers: [:], body: Data())), .retry(afterMs: nil, errorCode: "http_425")),
            (.success(.init(statusCode: 429, headers: ["Retry-After": "999"], body: Data())), .retry(afterMs: 300_000, errorCode: "http_429")),
            (.success(.init(statusCode: 503, headers: ["retry-after": "12"], body: Data())), .retry(afterMs: 12_000, errorCode: "http_503")),
            (.success(.init(statusCode: 400, headers: [:], body: Data())), .blocked(statusCode: 400, errorCode: "http_400")),
            (.failure(ProviderHTTPTransportError.timedOut), .retry(afterMs: nil, errorCode: "timed_out")),
            (.failure(ProviderHTTPTransportError.networkFailure), .retry(afterMs: nil, errorCode: "network_failure")),
            (.failure(ProviderHTTPTransportError.redirectRejected), .blocked(statusCode: nil, errorCode: "redirect_rejected")),
            (.failure(ProviderHTTPTransportError.responseTooLarge), .blocked(statusCode: nil, errorCode: "response_too_large")),
        ]

        for (httpResult, expected) in cases {
            let http = CapturingWebhookHTTPTransport(result: httpResult)
            let transport = LoopbackWebhookTransport(
                http: http,
                secrets: StaticCallAutomationSecretProvider(value: "test-secret"),
                nowSeconds: { 1_700_000_000 }
            )
            let actual = await transport.deliver(Self.delivery())
            XCTAssertEqual(actual, expected)
        }
    }

    func testInvalidEndpointOrKeychainFailureSendsNothing() async {
        let invalidHTTP = CapturingWebhookHTTPTransport(
            result: .success(.init(statusCode: 204, headers: [:], body: Data()))
        )
        let invalidTransport = LoopbackWebhookTransport(
            http: invalidHTTP,
            secrets: StaticCallAutomationSecretProvider(value: "test-secret"),
            nowSeconds: { 1_700_000_000 }
        )
        let invalidResult = await invalidTransport.deliver(
            Self.delivery(endpointHost: "example.com")
        )
        XCTAssertEqual(
            invalidResult,
            .blocked(statusCode: nil, errorCode: "invalid_endpoint")
        )
        let invalidRequest = await invalidHTTP.lastRequest()
        XCTAssertNil(invalidRequest)

        let failedHTTP = CapturingWebhookHTTPTransport(
            result: .success(.init(statusCode: 204, headers: [:], body: Data()))
        )
        let failedTransport = LoopbackWebhookTransport(
            http: failedHTTP,
            secrets: FailingCallAutomationSecretProvider(),
            nowSeconds: { 1_700_000_000 }
        )
        let failedResult = await failedTransport.deliver(Self.delivery())
        XCTAssertEqual(
            failedResult,
            .blocked(statusCode: nil, errorCode: "signing_secret_unavailable")
        )
        let failedRequest = await failedHTTP.lastRequest()
        XCTAssertNil(failedRequest)
    }

    func testKeychainReadErrorsFailInsteadOfCreatingReplacementSecret() {
        XCTAssertEqual(
            KeychainStore.secretReadAction(status: errSecItemNotFound, data: nil),
            .create
        )
        XCTAssertEqual(
            KeychainStore.secretReadAction(
                status: errSecSuccess,
                data: Data("stable-secret".utf8)
            ),
            .use("stable-secret")
        )
        XCTAssertEqual(
            KeychainStore.secretReadAction(status: errSecInteractionNotAllowed, data: nil),
            .fail
        )
        XCTAssertEqual(
            KeychainStore.secretReadAction(status: errSecSuccess, data: Data([0xFF])),
            .fail
        )
    }

    private static let eventID = "018f0000-0000-7000-8000-000000000003"

    private static func expectedSignature(
        secret: String,
        timestampSeconds: Int64,
        body: Data
    ) -> String {
        var message = Data("\(timestampSeconds).".utf8)
        message.append(body)
        let code = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: Data(secret.utf8))
        )
        return "sha256=" + code.map { String(format: "%02x", $0) }.joined()
    }

    private static func delivery(endpointHost: String = "127.0.0.1") -> CallAutomationDelivery {
        CallAutomationDelivery(
            event: CallAutomationOutboxRow(
                sequence: 1,
                eventID: eventID,
                semanticIdentity: "call-ended:42:0",
                callId: 42,
                eventType: .callEnded,
                occurredAtMs: 1_700_000_000_000,
                endpointFingerprint: "receiver-a",
                payloadJSON: #"{"degraded":false,"interrupted":false,"state":"finalizing"}"#,
                state: .sending,
                attempts: 1,
                nextAttemptAtMs: 1_700_000_000_000,
                leaseExpiresAtMs: 1_700_000_030_000,
                httpStatus: nil,
                lastErrorCode: nil,
                deliveredAtMs: nil,
                createdAtMs: 1_700_000_000_000,
                updatedAtMs: 1_700_000_000_000
            ),
            endpoint: URL(string: "http://\(endpointHost):8765/hooks/call")!
        )
    }
}

private struct StaticCallAutomationSecretProvider: CallAutomationSecretProviding {
    let value: String

    func signingSecret() throws -> String { value }
}

private struct FailingCallAutomationSecretProvider: CallAutomationSecretProviding {
    func signingSecret() throws -> String { throw FixtureError.failed }
}

private actor CapturingWebhookHTTPTransport: ProviderHTTPTransport {
    private let result: Result<ProviderHTTPTransportResponse, Error>
    private var request: ProviderHTTPTransportRequest?

    init(result: Result<ProviderHTTPTransportResponse, Error>) {
        self.result = result
    }

    func send(_ request: ProviderHTTPTransportRequest) async throws -> ProviderHTTPTransportResponse {
        self.request = request
        return try result.get()
    }

    func lastRequest() -> ProviderHTTPTransportRequest? { request }
}

private enum FixtureError: Error {
    case failed
}
