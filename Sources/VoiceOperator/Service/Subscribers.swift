import Foundation

/// A local app that asked to hear from Voice Operator: where to send, and what.
///
/// Voice Operator knows no client by name. A client registers itself over the
/// loopback API (`PUT /v1/subscribers/<name>`) with a Unix socket that takes
/// newline-delimited JSON, and says what it wants there:
///
/// - `commands`: the transcript of every command dictation (Ctrl+Fn), as
///   `{"type":"voice-command","text":"…"}`. One subscriber gets them — the one
///   that registered for them most recently.
/// - `events: ["dictation"]`: `{"type":"voice-dictation","active":…,"launch":…,"seq":…}`
///   as each dictation starts and ends (and `false` at launch).
///
/// Registrations are saved, so they outlive restarts of Voice Operator; a client
/// re-registers whenever it starts, which is harmless and keeps the socket path
/// current.
struct Subscriber: Codable, Equatable, Sendable {
    static let events: Set<String> = ["dictation"]

    var name: String
    var socket: String
    var commands: Bool
    var events: [String]
    var registered: Date

    enum Rejection: Error, Equatable {
        case invalidName, invalidBody, invalidSocket, unknownEvent(String)

        var object: [String: Any] {
            switch self {
            case .invalidName: return ["error": "invalid_name", "detail": "1–64 of a-z, 0-9, - and _"]
            case .invalidBody: return ["error": "invalid_body"]
            case .invalidSocket: return ["error": "invalid_socket", "detail": "an absolute path under 104 bytes"]
            case .unknownEvent(let event): return ["error": "unknown_event", "event": event]
            }
        }
    }

    /// The registration a `PUT /v1/subscribers/<name>` body asks for.
    static func parse(name: String, body: Data, now: Date = Date()) -> Result<Subscriber, Rejection> {
        guard (1...64).contains(name.count),
              name.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return .failure(.invalidName)
        }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .failure(.invalidBody)
        }
        // sockaddr_un.sun_path is 104 bytes, NUL included.
        guard let socket = object["socket"] as? String, socket.hasPrefix("/"), socket.utf8.count < 104 else {
            return .failure(.invalidSocket)
        }
        let events = object["events"] as? [String] ?? []
        if let unknown = events.first(where: { !Self.events.contains($0) }) { return .failure(.unknownEvent(unknown)) }
        return .success(Subscriber(name: name, socket: socket, commands: object["commands"] as? Bool ?? false,
                                   events: events, registered: now))
    }

    var object: [String: Any] {
        ["name": name, "socket": socket, "commands": commands, "events": events,
         "registered": ISO8601DateFormatter().string(from: registered)]
    }
}

/// The saved registrations (`subscribers.json` in Application Support).
final class SubscriberRegistry: @unchecked Sendable {
    static let shared = SubscriberRegistry(file: HistoryStore.supportDir.appendingPathComponent("subscribers.json"))

    private let file: URL
    private let lock = NSLock()
    private var subscribers: [Subscriber]

    init(file: URL) {
        self.file = file
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        subscribers = (try? Data(contentsOf: file)).flatMap { try? decoder.decode([Subscriber].self, from: $0) } ?? []
    }

    var all: [Subscriber] { lock.withLock { subscribers } }

    /// Who gets command dictations: the latest to register for them.
    var commandRoute: Subscriber? {
        lock.withLock { subscribers.filter(\.commands).max { $0.registered < $1.registered } }
    }

    func subscribers(to event: String) -> [Subscriber] {
        lock.withLock { subscribers.filter { $0.events.contains(event) } }
    }

    /// Add or replace (by name) a registration, and save.
    func register(_ subscriber: Subscriber) throws {
        try lock.withLock {
            subscribers.removeAll { $0.name == subscriber.name }
            subscribers.append(subscriber)
            try save()
        }
        Log.log("subscribers: \(subscriber.name) registered — socket \(subscriber.socket), "
                + "commands \(subscriber.commands), events \(subscriber.events)")
    }

    /// Remove a registration. False when there was none by that name.
    func unregister(_ name: String) throws -> Bool {
        let removed = try lock.withLock {
            let before = subscribers.count
            subscribers.removeAll { $0.name == name }
            guard subscribers.count != before else { return false }
            try save()
            return true
        }
        if removed { Log.log("subscribers: \(name) unregistered") }
        return removed
    }

    /// Caller holds `lock`.
    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(subscribers).write(to: file, options: .atomic)
    }
}

/// Delivers messages to subscribers' sockets: fire-and-forget, one connection
/// per message, newline-delimited JSON.
enum SubscriberSocket {
    /// Serial, so messages leave in the order they were sent.
    private static let queue = DispatchQueue(label: "com.voiceop.subscriber-socket")
    /// Names this process to subscribers, which start counting `dictationSeq` again when it changes.
    private static let launch = UUID().uuidString
    /// Touched only on `queue`.
    nonisolated(unsafe) private static var dictationSeq = 0

    /// Send a command dictation to the command route. `completion(false)` when
    /// nobody registered for commands, or they could not be reached.
    static func voiceCommand(_ text: String, registry: SubscriberRegistry = .shared,
                             completion: @escaping @Sendable (_ delivered: Bool, _ to: String?) -> Void) {
        guard let route = registry.commandRoute else { completion(false, nil); return }
        send(["type": "voice-command", "text": text], to: route.socket) { completion($0, route.name) }
    }

    /// Tell subscribers a dictation started or ended, so none of them speaks or
    /// prepares anything to say while the user is talking. Sent `false` at
    /// launch too, which clears a dictation an earlier process never ended.
    /// Each report is numbered: they travel on separate connections, and a
    /// subscriber drops one older than a report it already has.
    static func dictation(active: Bool, registry: SubscriberRegistry = .shared) {
        let targets = registry.subscribers(to: "dictation")
        guard !targets.isEmpty else { return }
        queue.async {
            dictationSeq += 1
            let message: [String: Any] = ["type": "voice-dictation", "active": active, "launch": launch, "seq": dictationSeq]
            for target in targets {
                send(message, to: target.socket) { ok in
                    if !ok { Log.log("subscribers: could not tell \(target.name) dictation \(active ? "started" : "ended")") }
                }
            }
        }
    }

    static func send(_ message: [String: Any], to path: String, completion: @escaping @Sendable (Bool) -> Void) {
        guard let payload = try? JSONSerialization.data(withJSONObject: message) else { completion(false); return }
        queue.async {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { completion(false); return }
            defer { close(fd) }
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: addr.sun_path)
            _ = path.withCString { src in
                withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: capacity) { strncpy($0, src, capacity - 1) } }
            }
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard ok == 0 else { completion(false); return }
            var line = payload; line.append(0x0A)
            let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            shutdown(fd, SHUT_WR)
            completion(written == line.count)
        }
    }
}
