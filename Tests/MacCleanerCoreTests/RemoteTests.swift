import Foundation
import Testing
@testable import MacCleanerCore

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    private let respond: @Sendable (URLRequest, Int) -> (String, Int)

    init(_ respond: @escaping @Sendable (URLRequest, Int) -> (String, Int)) {
        self.respond = respond
    }

    var requests: [URLRequest] { lock.withLock { stored } }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let index = lock.withLock {
            stored.append(request)
            return stored.count - 1
        }
        let (body, status) = respond(request, index)
        return (Data(body.utf8), status)
    }
}

final class MemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RemoteProvider: OAuthTokens] = [:]

    func tokens(for provider: RemoteProvider) -> OAuthTokens? { lock.withLock { values[provider] } }
    func hasTokens(for provider: RemoteProvider) -> Bool { tokens(for: provider) != nil }
    func save(_ tokens: OAuthTokens, for provider: RemoteProvider) throws { lock.withLock { values[provider] = tokens } }
    func delete(for provider: RemoteProvider) { lock.withLock { values[provider] = nil } }
}

@Suite struct RemoteTests {
    private func client(_ provider: RemoteProvider, _ transport: FakeTransport, token: String = "tok", expires: TimeInterval = 3600) throws -> RemoteClient {
        let store = MemoryTokenStore()
        try store.save(OAuthTokens(accessToken: token, refreshToken: "refresh", expiresAt: Date().addingTimeInterval(expires)), for: provider)
        return RemoteClient(oauth: OAuthClient(provider: provider, clientID: "id", store: store, transport: transport), transport: transport)
    }

    // MARK: OAuth

    @Test func testPKCEMatchesRFC7636Vector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func testAuthorizationURLUsesPKCEAndMinimalScope() throws {
        let client = OAuthClient(provider: .dropbox, clientID: "app", store: MemoryTokenStore(), transport: FakeTransport { _, _ in ("", 200) })
        let url = try #require(client.authorizationURL(state: "s", pkce: PKCE()))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        #expect(value("code_challenge_method") == "S256")
        #expect(value("state") == "s")
        #expect(value("token_access_type") == "offline")
        #expect(value("redirect_uri") == "http://localhost:53682/callback")
        #expect(value("scope")?.contains("files.permanently_delete") == false)
    }

    @Test func testCallbackParsing() throws {
        let good = LoopbackReceiver.parse(requestLine: "GET /callback?code=abc&state=s HTTP/1.1", expectedState: "s")
        #expect(try good?.get() == "abc")
        #expect(LoopbackReceiver.parse(requestLine: "GET /favicon.ico HTTP/1.1", expectedState: "s") == nil)
        #expect(LoopbackReceiver.parse(requestLine: "POST /callback?code=a&state=s HTTP/1.1", expectedState: "s") == nil)
        let forged = LoopbackReceiver.parse(requestLine: "GET /callback?code=abc&state=evil HTTP/1.1", expectedState: "s")
        #expect(throws: RemoteError.stateMismatch) { try forged?.get() }
        let denied = LoopbackReceiver.parse(requestLine: "GET /callback?error=access_denied&state=s HTTP/1.1", expectedState: "s")
        #expect(throws: RemoteError.authorizationDenied("access_denied")) { try denied?.get() }
    }

    @Test func testLoopbackReceivesRealRedirect() async throws {
        let receiver = LoopbackReceiver(state: "s", port: 53683)
        let code = try await receiver.waitForCode(timeout: .seconds(5)) {
            Task {
                let url = URL(string: "http://127.0.0.1:53683/callback?code=real&state=s")!
                _ = try? await URLSession.shared.data(from: url)
            }
        }
        #expect(code == "real")
    }

    @Test func testExchangeStoresTokensAndSendsVerifier() async throws {
        let store = MemoryTokenStore()
        let transport = FakeTransport { _, _ in (#"{"access_token":"a","refresh_token":"r","expires_in":3600}"#, 200) }
        let client = OAuthClient(provider: .gmail, clientID: "id", clientSecret: "sec", store: store, transport: transport)
        let pkce = PKCE()
        try await client.exchange(code: "c/1", pkce: pkce)
        #expect(store.tokens(for: .gmail)?.refreshToken == "r")
        let body = String(decoding: try #require(transport.requests.first?.httpBody), as: UTF8.self)
        #expect(body.contains("code_verifier=\(pkce.verifier)"))
        #expect(body.contains("code=c%2F1"))
        #expect(body.contains("client_secret=sec"))
    }

    @Test func testExpiredTokenRefreshesAndKeepsRefreshToken() async throws {
        let store = MemoryTokenStore()
        try store.save(OAuthTokens(accessToken: "old", refreshToken: "r", expiresAt: .distantPast), for: .dropbox)
        let transport = FakeTransport { _, _ in (#"{"access_token":"new","expires_in":3600}"#, 200) }
        let client = OAuthClient(provider: .dropbox, clientID: "id", store: store, transport: transport)
        #expect(try await client.accessToken() == "new")
        #expect(store.tokens(for: .dropbox)?.refreshToken == "r")
    }

    @Test func testMissingTokensReportNotConnected() async {
        let client = OAuthClient(provider: .gmail, clientID: "id", store: MemoryTokenStore(), transport: FakeTransport { _, _ in ("", 200) })
        await #expect(throws: RemoteError.notConnected) { try await client.accessToken() }
    }

    @Test func testUnauthorizedRetriesOnceWithFreshToken() async throws {
        let transport = FakeTransport { request, index in
            if request.url?.host == "oauth2.googleapis.com" { return (#"{"access_token":"fresh"}"#, 200) }
            return index == 0 ? ("{}", 401) : (#"{"files":[]}"#, 200)
        }
        _ = try await GoogleDriveService(client: client(.googleDrive, transport)).list()
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    @Test func testHTTPErrorSurfacesBoundedMessage() async throws {
        let transport = FakeTransport { _, _ in (#"{"error":{"message":"Quota dépassé"}}"#, 403) }
        await #expect(throws: RemoteError.http(status: 403, message: "Quota dépassé")) {
            _ = try await DropboxService(client: client(.dropbox, transport)).list()
        }
    }

    // MARK: Services

    @Test func testGmailListsLargeMessagesAndTrashes() async throws {
        let transport = FakeTransport { request, _ in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/messages") { return (#"{"messages":[{"id":"m1"}]}"#, 200) }
            if path.hasSuffix("/trash") { return ("{}", 200) }
            return (#"{"sizeEstimate":9000000,"payload":{"headers":[{"name":"Subject","value":"Photos"},{"name":"From","value":"a@b"}]}}"#, 200)
        }
        let service = GmailService(client: try client(.gmail, transport))
        let items = try await service.list()
        #expect(items == [RemoteItem(id: "m1", name: "Photos", detail: "a@b", size: 9_000_000)])
        #expect(transport.requests[0].url?.absoluteString.contains("q=larger%3A5M") == true)
        try await service.moveToTrash(items[0])
        #expect(transport.requests.last?.httpMethod == "POST")
        #expect(transport.requests.last?.url?.path == "/gmail/v1/users/me/messages/m1/trash")
    }

    @Test func testOutlookMovesToDeletedItems() async throws {
        let body = #"{"value":[{"id":"a/b","subject":"Devis","from":{"emailAddress":{"address":"x@y"}},"receivedDateTime":"2026-01-02T03:04:05Z","singleValueExtendedProperties":[{"value":"7000"}]}]}"#
        let transport = FakeTransport { _, _ in (body, 200) }
        let service = OutlookService(client: try client(.outlook, transport))
        let items = try await service.list()
        #expect(items.first?.size == 7000)
        #expect(items.first?.detail == "x@y · 2026-01-02")
        try await service.moveToTrash(try #require(items.first))
        let request = try #require(transport.requests.last)
        #expect(request.url?.absoluteString.hasSuffix("/messages/a%2Fb/move") == true)
        #expect(String(decoding: try #require(request.httpBody), as: UTF8.self).contains("deleteditems"))
    }

    @Test func testDriveTrashesWithoutDeleting() async throws {
        let transport = FakeTransport { _, _ in (#"{"files":[{"id":"f1","name":"gros.zip","quotaBytesUsed":"500","modifiedTime":"2026-03-04T00:00:00Z"}]}"#, 200) }
        let service = GoogleDriveService(client: try client(.googleDrive, transport))
        let items = try await service.list()
        #expect(items.first?.size == 500)
        try await service.moveToTrash(try #require(items.first))
        #expect(transport.requests.last?.httpMethod == "PATCH")
        #expect(String(decoding: try #require(transport.requests.last?.httpBody), as: UTF8.self).contains("trashed"))
    }

    @Test func testOneDriveWalksFolders() async throws {
        let transport = FakeTransport { request, _ in
            if request.url?.absoluteString.contains("/items/dir/children") == true {
                return (#"{"value":[{"id":"f2","name":"b.bin","size":20,"file":{}}]}"#, 200)
            }
            return (#"{"value":[{"id":"dir","name":"Dossier","size":99,"folder":{}},{"id":"f1","name":"a.bin","size":10,"file":{}}]}"#, 200)
        }
        let items = try await OneDriveService(client: client(.oneDrive, transport)).list()
        #expect(items.map(\.id) == ["f2", "f1"])
    }

    @Test func testDropboxFollowsCursorAndSkipsFolders() async throws {
        let transport = FakeTransport { request, _ in
            if request.url?.path.hasSuffix("/continue") == true {
                return (#"{"entries":[{".tag":"file","name":"b","path_lower":"/b","size":20}],"has_more":false}"#, 200)
            }
            return (#"{"entries":[{".tag":"folder","name":"d","path_lower":"/d"},{".tag":"file","name":"a","path_lower":"/a","size":10}],"has_more":true,"cursor":"c"}"#, 200)
        }
        let service = DropboxService(client: try client(.dropbox, transport))
        let items = try await service.list()
        #expect(items.map(\.id) == ["/b", "/a"])
        try await service.moveToTrash(items[0])
        #expect(transport.requests.last?.url?.path == "/2/files/delete_v2")
    }

    @Test func testNoServiceUsesPermanentDeletion() async throws {
        let transport = FakeTransport { _, _ in ("{}", 200) }
        let item = RemoteItem(id: "x", name: "x", detail: "", size: 1)
        for provider in RemoteProvider.allCases {
            try await RemoteServices.make(provider, client: client(provider, transport)).moveToTrash(item)
        }
        let addresses = transport.requests.compactMap { $0.url?.absoluteString }
        #expect(!addresses.contains { $0.contains("permanently_delete") || $0.contains("permanentDelete") })
        #expect(transport.requests.filter { $0.httpMethod == "DELETE" }.count == 1)
    }

    @Test func testIdentifierCannotChangeURLPath() {
        #expect(RemoteFormat.path("../../me") == "..%2F..%2Fme")
    }

    @Test func testRemoteHistoryKeepsNoNames() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let history = CleanupHistory(fileURL: url)
        try history.recordRemote(module: "Gmail", count: 2, bytes: 10, failures: 0)
        #expect(history.load().entries.first?.paths.isEmpty == true)
    }

    @Test func testBuildCredentialsLoadAndStayEmptyWithoutFile() throws {
        #expect(CloudCredentials.load(from: nil).clientID(for: .gmail).isEmpty)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"googleClientID":"g","googleClientSecret":"s","microsoftClientID":"m","dropboxClientID":"d"}"#.utf8).write(to: url)
        let credentials = CloudCredentials.load(from: url)
        #expect(credentials.clientID(for: .outlook) == "m")
        #expect(credentials.clientSecret(for: .googleDrive) == "s")
        #expect(credentials.clientSecret(for: .dropbox) == nil)
    }
}
