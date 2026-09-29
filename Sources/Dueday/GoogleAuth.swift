import AppKit
import CryptoKit

/// The user's own OAuth client ("Desktop app" type in Google Cloud). A desktop client's secret is not
/// actually secret (Google's own words), but it is still required by the token endpoint.
struct OAuthClient: Codable, Equatable {
    var clientID: String
    var clientSecret: String
}

private struct StoredAuth: Codable {
    var client: OAuthClient
    var refreshToken: String?
}

enum AuthError: LocalizedError {
    case notConfigured
    case notSignedIn
    case cancelled
    case denied(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Enter your OAuth Client ID and Secret first."
        case .notSignedIn: "Signed out — please sign in again."
        case .cancelled: "Sign-in cancelled."
        case .denied(let reason): "Google declined the sign-in (\(reason))."
        case .server(let message): message
        }
    }
}

/// Installed-app OAuth: the browser signs in and redirects to a one-shot server on 127.0.0.1, with PKCE.
@MainActor
final class GoogleAuth: ObservableObject {
    static let shared = GoogleAuth()
    static let scope = "https://www.googleapis.com/auth/tasks"

    @Published private(set) var client: OAuthClient?
    @Published private(set) var isSignedIn = false
    @Published private(set) var isSigningIn = false

    private var refreshToken: String?
    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var refreshing: Task<String, Error>?
    private var loopback: LoopbackServer?

    private init() {
        if let stored = Keychain.load(StoredAuth.self) {
            client = stored.client
            refreshToken = stored.refreshToken
            isSignedIn = stored.refreshToken != nil
        }
    }

    private func persist() {
        guard let client else {
            Keychain.delete()
            return
        }
        Keychain.save(StoredAuth(client: client, refreshToken: refreshToken))
    }

    // MARK: Sign in / out

    func signIn(with newClient: OAuthClient) async throws {
        let newClient = OAuthClient(clientID: newClient.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                    clientSecret: newClient.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !newClient.clientID.isEmpty, !newClient.clientSecret.isEmpty else { throw AuthError.notConfigured }
        cancelSignIn()
        isSigningIn = true
        defer {
            isSigningIn = false
            loopback?.stop()
            loopback = nil
        }

        let verifier = Self.randomURLSafe(bytes: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(bytes: 16)

        let server = LoopbackServer()
        loopback = server
        let port = try server.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            .init(name: "client_id", value: newClient.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(auth.url!)

        let params = try await server.waitForRedirect()
        if let error = params["error"] { throw AuthError.denied(error) }
        guard params["state"] == state, let code = params["code"] else { throw AuthError.server("Unexpected redirect from Google.") }

        let token = try await Self.tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "client_id": newClient.clientID,
            "client_secret": newClient.clientSecret,
        ])
        guard let refresh = token.refresh_token else { throw AuthError.server("Google returned no refresh token.") }
        client = newClient
        refreshToken = refresh
        accessToken = token.access_token
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600) - 60)
        persist()
        isSignedIn = true
    }

    func cancelSignIn() {
        loopback?.cancel()
    }

    /// Forgets the tokens (and revokes them at Google) but keeps the client, so signing in again is one click.
    func signOut() {
        if let token = refreshToken {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.formBody(["token": token])
            URLSession.shared.dataTask(with: req).resume()
        }
        dropSession()
    }

    /// Removes the client too.
    func forgetClient() {
        signOut()
        client = nil
        persist()
    }

    private func dropSession() {
        refreshing?.cancel()
        refreshing = nil
        refreshToken = nil
        accessToken = nil
        accessTokenExpiry = .distantPast
        isSignedIn = false
        persist()
    }

    // MARK: Access tokens

    /// A valid access token, refreshed when needed; concurrent callers share one refresh.
    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let accessToken, Date() < accessTokenExpiry { return accessToken }
        if let refreshing { return try await refreshing.value }
        guard let client, let refreshToken else { throw AuthError.notSignedIn }
        let task = Task { () throws -> String in
            do {
                let token = try await Self.tokenRequest([
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken,
                    "client_id": client.clientID,
                    "client_secret": client.clientSecret,
                ])
                return token.access_token
            } catch AuthError.denied {
                // invalid_grant: revoked, expired (Testing-mode projects expire tokens after 7 days), etc.
                throw AuthError.notSignedIn
            }
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let token = try await task.value
            accessToken = token
            accessTokenExpiry = Date().addingTimeInterval(3500)
            return token
        } catch AuthError.notSignedIn {
            dropSession()
            throw AuthError.notSignedIn
        }
    }

    // MARK: Helpers

    private struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Int?
        var refresh_token: String?
    }

    private struct TokenError: Decodable {
        var error: String
        var error_description: String?
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody(form)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let err = try? JSONDecoder().decode(TokenError.self, from: data) {
                if err.error == "invalid_grant" { throw AuthError.denied(err.error) }
                throw AuthError.server(err.error_description ?? err.error)
            }
            throw AuthError.server("Token request failed (HTTP \(status)).")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func formBody(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        .joined(separator: "&")
        .data(using: .utf8)!
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A tiny HTTP server on 127.0.0.1 (random port) that waits for the single OAuth redirect.
private final class LoopbackServer: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    func start() throws -> UInt16 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw AuthError.server("Couldn’t open a local port for sign-in.") }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(sock, sa, len) == 0 && listen(sock, 4) == 0 && getsockname(sock, sa, &len) == 0
            }
        }
        guard ok else {
            close(sock)
            throw AuthError.server("Couldn’t open a local port for sign-in.")
        }
        fd = sock
        let port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [self] in acceptLoop(sock) }
        return port
    }

    func waitForRedirect() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let result {
                lock.unlock()
                cont.resume(with: result)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    func cancel() { finish(.failure(AuthError.cancelled)) }

    func stop() {
        lock.lock()
        let sock = fd
        fd = -1
        lock.unlock()
        if sock >= 0 {
            shutdown(sock, SHUT_RDWR)
            close(sock)
        }
    }

    private func finish(_ r: Result<[String: String], Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = r
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: r)
        stop()
    }

    private func acceptLoop(_ sock: Int32) {
        while true {
            let client = accept(sock, nil, nil)
            guard client >= 0 else { return }  // closed by stop()
            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = read(client, &buffer, buffer.count)
            let request = n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
            // "GET /?code=…&state=… HTTP/1.1"
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let items = URLComponents(string: "http://localhost" + target)?.queryItems ?? []
            var params: [String: String] = [:]
            for item in items { params[item.name] = item.value ?? "" }
            let handled = params["code"] != nil || params["error"] != nil
            let body = handled
                ? "<!doctype html><meta charset=utf-8><title>Dueday</title><body style=\"font:15px -apple-system;text-align:center;padding-top:80px\"><h2>Signed in to Dueday</h2><p>You can close this tab.</p>"
                : "Not found"
            let response = "HTTP/1.1 \(handled ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            _ = response.withCString { write(client, $0, strlen($0)) }
            close(client)
            if handled {
                finish(.success(params))
                return
            }
        }
    }
}
