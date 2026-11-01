import CryptoKit
import Foundation
import Network
import Security

public enum RemoteProvider: String, CaseIterable, Identifiable, Sendable {
    case gmail, outlook, googleDrive, oneDrive, dropbox

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .gmail: "Gmail"
        case .outlook: "Outlook"
        case .googleDrive: "Google Drive"
        case .oneDrive: "OneDrive"
        case .dropbox: "Dropbox"
        }
    }

    public var isEmail: Bool { self == .gmail || self == .outlook }

    public enum Vendor: Sendable { case google, microsoft, dropbox }

    public var vendor: Vendor {
        switch self {
        case .gmail, .googleDrive: .google
        case .outlook, .oneDrive: .microsoft
        case .dropbox: .dropbox
        }
    }

    var scopes: String {
        switch self {
        case .gmail: "https://www.googleapis.com/auth/gmail.modify"
        case .googleDrive: "https://www.googleapis.com/auth/drive"
        case .outlook: "offline_access Mail.ReadWrite"
        case .oneDrive: "offline_access Files.ReadWrite"
        case .dropbox: "files.metadata.read files.content.write"
        }
    }

    var authorizationEndpoint: String {
        switch vendor {
        case .google: "https://accounts.google.com/o/oauth2/v2/auth"
        case .microsoft: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
        case .dropbox: "https://www.dropbox.com/oauth2/authorize"
        }
    }

    var tokenEndpoint: String {
        switch vendor {
        case .google: "https://oauth2.googleapis.com/token"
        case .microsoft: "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        case .dropbox: "https://api.dropboxapi.com/oauth2/token"
        }
    }
}

/// Identifiants de l'application OAuth de ce build, lus dans ses ressources.
/// Le fichier reste hors du dépôt : voir `Config/OAuthClients.example.json`.
public struct CloudCredentials: Codable, Equatable, Sendable {
    public var googleClientID = ""
    public var googleClientSecret = ""
    public var microsoftClientID = ""
    public var dropboxClientID = ""

    public init() {}

    public func clientID(for provider: RemoteProvider) -> String {
        switch provider.vendor {
        case .google: googleClientID
        case .microsoft: microsoftClientID
        case .dropbox: dropboxClientID
        }
    }

    public func clientSecret(for provider: RemoteProvider) -> String? {
        provider.vendor == .google && !googleClientSecret.isEmpty ? googleClientSecret : nil
    }

    public static func load(from url: URL?) -> CloudCredentials {
        url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(CloudCredentials.self, from: $0) } ?? CloudCredentials()
    }
}

public enum RemoteError: LocalizedError, Equatable {
    case notConnected
    case missingClientID
    case stateMismatch
    case authorizationDenied(String)
    case timedOut
    case http(status: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Compte non connecté."
        case .missingClientID: "Identifiant client manquant."
        case .stateMismatch: "Réponse d'autorisation refusée : état différent de la demande."
        case .authorizationDenied(let reason): "Autorisation refusée : \(reason)"
        case .timedOut: "Autorisation expirée."
        case .http(let status, let message): "Erreur \(status) : \(message)"
        case .invalidResponse: "Réponse du service illisible."
        }
    }
}

public struct OAuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
}

public protocol TokenStoring: Sendable {
    func tokens(for provider: RemoteProvider) -> OAuthTokens?
    func hasTokens(for provider: RemoteProvider) -> Bool
    func save(_ tokens: OAuthTokens, for provider: RemoteProvider) throws
    func delete(for provider: RemoteProvider)
}

/// Élément du trousseau lisible uniquement Mac déverrouillé, jamais synchronisé.
public struct Keychain: Sendable {
    private let service: String

    public init(service: String = "local.maccleaner.oauth") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// Lit seulement les attributs : contrairement à `read`, ne déclenche aucune demande de mot de passe.
    public func contains(_ account: String) -> Bool {
        var request = query(account)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    public func read(_ account: String) -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func write(_ data: Data, account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

public struct KeychainTokenStore: TokenStoring {
    private let keychain: Keychain

    public init(keychain: Keychain = Keychain()) {
        self.keychain = keychain
    }

    public func tokens(for provider: RemoteProvider) -> OAuthTokens? {
        keychain.read(provider.rawValue).flatMap { try? JSONDecoder().decode(OAuthTokens.self, from: $0) }
    }

    public func hasTokens(for provider: RemoteProvider) -> Bool {
        keychain.contains(provider.rawValue)
    }

    public func save(_ tokens: OAuthTokens, for provider: RemoteProvider) throws {
        try keychain.write(JSONEncoder().encode(tokens), account: provider.rawValue)
    }

    public func delete(for provider: RemoteProvider) {
        keychain.delete(provider.rawValue)
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String = PKCE.randomString()) {
        self.verifier = verifier
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            preconditionFailure("Générateur aléatoire indisponible")
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct OAuthClient: Sendable {
    public static let callbackPort: UInt16 = 53682
    public static let redirectURI = "http://localhost:\(callbackPort)/callback"

    private let provider: RemoteProvider
    private let clientID: String
    private let clientSecret: String?
    private let store: any TokenStoring
    private let transport: any HTTPTransport

    public init(
        provider: RemoteProvider, clientID: String, clientSecret: String? = nil,
        store: any TokenStoring = KeychainTokenStore(), transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.provider = provider
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.store = store
        self.transport = transport
    }

    public func authorizationURL(state: String, pkce: PKCE) -> URL? {
        var items = [
            ("client_id", clientID), ("redirect_uri", Self.redirectURI), ("response_type", "code"),
            ("scope", provider.scopes), ("state", state),
            ("code_challenge", pkce.challenge), ("code_challenge_method", "S256"),
        ]
        switch provider.vendor {
        case .google: items += [("access_type", "offline"), ("prompt", "consent")]
        case .dropbox: items.append(("token_access_type", "offline"))
        case .microsoft: break
        }
        var components = URLComponents(string: provider.authorizationEndpoint)
        components?.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components?.url
    }

    public func exchange(code: String, pkce: PKCE) async throws {
        let tokens = try await requestTokens([
            ("grant_type", "authorization_code"), ("code", code),
            ("redirect_uri", Self.redirectURI), ("code_verifier", pkce.verifier),
        ], previousRefresh: nil)
        try store.save(tokens, for: provider)
    }

    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens = store.tokens(for: provider) else { throw RemoteError.notConnected }
        if !forceRefresh, tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        guard let refresh = tokens.refreshToken else { throw RemoteError.notConnected }
        let renewed = try await requestTokens([("grant_type", "refresh_token"), ("refresh_token", refresh)], previousRefresh: refresh)
        try store.save(renewed, for: provider)
        return renewed.accessToken
    }

    private func requestTokens(_ fields: [(String, String)], previousRefresh: String?) async throws -> OAuthTokens {
        guard let url = URL(string: provider.tokenEndpoint) else { throw RemoteError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = fields + [("client_id", clientID)]
        if let clientSecret, !clientSecret.isEmpty { form.append(("client_secret", clientSecret)) }
        request.httpBody = Data(form.map { "\($0.0)=\(Self.formEncoded($0.1))" }.joined(separator: "&").utf8)
        let (data, status) = try await transport.send(request)
        guard (200..<300).contains(status) else {
            throw RemoteError.http(status: status, message: RemoteMessage.extract(from: data))
        }
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw RemoteError.invalidResponse }
        return OAuthTokens(
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? previousRefresh,
            expiresAt: Date().addingTimeInterval(response.expires_in ?? 3600)
        )
    }

    private static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

enum RemoteMessage {
    /// Limité : un message d'erreur distant ne doit pas envahir l'interface.
    static func extract(from data: Data) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = json?["error"]
        let message = (error as? [String: Any])?["message"] as? String
            ?? json?["error_description"] as? String
            ?? json?["error_summary"] as? String
            ?? error as? String
        return String((message ?? "réponse inattendue").prefix(200))
    }
}

/// Reçoit l'unique redirection OAuth sur la boucle locale, puis s'arrête.
public final class LoopbackReceiver: @unchecked Sendable {
    private let port: UInt16
    private let expectedState: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var listener: NWListener?

    public init(state: String, port: UInt16 = OAuthClient.callbackPort) {
        expectedState = state
        self.port = port
    }

    /// `onReady` s'exécute une fois le port ouvert : le navigateur peut alors être lancé.
    public func waitForCode(timeout: Duration = .seconds(300), onReady: @escaping @Sendable () -> Void) async throws -> String {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw RemoteError.invalidResponse }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: onReady()
                case .failed(let error): self?.finish(.failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: .global())
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(.failure(RemoteError.timedOut))
            }
        }
    }

    public func cancel() {
        finish(.failure(CancellationError()))
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let line = data.flatMap { String(decoding: $0, as: UTF8.self).split(separator: "\r\n").first }.map(String.init) ?? ""
            let outcome = Self.parse(requestLine: line, expectedState: self.expectedState)
            let page = (try? outcome?.get()) != nil
                ? "Connexion réussie. Vous pouvez fermer cet onglet."
                : "Connexion refusée. Revenez à macCleaner."
            let body = "<!doctype html><meta charset=utf-8><title>macCleaner</title><p>\(page)</p>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let outcome { self.finish(outcome) }
        }
    }

    /// `nil` pour une requête parasite comme `/favicon.ico`, qui ne doit pas clore l'attente.
    static func parse(requestLine: String, expectedState: String) -> Result<String, Error>? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: String(parts[1])),
              components.path == "/callback" else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == expectedState else { return .failure(RemoteError.stateMismatch) }
        if let error = value("error") { return .failure(RemoteError.authorizationDenied(String(error.prefix(100)))) }
        guard let code = value("code"), !code.isEmpty else { return .failure(RemoteError.invalidResponse) }
        return .success(code)
    }

    private func finish(_ result: Result<String, Error>) {
        let waiting = lock.withLock {
            let waiting = continuation
            continuation = nil
            return waiting
        }
        guard let waiting else { return }
        listener?.cancel()
        waiting.resume(with: result)
    }
}
