import XCTest
@testable import VoiceOperator

final class SubscriberTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        // Short: a Unix socket path must fit in 104 bytes.
        dir = URL(fileURLWithPath: "/tmp/vo-sub-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func body(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    // MARK: - Parsing

    func testParsesARegistration() throws {
        let parsed = try Subscriber.parse(name: "spaceterm",
                                          body: body(["socket": "/Users/x/.spaceterm/hooks.sock", "commands": true, "events": ["dictation"]])).get()
        XCTAssertEqual(parsed.socket, "/Users/x/.spaceterm/hooks.sock")
        XCTAssertTrue(parsed.commands)
        XCTAssertEqual(parsed.events, ["dictation"])
    }

    func testRejectsBadRegistrations() {
        XCTAssertEqual(Subscriber.parse(name: "Space Term", body: body(["socket": "/a"])).failure, .invalidName)
        XCTAssertEqual(Subscriber.parse(name: "x", body: Data("nope".utf8)).failure, .invalidBody)
        XCTAssertEqual(Subscriber.parse(name: "x", body: body(["socket": "relative.sock"])).failure, .invalidSocket)
        XCTAssertEqual(Subscriber.parse(name: "x", body: body(["socket": "/" + String(repeating: "a", count: 110)])).failure, .invalidSocket)
        XCTAssertEqual(Subscriber.parse(name: "x", body: body(["socket": "/a", "events": ["typing"]])).failure, .unknownEvent("typing"))
    }

    // MARK: - Registry

    func testRegistrationsPersistAndReplaceByName() throws {
        let file = dir.appendingPathComponent("subscribers.json")
        let registry = SubscriberRegistry(file: file)
        try registry.register(Subscriber(name: "a", socket: "/a", commands: true, events: [], registered: Date(timeIntervalSince1970: 1)))
        try registry.register(Subscriber(name: "a", socket: "/a2", commands: true, events: ["dictation"], registered: Date(timeIntervalSince1970: 2)))

        let reloaded = SubscriberRegistry(file: file)
        XCTAssertEqual(reloaded.all.map(\.socket), ["/a2"])
        XCTAssertEqual(reloaded.subscribers(to: "dictation").map(\.name), ["a"])
        XCTAssertTrue(try reloaded.unregister("a"))
        XCTAssertFalse(try reloaded.unregister("a"))
        XCTAssertTrue(SubscriberRegistry(file: file).all.isEmpty)
    }

    func testLatestCommandRegistrationWins() throws {
        let registry = SubscriberRegistry(file: dir.appendingPathComponent("subscribers.json"))
        XCTAssertNil(registry.commandRoute)
        try registry.register(Subscriber(name: "old", socket: "/old", commands: true, events: [], registered: Date(timeIntervalSince1970: 1)))
        try registry.register(Subscriber(name: "listener", socket: "/l", commands: false, events: ["dictation"], registered: Date(timeIntervalSince1970: 3)))
        try registry.register(Subscriber(name: "new", socket: "/new", commands: true, events: [], registered: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(registry.commandRoute?.name, "new")
    }

    // MARK: - Delivery

    func testCommandReachesTheRegisteredSocket() throws {
        let socketPath = dir.appendingPathComponent("s.sock").path
        let listener = try UnixListener(path: socketPath)
        let registry = SubscriberRegistry(file: dir.appendingPathComponent("subscribers.json"))
        try registry.register(Subscriber(name: "client", socket: socketPath, commands: true, events: ["dictation"], registered: Date()))

        let delivered = expectation(description: "delivered")
        SubscriberSocket.voiceCommand("open the door", registry: registry) { ok, route in
            XCTAssertTrue(ok); XCTAssertEqual(route, "client"); delivered.fulfill()
        }
        wait(for: [delivered], timeout: 5)
        let line = try XCTUnwrap(listener.acceptLine())
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(message["type"] as? String, "voice-command")
        XCTAssertEqual(message["text"] as? String, "open the door")
    }

    func testNoCommandRouteReportsUndelivered() {
        let registry = SubscriberRegistry(file: dir.appendingPathComponent("subscribers.json"))
        let done = expectation(description: "done")
        SubscriberSocket.voiceCommand("hello", registry: registry) { ok, route in
            XCTAssertFalse(ok); XCTAssertNil(route); done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let f) = self { return f }; return nil }
}

/// A one-shot Unix socket server for the delivery tests.
private final class UnixListener {
    private let fd: Int32
    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: capacity) { strncpy($0, src, capacity - 1) } }
        }
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(fd, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
    }
    deinit { close(fd) }

    func acceptLine() -> String? {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return nil }
        defer { close(client) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
