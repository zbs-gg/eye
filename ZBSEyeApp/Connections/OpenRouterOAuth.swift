import Foundation
import CryptoKit
import Network
import Security
import AppKit

/// "Sign in with OpenRouter" — a real OAuth 2.0 Authorization Code flow with PKCE, no key pasting.
///
/// Flow (verified against OpenRouter's docs):
///  1. PKCE — `code_verifier` = 64 random bytes, base64url (no padding); `code_challenge` =
///     base64url(SHA256(verifier)); method `S256`.
///  2. A TEMPORARY loopback HTTP listener binds 127.0.0.1 on an EPHEMERAL port and waits for the
///     browser to hit `GET /callback?code=…`. OpenRouter supports localhost callbacks (no custom URL
///     schemes), so this stays entirely on-box — nothing but 127.0.0.1 is ever bound.
///  3. The system browser opens `https://openrouter.ai/auth?callback_url=…&code_challenge=…&…`.
///  4. On the code, POST `{code, code_verifier, code_challenge_method}` to
///     `https://openrouter.ai/api/v1/auth/keys` → `{ "key": "sk-or-…" }`.
///
/// Secrets discipline: the verifier, the authorization code and the returned key are NEVER logged.
/// The exchange goes to OpenRouter's pinned host over HTTPS with redirects blocked (a 3xx must never
/// re-send the code to another host). Self-contained + Sendable — the whole thing runs off the main
/// actor; only a Sendable outcome (the key, or a typed error) crosses back.
actor OpenRouterOAuth {

    // MARK: errors

    enum OAuthError: Error, LocalizedError, Equatable {
        case listenerFailed
        case browserOpenFailed
        case timedOut
        case cancelled
        case entropyFailed             // the system RNG failed — refuse rather than use weak entropy
        case providerError(String)     // OpenRouter redirected back with ?error=…
        case exchangeFailed(String)    // non-2xx from /auth/keys
        case invalidResponse
        case noKey

        var errorDescription: String? {
            switch self {
            case .listenerFailed:
                return String(localized: "Couldn't start the local sign-in listener. Try again.")
            case .browserOpenFailed:
                return String(localized: "Couldn't open your browser to sign in.")
            case .timedOut:
                return String(localized: "Sign-in timed out. Try again.")
            case .cancelled:
                return String(localized: "Sign-in cancelled.")
            case .entropyFailed:
                return String(localized: "Couldn't generate secure sign-in credentials. Try again.")
            case .providerError(let m):
                return String(localized: "OpenRouter sign-in failed: \(m)")
            case .exchangeFailed(let m):
                return String(localized: "Couldn't complete sign-in (\(m)).")
            case .invalidResponse:
                return String(localized: "Unexpected response from OpenRouter.")
            case .noKey:
                return String(localized: "OpenRouter didn't return a key.")
            }
        }

        var isCancellation: Bool { self == .cancelled }
    }

    // MARK: entry point

    /// Runs the full flow and returns the `sk-or-…` key, or throws a typed `OAuthError`.
    /// `timeout` is the overall ceiling; the caller can also cancel the enclosing Task at any point
    /// (user closed the browser / clicked Cancel) — either way the listener is always torn down.
    func authorize(timeout: TimeInterval = 180) async throws -> String {
        let verifier = try Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        // CSRF/anti-injection nonce: always SENT on the auth URL, but validated on the callback ONLY when
        // it's echoed back (best-effort — OpenRouter's PKCE flow may omit `state`; PKCE + the loopback bind
        // the exchange regardless). A present-but-wrong nonce is rejected; an absent one is accepted.
        let state = try Self.makeStateNonce()

        let listener = LoopbackListener()
        let port: UInt16
        do {
            port = try await listener.start(expectedState: state)
        } catch {
            await listener.stop()
            throw Self.mapped(error)
        }

        do {
            // Use the loopback IP literal (not "localhost") for the callback: it matches the IPv4 bind
            // exactly and sidesteps the localhost → ::1 vs 127.0.0.1 resolution ambiguity (RFC 8252 §7.3).
            let callback = "http://127.0.0.1:\(port)/callback"
            guard var comps = URLComponents(string: "https://openrouter.ai/auth") else {
                throw OAuthError.invalidResponse
            }
            comps.queryItems = [
                URLQueryItem(name: "callback_url", value: callback),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state),
            ]
            guard let authURL = comps.url else { throw OAuthError.invalidResponse }

            let opened = await MainActor.run { NSWorkspace.shared.open(authURL) }
            guard opened else { throw OAuthError.browserOpenFailed }

            let code = try await Self.withTimeout(timeout) {
                try await listener.waitForCode()
            }
            await listener.stop()

            return try await exchange(code: code, verifier: verifier)
        } catch {
            await listener.stop()
            throw Self.mapped(error)
        }
    }

    // MARK: token exchange

    private struct KeyExchangeRequest: Encodable {
        let code: String
        let code_verifier: String
        let code_challenge_method: String
    }
    private struct KeyExchangeResponse: Decodable { let key: String }

    /// POST the code + verifier to OpenRouter's pinned host and parse the returned key.
    /// Never logs the request or the response.
    private func exchange(code: String, verifier: String) async throws -> String {
        guard let url = URL(string: "https://openrouter.ai/api/v1/auth/keys") else {
            throw OAuthError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            KeyExchangeRequest(code: code, code_verifier: verifier, code_challenge_method: "S256"))

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await Self.session.data(for: req)
        } catch {
            throw OAuthError.exchangeFailed(Self.transportMessage(error))
        }
        guard let http = resp as? HTTPURLResponse else { throw OAuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // Status only — the error body is not logged/surfaced verbatim (defensive: no secret echo).
            throw OAuthError.exchangeFailed("HTTP \(http.statusCode)")
        }
        guard let decoded = try? JSONDecoder().decode(KeyExchangeResponse.self, from: data),
              !decoded.key.isEmpty else {
            throw OAuthError.noKey
        }
        return decoded.key
    }

    // MARK: PKCE

    /// 64 random bytes → base64url without padding (a 43…128-char verifier, per RFC 7636).
    /// Throws on RNG failure — NEVER proceed with weak/zero entropy (that would defeat PKCE).
    static func makeCodeVerifier() throws -> String {
        try base64URL(randomBytes(64))
    }

    /// A random `state` nonce (32 bytes → base64url) tying the browser round-trip to this flow.
    static func makeStateNonce() throws -> String {
        try base64URL(randomBytes(32))
    }

    /// `count` cryptographically-secure random bytes, or throw `.entropyFailed` if the system RNG fails.
    private static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw OAuthError.entropyFailed }
        return Data(bytes)
    }

    /// S256: base64url(SHA256(verifier)) without padding.
    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    /// base64url, no padding (RFC 4648 §5): `+`→`-`, `/`→`_`, drop `=`.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: helpers

    /// Blocks ALL redirects — a 3xx from the pinned host must never re-send the code/verifier elsewhere.
    /// One shared, stateless session backs the single exchange call.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        c.waitsForConnectivity = false
        return URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
    }()

    private static func transportMessage(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorNotConnectedToInternet {
            return String(localized: "no internet connection")
        }
        return String(localized: "network error")
    }

    /// Normalize CancellationError → `.cancelled`; pass typed errors through; wrap the rest.
    private static func mapped(_ error: Error) -> OAuthError {
        if error is CancellationError { return .cancelled }
        if let e = error as? OAuthError { return e }
        return .listenerFailed
    }

    /// Race an operation against an overall timeout. Cancelling the group unblocks the loopback wait
    /// via its cancellation handler, so the group never deadlocks on a suspended continuation.
    private static func withTimeout<T: Sendable>(
        _ timeout: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw OAuthError.timedOut
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            return result
        }
    }
}

// MARK: — loopback listener (one-shot callback capture)

/// A temporary 127.0.0.1-only HTTP listener that captures the OAuth callback exactly once.
/// Binds an ephemeral port (OS-assigned), answers the browser with a tiny "you can close this tab"
/// page, and hands the `code` (or provider `error`) back to `waitForCode()`. Everything is teardown-safe.
private actor LoopbackListener {

    private var listener: NWListener?
    private var portCont: CheckedContinuation<UInt16, Error>?
    private var codeCont: CheckedContinuation<String, Error>?
    private var pending: Result<String, Error>?   // callback arrived before waitForCode() was awaited
    private var delivered = false
    private var stopped = false
    private var expectedState: String?            // the `state` nonce; validated only if the callback echoes one

    private static let queue = DispatchQueue(label: "gg.zbs.eye.openrouter.oauth.loopback")
    /// Binding a loopback socket is near-instant; if it hasn't reached `.ready` within this window the
    /// bind is wedged — fail cleanly instead of suspending forever on the port continuation.
    private static let bindTimeout: TimeInterval = 10

    /// Bind 127.0.0.1 on an ephemeral port; resolves with the assigned port once listening.
    /// `expectedState` is the nonce validated only if the OAuth callback echoes one. Bounded by `bindTimeout` and
    /// cancellation-safe: a wedged bind, a cancelled task, or a terminal `.failed`/`.cancelled` state
    /// all resume the waiter (and tear the socket down) rather than leaking it.
    func start(expectedState: String) async throws -> UInt16 {
        self.expectedState = expectedState
        let params = NWParameters.tcp
        // requiredLocalEndpoint pins the bind to loopback ONLY (never 0.0.0.0); .any = ephemeral port.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true

        let l: NWListener
        do { l = try NWListener(using: params) }
        catch { throw OpenRouterOAuth.OAuthError.listenerFailed }
        listener = l

        l.stateUpdateHandler = { [weak self] state in
            Task { await self?.onState(state) }
        }
        l.newConnectionHandler = { [weak self] conn in
            Task { await self?.onConnection(conn) }
        }

        // Watchdog: fail the port wait if the socket never reaches a terminal state in time.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.bindTimeout * 1_000_000_000))
            await self?.failPortWait(.timedOut)
        }
        defer { watchdog.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
                // If teardown already happened (cancel/timeout), don't suspend — resume immediately.
                if stopped {
                    cont.resume(throwing: OpenRouterOAuth.OAuthError.cancelled)
                    return
                }
                portCont = cont
                l.start(queue: Self.queue)
            }
        } onCancel: {
            Task { await self.failPortWait(.cancelled) }
        }
    }

    /// Resume a still-pending port continuation with an error and tear the half-open socket down.
    /// Idempotent — whichever of {ready, failed, watchdog, cancel} lands first wins; the rest no-op.
    private func failPortWait(_ error: OpenRouterOAuth.OAuthError) {
        guard let cont = portCont else { return }
        portCont = nil
        stopped = true
        listener?.cancel()
        listener = nil
        cont.resume(throwing: error)
    }

    /// Await the authorization code (or a typed error). Cancellation-safe: cancelling the awaiting task
    /// resumes the continuation with `.cancelled` rather than leaking it.
    func waitForCode() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                if let p = pending {
                    pending = nil
                    cont.resume(with: p)
                    return
                }
                if stopped {
                    cont.resume(throwing: OpenRouterOAuth.OAuthError.cancelled)
                    return
                }
                codeCont = cont
            }
        } onCancel: {
            Task { await self.cancelWait() }
        }
    }

    /// Idempotent teardown: cancel the socket and unblock any pending waiters.
    func stop() {
        stopped = true
        listener?.cancel()
        listener = nil
        if let cont = portCont {
            portCont = nil
            cont.resume(throwing: OpenRouterOAuth.OAuthError.cancelled)
        }
        if let cont = codeCont {
            codeCont = nil
            cont.resume(throwing: OpenRouterOAuth.OAuthError.cancelled)
        }
    }

    // MARK: internals

    private func onState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let cont = portCont else { return }
            portCont = nil
            cont.resume(returning: listener?.port?.rawValue ?? 0)
        case .failed:
            failPortWait(.listenerFailed)
            deliver(.failure(OpenRouterOAuth.OAuthError.listenerFailed))
        case .cancelled:
            // Terminal: the socket is gone. Resume a still-pending port waiter so it can't hang.
            failPortWait(.cancelled)
        default:
            break
        }
    }

    private func onConnection(_ conn: NWConnection) {
        conn.start(queue: Self.queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            Task { await self?.onReceive(conn, buffer: buffer, data: data, isComplete: isComplete, error: error != nil) }
        }
    }

    private func onReceive(_ conn: NWConnection, buffer: Data, data: Data?, isComplete: Bool, error: Bool) {
        var buf = buffer
        if let data { buf.append(data) }
        // The request line (everything up to the first CRLF) is all we need for a GET.
        if let crlf = buf.firstRange(of: Data("\r\n".utf8)) {
            let line = buf.subdata(in: buf.startIndex..<crlf.lowerBound)
            handleRequestLine(conn, line)
            return
        }
        if error || isComplete || buf.count > 64 * 1024 {
            conn.cancel()
            return
        }
        receive(conn, buffer: buf)
    }

    private func handleRequestLine(_ conn: NWConnection, _ line: Data) {
        guard let text = String(data: line, encoding: .utf8) else {
            respondAndClose(conn, status: "400 Bad Request", html: "Bad request")
            return
        }
        // "GET /callback?code=… HTTP/1.1"
        let parts = text.split(separator: " ")
        guard parts.count >= 2, let comps = URLComponents(string: "http://localhost" + parts[1]) else {
            respondAndClose(conn, status: "400 Bad Request", html: "Bad request")
            return
        }
        guard comps.path == "/callback" else {
            // Favicon or a stray probe — answer, but don't treat it as the callback.
            respondAndClose(conn, status: "404 Not Found", html: "Not found")
            return
        }
        let items = comps.queryItems ?? []
        let code = items.first { $0.name == "code" }?.value
        let providerErr = items.first { $0.name == "error" }?.value
        let gotState = items.first { $0.name == "state" }?.value

        // CSRF/anti-injection: `state` is defense-in-depth ON TOP of PKCE (code↔verifier) + the loopback
        // bind. Validate it ONLY when the callback actually echoes one: OpenRouter's /auth PKCE flow is not
        // documented to return `state`, so rejecting on ABSENCE would break every real sign-in. Reject only
        // on an explicit MISMATCH (a present-but-wrong nonce ⇒ likely forged); a missing nonce still lands.
        if let expectedState, let gotState, gotState != expectedState {
            respondAndClose(conn, status: "400 Bad Request", html: "Bad request")
            return
        }

        respondAndClose(conn, status: "200 OK", html: Self.pageHTML)

        if let code, !code.isEmpty {
            deliver(.success(code))
        } else if let providerErr, !providerErr.isEmpty {
            deliver(.failure(OpenRouterOAuth.OAuthError.providerError(providerErr)))
        } else {
            deliver(.failure(OpenRouterOAuth.OAuthError.providerError("no code")))
        }
    }

    private func deliver(_ result: Result<String, Error>) {
        guard !delivered, !stopped else { return }
        delivered = true
        if let cont = codeCont {
            codeCont = nil
            cont.resume(with: result)
        } else {
            pending = result
        }
    }

    private func cancelWait() {
        stopped = true
        guard let cont = codeCont else { return }
        codeCont = nil
        cont.resume(throwing: OpenRouterOAuth.OAuthError.cancelled)
    }

    private func respondAndClose(_ conn: NWConnection, status: String, html: String) {
        let body = Data(html.utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var packet = Data(head.utf8)
        packet.append(body)
        conn.send(content: packet, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static let pageHTML = """
    <!doctype html><html lang="en"><head><meta charset="utf-8">\
    <meta name="viewport" content="width=device-width, initial-scale=1">\
    <title>ZBS Eye</title></head>\
    <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;text-align:center;padding:3rem 1.5rem;color:#1d1d1f;background:#f5f5f7">\
    <h2 style="font-weight:600">You're signed in.</h2>\
    <p style="color:#6e6e73">You can close this tab and return to ZBS Eye.</p></body></html>
    """
}
