import Foundation

public struct RemoteItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let size: Int64

    public init(id: String, name: String, detail: String, size: Int64) {
        self.id = id
        self.name = name
        self.detail = detail
        self.size = size
    }
}

/// Toutes les suppressions passent par la corbeille du service et restent récupérables.
public protocol RemoteService: Sendable {
    func list() async throws -> [RemoteItem]
    func moveToTrash(_ item: RemoteItem) async throws
}

public struct RemoteClient: Sendable {
    private let oauth: OAuthClient
    private let transport: any HTTPTransport

    public init(oauth: OAuthClient, transport: any HTTPTransport = URLSessionTransport()) {
        self.oauth = oauth
        self.transport = transport
    }

    func request(_ address: String, method: String = "GET", json: Any? = nil) async throws -> Data {
        guard let url = URL(string: address) else { throw RemoteError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        var (data, status) = try await send(request, token: oauth.accessToken())
        if status == 401 {
            (data, status) = try await send(request, token: oauth.accessToken(forceRefresh: true))
        }
        guard (200..<300).contains(status) else {
            throw RemoteError.http(status: status, message: RemoteMessage.extract(from: data))
        }
        return data
    }

    func object(_ address: String, method: String = "GET", json: Any? = nil) async throws -> [String: Any] {
        let data = try await request(address, method: method, json: json)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteError.invalidResponse
        }
        return object
    }

    private func send(_ request: URLRequest, token: String) async throws -> (Data, Int) {
        var signed = request
        signed.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await transport.send(signed)
    }
}

enum RemoteFormat {
    /// Un identifiant distant ne doit jamais pouvoir changer de chemin d'URL.
    static func path(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func query(_ value: String) -> String { path(value) }

    static func size(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) ?? 0 }
        return 0
    }

    static func date(_ value: Any?) -> String {
        (value as? String).map { String($0.prefix(10)) } ?? ""
    }
}

public struct GmailService: RemoteService {
    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me/messages"
    private let client: RemoteClient

    public init(client: RemoteClient) { self.client = client }

    public func list() async throws -> [RemoteItem] {
        let page = try await client.object("\(Self.base)?maxResults=100&q=\(RemoteFormat.query("larger:5M"))")
        let identifiers = (page["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        var items: [RemoteItem] = []
        for identifier in identifiers {
            try Task.checkCancellation()
            let message = try await client.object("\(Self.base)/\(RemoteFormat.path(identifier))?format=metadata&metadataHeaders=Subject&metadataHeaders=From")
            let headers = ((message["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
            func header(_ name: String) -> String? {
                headers.first { ($0["name"] as? String)?.lowercased() == name }?["value"] as? String
            }
            items.append(RemoteItem(
                id: identifier, name: header("subject") ?? "(sans objet)",
                detail: header("from") ?? "", size: RemoteFormat.size(message["sizeEstimate"])
            ))
        }
        return items.sorted { $0.size > $1.size }
    }

    public func moveToTrash(_ item: RemoteItem) async throws {
        _ = try await client.request("\(Self.base)/\(RemoteFormat.path(item.id))/trash", method: "POST")
    }
}

public struct OutlookService: RemoteService {
    private static let base = "https://graph.microsoft.com/v1.0/me"
    private static let sizeProperty = "Integer 0x0E08"
    private let client: RemoteClient

    public init(client: RemoteClient) { self.client = client }

    public func list() async throws -> [RemoteItem] {
        let expand = RemoteFormat.query("singleValueExtendedProperties($filter=id eq '\(Self.sizeProperty)')")
        let filter = RemoteFormat.query("hasAttachments eq true")
        let page = try await client.object("\(Self.base)/messages?$top=200&$select=id,subject,from,receivedDateTime&$filter=\(filter)&$expand=\(expand)")
        let items = (page["value"] as? [[String: Any]] ?? []).compactMap { message -> RemoteItem? in
            guard let identifier = message["id"] as? String else { return nil }
            let properties = message["singleValueExtendedProperties"] as? [[String: Any]]
            let sender = ((message["from"] as? [String: Any])?["emailAddress"] as? [String: Any])?["address"] as? String
            return RemoteItem(
                id: identifier, name: (message["subject"] as? String) ?? "(sans objet)",
                detail: [sender, RemoteFormat.date(message["receivedDateTime"])].compactMap { $0 }.joined(separator: " · "),
                size: RemoteFormat.size(properties?.first?["value"])
            )
        }
        return items.sorted { $0.size > $1.size }
    }

    public func moveToTrash(_ item: RemoteItem) async throws {
        _ = try await client.request(
            "\(Self.base)/messages/\(RemoteFormat.path(item.id))/move", method: "POST",
            json: ["destinationId": "deleteditems"]
        )
    }
}

public struct GoogleDriveService: RemoteService {
    private static let base = "https://www.googleapis.com/drive/v3/files"
    private let client: RemoteClient

    public init(client: RemoteClient) { self.client = client }

    public func list() async throws -> [RemoteItem] {
        let filter = RemoteFormat.query("trashed=false and 'me' in owners")
        let order = RemoteFormat.query("quotaBytesUsed desc")
        let fields = RemoteFormat.query("files(id,name,quotaBytesUsed,modifiedTime)")
        let page = try await client.object("\(Self.base)?pageSize=200&q=\(filter)&orderBy=\(order)&fields=\(fields)")
        return (page["files"] as? [[String: Any]] ?? []).compactMap { file in
            guard let identifier = file["id"] as? String else { return nil }
            return RemoteItem(
                id: identifier, name: (file["name"] as? String) ?? identifier,
                detail: "Modifié le \(RemoteFormat.date(file["modifiedTime"]))",
                size: RemoteFormat.size(file["quotaBytesUsed"])
            )
        }
    }

    public func moveToTrash(_ item: RemoteItem) async throws {
        _ = try await client.request("\(Self.base)/\(RemoteFormat.path(item.id))", method: "PATCH", json: ["trashed": true])
    }
}

public struct OneDriveService: RemoteService {
    private static let base = "https://graph.microsoft.com/v1.0/me/drive"
    private static let folderLimit = 200
    private let client: RemoteClient

    public init(client: RemoteClient) { self.client = client }

    /// Graph ne trie pas tout le lecteur par taille : parcours en largeur, borné.
    public func list() async throws -> [RemoteItem] {
        var folders = ["\(Self.base)/root/children"]
        var visited = 0
        var files: [RemoteItem] = []
        while let folder = folders.first, visited < Self.folderLimit {
            try Task.checkCancellation()
            folders.removeFirst()
            visited += 1
            let page = try await client.object("\(folder)?$top=200&$select=id,name,size,folder,file,lastModifiedDateTime")
            for entry in page["value"] as? [[String: Any]] ?? [] {
                guard let identifier = entry["id"] as? String else { continue }
                if entry["folder"] != nil {
                    folders.append("\(Self.base)/items/\(RemoteFormat.path(identifier))/children")
                } else {
                    files.append(RemoteItem(
                        id: identifier, name: (entry["name"] as? String) ?? identifier,
                        detail: "Modifié le \(RemoteFormat.date(entry["lastModifiedDateTime"]))",
                        size: RemoteFormat.size(entry["size"])
                    ))
                }
            }
        }
        return Array(files.sorted { $0.size > $1.size }.prefix(200))
    }

    public func moveToTrash(_ item: RemoteItem) async throws {
        _ = try await client.request("\(Self.base)/items/\(RemoteFormat.path(item.id))", method: "DELETE")
    }
}

public struct DropboxService: RemoteService {
    private static let base = "https://api.dropboxapi.com/2/files"
    private static let pageLimit = 50
    private let client: RemoteClient

    public init(client: RemoteClient) { self.client = client }

    public func list() async throws -> [RemoteItem] {
        var page = try await client.object("\(Self.base)/list_folder", method: "POST", json: ["path": "", "recursive": true, "limit": 2000])
        var entries = page["entries"] as? [[String: Any]] ?? []
        var pages = 1
        while page["has_more"] as? Bool == true, let cursor = page["cursor"] as? String, pages < Self.pageLimit {
            try Task.checkCancellation()
            page = try await client.object("\(Self.base)/list_folder/continue", method: "POST", json: ["cursor": cursor])
            entries += page["entries"] as? [[String: Any]] ?? []
            pages += 1
        }
        let files = entries.compactMap { entry -> RemoteItem? in
            guard entry[".tag"] as? String == "file", let path = entry["path_lower"] as? String else { return nil }
            return RemoteItem(
                id: path, name: (entry["name"] as? String) ?? path,
                detail: (entry["path_display"] as? String) ?? path, size: RemoteFormat.size(entry["size"])
            )
        }
        return Array(files.sorted { $0.size > $1.size }.prefix(200))
    }

    public func moveToTrash(_ item: RemoteItem) async throws {
        _ = try await client.request("\(Self.base)/delete_v2", method: "POST", json: ["path": item.id])
    }
}

public enum RemoteServices {
    public static func make(_ provider: RemoteProvider, client: RemoteClient) -> any RemoteService {
        switch provider {
        case .gmail: GmailService(client: client)
        case .outlook: OutlookService(client: client)
        case .googleDrive: GoogleDriveService(client: client)
        case .oneDrive: OneDriveService(client: client)
        case .dropbox: DropboxService(client: client)
        }
    }
}
