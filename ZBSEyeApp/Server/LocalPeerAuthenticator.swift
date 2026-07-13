import CryptoKit
import Foundation
import Security

/// Token-derived proof for the unauthenticated localhost health probe. The MCP
/// helper verifies this before it sends a bearer token to a port read from a
/// potentially stale file.
enum LocalPeerAuthenticator {
    static let challengeByteCount = 32

    static func makeChallenge() -> String {
        var bytes = [UInt8](repeating: 0, count: challengeByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func proof(token: String, challenge: String, listeningPort: Int) -> String? {
        guard challenge.utf8.count == challengeByteCount * 2,
              challenge.allSatisfy({ $0.isHexDigit }),
              (1...65_535).contains(listeningPort) else { return nil }
        let key = SymmetricKey(data: Data(token.utf8))
        let message = "zbseye-local-peer-v1\n\(listeningPort)\n\(challenge)"
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: key
        )
        return signature.map { String(format: "%02x", $0) }.joined()
    }

    static func verify(
        proof candidate: String,
        token: String,
        challenge: String,
        listeningPort: Int
    ) -> Bool {
        guard let expected = proof(
            token: token,
            challenge: challenge,
            listeningPort: listeningPort
        ),
              candidate.utf8.count == expected.utf8.count else { return false }
        return zip(candidate.utf8, expected.utf8).reduce(UInt8.zero) {
            $0 | ($1.0 ^ $1.1)
        } == 0
    }
}
