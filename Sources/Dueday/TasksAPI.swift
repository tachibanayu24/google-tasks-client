import Foundation

struct TaskList: Codable, Identifiable, Equatable {
    var id: String
    var title: String
}

/// A Google Tasks task. Only what the API can actually read and write is modelled: no due time, no repeat,
/// no stars. `due` is a date (the API drops the time part).
struct TaskItem: Codable, Identifiable, Equatable {
    var id: String
    var title: String?
    var notes: String?
    var status: String?
    var due: String?
    var completed: String?
    var parent: String?
    var position: String?
    var hidden: Bool?
    var deleted: Bool?
    var webViewLink: String?
    var links: [Link]?

    struct Link: Codable, Equatable, Hashable {
        var type: String?
        var description: String?
        var link: String?
    }

    var isCompleted: Bool { status == "completed" }

    /// The calendar date of `due`, read in UTC (it is always stored as midnight UTC).
    var dueDate: Date? {
        guard let due, let day = Self.dueParser.date(from: String(due.prefix(10))) else { return nil }
        return Calendar.current.date(from: Self.utc.dateComponents([.year, .month, .day], from: day))
    }

    var completedDate: Date? {
        guard let completed else { return nil }
        return ISO8601DateFormatter.withFractions.date(from: completed) ?? ISO8601DateFormatter().date(from: completed)
    }

    static func dueString(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02dT00:00:00.000Z", c.year!, c.month!, c.day!)
    }

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let dueParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = utc
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func nowString() -> String { withFractions.string(from: Date()) }
}

struct APIError: LocalizedError {
    var status: Int
    var message: String
    var errorDescription: String? { message }
}

/// Thin async wrapper over https://tasks.googleapis.com/tasks/v1.
@MainActor
struct TasksAPI {
    let auth: GoogleAuth
    private let base = URL(string: "https://tasks.googleapis.com/tasks/v1/")!

    private struct Page<T: Decodable>: Decodable {
        var items: [T]?
        var nextPageToken: String?
    }

    // MARK: Lists

    func lists() async throws -> [TaskList] {
        try await paged("users/@me/lists", query: [.init(name: "maxResults", value: "100")])
    }

    func createList(title: String) async throws -> TaskList {
        try await decode(send("POST", "users/@me/lists", body: ["title": title]))
    }

    func renameList(_ id: String, title: String) async throws {
        _ = try await send("PATCH", "users/@me/lists/\(id.pathEscaped)", body: ["title": title])
    }

    func deleteList(_ id: String) async throws {
        _ = try await send("DELETE", "users/@me/lists/\(id.pathEscaped)")
    }

    // MARK: Tasks

    /// Every task in a list. Completed tasks are included; tasks completed in Google's own apps come back
    /// hidden, so hidden ones are requested too.
    func tasks(in list: String) async throws -> [TaskItem] {
        try await paged("lists/\(list.pathEscaped)/tasks", query: [
            .init(name: "maxResults", value: "100"),
            .init(name: "showCompleted", value: "true"),
            .init(name: "showHidden", value: "true"),
        ])
    }

    func insertTask(in list: String, fields: [String: Any], parent: String?, previous: String?) async throws -> TaskItem {
        var query: [URLQueryItem] = []
        if let parent { query.append(.init(name: "parent", value: parent)) }
        if let previous { query.append(.init(name: "previous", value: previous)) }
        return try await decode(send("POST", "lists/\(list.pathEscaped)/tasks", query: query, body: fields))
    }

    /// `NSNull()` values clear a field (e.g. `due`, `completed`).
    func patchTask(in list: String, id: String, fields: [String: Any]) async throws -> TaskItem {
        try await decode(send("PATCH", "lists/\(list.pathEscaped)/tasks/\(id.pathEscaped)", body: fields))
    }

    func deleteTask(in list: String, id: String) async throws {
        _ = try await send("DELETE", "lists/\(list.pathEscaped)/tasks/\(id.pathEscaped)")
    }

    func moveTask(in list: String, id: String, parent: String?, previous: String?, toList: String? = nil) async throws -> TaskItem {
        var query: [URLQueryItem] = []
        if let parent { query.append(.init(name: "parent", value: parent)) }
        if let previous { query.append(.init(name: "previous", value: previous)) }
        if let toList { query.append(.init(name: "destinationTasklist", value: toList)) }
        return try await decode(send("POST", "lists/\(list.pathEscaped)/tasks/\(id.pathEscaped)/move", query: query))
    }

    // MARK: Transport

    private func paged<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> [T] {
        var all: [T] = []
        var token: String?
        repeat {
            var q = query
            if let token { q.append(.init(name: "pageToken", value: token)) }
            let page: Page<T> = try await decode(send("GET", path, query: q))
            all += page.items ?? []
            token = page.nextPageToken
        } while token != nil
        return all
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                      retrying: Bool = false) async throws -> Data {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        // appendingPathComponent would escape the "@" in "@me"; set the already-escaped path directly.
        components.percentEncodedPath = base.path + "/" + path
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue("Bearer \(try await auth.validAccessToken(forceRefresh: retrying))", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, !retrying {
            return try await send(method, path, query: query, body: body, retrying: true)
        }
        guard (200..<300).contains(status) else {
            struct Envelope: Decodable {
                struct Inner: Decodable { var message: String? }
                var error: Inner?
            }
            let message = (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message
            throw APIError(status: status, message: message ?? "Google Tasks returned HTTP \(status).")
        }
        return data
    }
}

private extension String {
    var pathEscaped: String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
