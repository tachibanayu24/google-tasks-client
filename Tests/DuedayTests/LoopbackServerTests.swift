import Foundation
import Testing
@testable import Dueday

@Suite struct LoopbackServerTests {
    /// Opens a raw TCP connection to 127.0.0.1:port and sends `chunks` with a pause between them.
    private func connect(_ port: UInt16, send chunks: [String], pause: TimeInterval = 0.05, close shouldClose: Bool = true) -> Int32 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = port.bigEndian
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        for chunk in chunks {
            _ = chunk.withCString { write(sock, $0, strlen($0)) }
            Thread.sleep(forTimeInterval: pause)
        }
        if shouldClose { close(sock) }
        return sock
    }

    private func status(_ port: UInt16, _ path: String) async throws -> Int {
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        return (response as! HTTPURLResponse).statusCode
    }

    @Test func acceptsOnlyTheRedirectWithOurState() async throws {
        let server = LoopbackServer(expectedState: "s3cret")
        let port = try server.start()
        #expect(try await status(port, "/favicon.ico") == 404)
        #expect(try await status(port, "/?code=evil&state=wrong") == 404)
        #expect(try await status(port, "/?code=abc&state=s3cret&scope=x") == 200)
        let params = try await server.waitForRedirect()
        #expect(params["code"] == "abc")
    }

    @Test func survivesSilentAndSplitConnections() async throws {
        let server = LoopbackServer(expectedState: "st")
        let port = try server.start()
        // A speculative connection that never sends anything, left open.
        let idle = connect(port, send: [], close: false)
        defer { close(idle) }
        // The real request, arriving in pieces.
        DispatchQueue.global().async {
            _ = connect(port, send: ["GET /?code=12", "34&state=st HT", "TP/1.1\r\nHost: x\r\n\r\n"])
        }
        let params = try await server.waitForRedirect()
        #expect(params["code"] == "1234")
    }

    @Test func cancellingEndsTheWait() async throws {
        let server = LoopbackServer(expectedState: "st")
        _ = try server.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { server.cancel() }
        await #expect(throws: AuthError.self) { try await server.waitForRedirect() }
    }
}
