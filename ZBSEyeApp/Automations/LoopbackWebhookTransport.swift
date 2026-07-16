import CryptoKit
import Foundation

enum CallAutomationEndpointError: Error, Sendable, Equatable {
    case invalid
}

enum CallAutomationEndpoint {
    static func canonicalURL(from input: String) throws -> URL {
        guard let url = URL(string: input) else { throw CallAutomationEndpointError.invalid }
        return try canonicalURL(url)
    }

    static func canonicalURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1",
              let port = components.port,
              (1_024...65_535).contains(port),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              !components.percentEncodedPath.lowercased().contains("%2e") else {
            throw CallAutomationEndpointError.invalid
        }
        components.scheme = "http"
        components.host = "127.0.0.1"
        guard let canonical = components.url,
              canonical.host == "127.0.0.1" else {
            throw CallAutomationEndpointError.invalid
        }
        return canonical
    }

    static func fingerprint(_ endpoint: URL) throws -> String {
        let url = try canonicalURL(endpoint)
        return SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

protocol CallAutomationSecretProviding: Sendable {
    func signingSecret() throws -> String
}

struct KeychainCallAutomationSecretProvider: CallAutomationSecretProviding {
    func signingSecret() throws -> String {
        try KeychainStore.callAutomationSigningSecret()
    }
}

struct LoopbackWebhookTransport: CallAutomationTransport, Sendable {
    private static let responseLimit = 16 * 1_024
    private static let maximumRetryAfterMs: Int64 = 300_000

    private let http: any ProviderHTTPTransport
    private let secrets: any CallAutomationSecretProviding
    private let nowSeconds: @Sendable () -> Int64

    init(
        http: any ProviderHTTPTransport = URLSessionProviderHTTPTransport(
            disablesSystemProxy: true
        ),
        secrets: any CallAutomationSecretProviding = KeychainCallAutomationSecretProvider(),
        nowSeconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970)
        }
    ) {
        self.http = http
        self.secrets = secrets
        self.nowSeconds = nowSeconds
    }

    func deliver(_ delivery: CallAutomationDelivery) async -> CallAutomationDeliveryResult {
        let endpoint: URL
        do {
            endpoint = try CallAutomationEndpoint.canonicalURL(delivery.endpoint)
        } catch {
            return .blocked(statusCode: nil, errorCode: "invalid_endpoint")
        }

        let body: Data
        do {
            body = try CallAutomationPayload.encode(event: delivery.event)
        } catch {
            return .blocked(statusCode: nil, errorCode: "invalid_payload")
        }

        return await send(body: body, eventID: delivery.event.eventID, endpoint: endpoint)
    }

    func test(
        endpoint: URL,
        eventID: String,
        occurredAtMs: Int64
    ) async -> CallAutomationDeliveryResult {
        let canonicalEndpoint: URL
        do {
            canonicalEndpoint = try CallAutomationEndpoint.canonicalURL(endpoint)
        } catch {
            return .blocked(statusCode: nil, errorCode: "invalid_endpoint")
        }
        let body: Data
        do {
            body = try CallAutomationPayload.encodeTest(
                eventID: eventID,
                occurredAtMs: occurredAtMs
            )
        } catch {
            return .blocked(statusCode: nil, errorCode: "invalid_payload")
        }
        return await send(body: body, eventID: eventID, endpoint: canonicalEndpoint)
    }

    private func send(
        body: Data,
        eventID: String,
        endpoint: URL
    ) async -> CallAutomationDeliveryResult {
        let secret: String
        do {
            secret = try secrets.signingSecret()
            guard !secret.isEmpty else { throw CallAutomationSecretError.unavailable }
        } catch {
            return .blocked(statusCode: nil, errorCode: "signing_secret_unavailable")
        }

        let timestamp = nowSeconds()
        let request = ProviderHTTPTransportRequest(
            url: endpoint,
            method: "POST",
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/cloudevents+json",
                "X-ZBS-Eye-Event-ID": eventID,
                "X-ZBS-Eye-Delivery-Timestamp": String(timestamp),
                "X-ZBS-Eye-Signature": CallAutomationSignature.make(
                    secret: secret,
                    timestampSeconds: timestamp,
                    body: body
                ),
            ],
            body: body,
            timeout: .seconds(5),
            maximumResponseBytes: Self.responseLimit,
            maximumErrorBytes: Self.responseLimit
        )

        do {
            let response = try await http.send(request)
            return Self.classify(
                statusCode: response.statusCode,
                headers: response.headers,
                nowSeconds: timestamp
            )
        } catch let error as ProviderHTTPTransportError {
            switch error {
            case .timedOut:
                return .retry(afterMs: nil, errorCode: "timed_out")
            case .networkFailure, .cancelled:
                return .retry(afterMs: nil, errorCode: "network_failure")
            case .redirectRejected:
                return .blocked(statusCode: nil, errorCode: "redirect_rejected")
            case .responseTooLarge:
                return .blocked(statusCode: nil, errorCode: "response_too_large")
            }
        } catch {
            return .retry(afterMs: nil, errorCode: "network_failure")
        }
    }

    static func classify(
        statusCode: Int,
        headers: [String: String],
        nowSeconds: Int64
    ) -> CallAutomationDeliveryResult {
        if (200...299).contains(statusCode) {
            return .delivered(statusCode: statusCode)
        }
        if statusCode == 408 || statusCode == 425 || statusCode == 429
            || (500...599).contains(statusCode) {
            return .retry(
                afterMs: retryAfterMs(headers: headers, nowSeconds: nowSeconds),
                errorCode: "http_\(statusCode)"
            )
        }
        return .blocked(statusCode: statusCode, errorCode: "http_\(statusCode)")
    }

    private static func retryAfterMs(
        headers: [String: String],
        nowSeconds: Int64
    ) -> Int64? {
        guard let raw = headers.first(where: {
            $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame
        })?.value.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let seconds: Int64?
        if let delta = Int64(raw), delta >= 0 {
            seconds = delta
        } else {
            seconds = httpDateSeconds(raw).map { max(0, $0 - nowSeconds) }
        }
        guard let seconds else { return nil }
        let milliseconds = seconds.multipliedReportingOverflow(by: 1_000)
        return min(milliseconds.overflow ? Int64.max : milliseconds.partialValue, maximumRetryAfterMs)
    }

    private static func httpDateSeconds(_ text: String) -> Int64? {
        for format in [
            "EEE',' dd MMM yyyy HH':'mm':'ss z",
            "EEEE',' dd-MMM-yy HH':'mm':'ss z",
            "EEE MMM d HH':'mm':'ss yyyy",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return Int64(date.timeIntervalSince1970)
            }
        }
        return nil
    }
}

private enum CallAutomationSecretError: Error {
    case unavailable
}
