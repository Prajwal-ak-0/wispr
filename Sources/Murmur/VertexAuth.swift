import Foundation
import Security

// Service-account authentication for Vertex AI.
//
// The app signs its own JWT and exchanges it for an access token, so meeting transcription never
// depends on gcloud being installed or on a developer's personal login being current.
struct VertexServiceAccount: Equatable {
    let clientEmail: String
    let tokenURI: String
    let projectID: String
    let privateKeyPEM: String

    static func load(path: String) throws -> VertexServiceAccount {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw VertexAuthError.missingCredentials(expanded)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["client_email"] as? String,
              let key = json["private_key"] as? String,
              let project = json["project_id"] as? String else {
            throw VertexAuthError.malformedCredentials
        }
        return VertexServiceAccount(
            clientEmail: email,
            tokenURI: (json["token_uri"] as? String) ?? "https://oauth2.googleapis.com/token",
            projectID: project,
            privateKeyPEM: key)
    }
}

enum VertexAuthError: LocalizedError {
    case missingCredentials(String)
    case malformedCredentials
    case keyImportFailed(String)
    case signingFailed(String)
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let path): return "Vertex service-account file not found at \(path)"
        case .malformedCredentials: return "Vertex service-account JSON is missing client_email, private_key, or project_id"
        case .keyImportFailed(let detail): return "Could not read the service-account private key: \(detail)"
        case .signingFailed(let detail): return "Could not sign the Vertex auth request: \(detail)"
        case .tokenExchangeFailed(let detail): return "Vertex token exchange failed: \(detail)"
        }
    }
}

// Caches one access token per service account until shortly before it expires. Tokens last an hour,
// so a long meeting transcription performs exactly one token exchange.
actor VertexTokenProvider {
    static let shared = VertexTokenProvider()
    private var cache: [String: (token: String, expiresAt: Date)] = [:]

    func accessToken(for account: VertexServiceAccount) async throws -> String {
        if let cached = cache[account.clientEmail], cached.expiresAt > Date().addingTimeInterval(120) {
            return cached.token
        }
        let assertion = try Self.signedAssertion(for: account)
        var request = URLRequest(url: URL(string: account.tokenURI)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(assertion)"
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw VertexAuthError.tokenExchangeFailed(String(decoding: data.prefix(400), as: UTF8.self))
        }
        let lifetime = (json["expires_in"] as? Double) ?? 3600
        cache[account.clientEmail] = (token, Date().addingTimeInterval(lifetime))
        return token
    }

    private static func signedAssertion(for account: VertexServiceAccount) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header = ["alg": "RS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": account.clientEmail,
            "scope": "https://www.googleapis.com/auth/cloud-platform",
            "aud": account.tokenURI,
            "iat": now,
            "exp": now + 3600,
        ]
        let headerPart = base64URL(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let claimsPart = base64URL(try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
        let signingInput = "\(headerPart).\(claimsPart)"

        let key = try privateKey(from: account.privateKeyPEM)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                                    Data(signingInput.utf8) as CFData, &error) as Data? else {
            throw VertexAuthError.signingFailed(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        return "\(signingInput).\(base64URL(signature))"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // Service-account keys arrive as PKCS#8 PEM. SecKey wants the bare PKCS#1 RSA key, so the
    // PKCS#8 wrapper is unwrapped here rather than shelling out to openssl.
    private static func privateKey(from pem: String) throws -> SecKey {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let der = Data(base64Encoded: base64) else {
            throw VertexAuthError.keyImportFailed("private_key is not valid base64 PEM")
        }
        let pkcs1 = pem.contains("BEGIN RSA PRIVATE KEY") ? der : try unwrapPKCS8(der)

        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw VertexAuthError.keyImportFailed(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        return key
    }

    // PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE, privateKey OCTET STRING }
    // Returns the contents of that OCTET STRING, which is the PKCS#1 RSAPrivateKey.
    private static func unwrapPKCS8(_ der: Data) throws -> Data {
        var index = der.startIndex
        func byte() throws -> UInt8 {
            guard index < der.endIndex else { throw VertexAuthError.keyImportFailed("truncated key") }
            defer { index = der.index(after: index) }
            return der[index]
        }
        func length() throws -> Int {
            let first = try byte()
            guard first & 0x80 != 0 else { return Int(first) }
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4 else { throw VertexAuthError.keyImportFailed("bad DER length") }
            var value = 0
            for _ in 0..<count { value = (value << 8) | Int(try byte()) }
            return value
        }
        guard try byte() == 0x30 else { throw VertexAuthError.keyImportFailed("expected DER sequence") }
        _ = try length()
        guard try byte() == 0x02 else { throw VertexAuthError.keyImportFailed("expected version integer") }
        // The length has to be consumed before the skip is computed: reading it advances `index`.
        let versionLength = try length()
        index = der.index(index, offsetBy: versionLength)
        guard try byte() == 0x30 else { throw VertexAuthError.keyImportFailed("expected algorithm sequence") }
        let algorithmLength = try length()
        index = der.index(index, offsetBy: algorithmLength)
        guard try byte() == 0x04 else { throw VertexAuthError.keyImportFailed("expected key octet string") }
        let keyLength = try length()
        guard der.distance(from: index, to: der.endIndex) >= keyLength else {
            throw VertexAuthError.keyImportFailed("key octet string overruns the file")
        }
        return der.subdata(in: index..<der.index(index, offsetBy: keyLength))
    }
}
