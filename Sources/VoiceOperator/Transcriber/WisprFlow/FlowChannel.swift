import Foundation
import GRPC
import NIOCore
import NIOPosix
import FlowAPI

/// The process-wide, permanently warm gRPC connection to Wispr's Baseten
/// transcription replica.
///
/// This exists because the previous code built a fresh `MultiThreadedEventLoopGroup`
/// and `GRPCChannelPool` for **every** transcription and tore both down again, so
/// each dictation paid DNS + TCP + TLS + HTTP/2 preface before a single audio byte
/// moved. Wispr Flow instead caches one client for the life of the app
/// (`ensureClient` in the app bundle) and holds the connection open with keepalive
/// pings, so by the time you press the trigger key the socket is already there.
/// We mirror that configuration:
///
///   grpc.keepalive_time_ms                     4000  → `keepalive.interval`
///   grpc.keepalive_timeout_ms                  2000  → `keepalive.timeout`
///   grpc.keepalive_permit_without_calls           1  → `permitWithoutCalls`
///   grpc.http2.max_pings_without_data             0  → `maximumPingsWithoutData`
///
/// The last one needs translating rather than copying: in gRPC's C core `0` means
/// *unlimited* pings while idle, but grpc-swift reads the field literally and
/// blocks once `sentPingsWithoutData` exceeds it. `.max` is the faithful
/// equivalent. Likewise `minimumSentPingIntervalWithoutData` must sit strictly
/// below `interval`, or grpc-swift silently suppresses the very pings we asked
/// for; Wispr sets both to 4 s, we use 3 s so no ping is ever dropped to jitter.
///
/// `minConnectionsPerEventLoop = 1` is what actually keeps us warm: the pool marks
/// that connection `neverGoIdle` and dials it as soon as the channel is created,
/// so `warmUp()` at launch is enough to have TLS finished long before the first
/// dictation.
final class FlowChannel: @unchecked Sendable {
    static let shared = FlowChannel()

    /// Wispr's default production model (`Rt.RT` in the app bundle, and a member
    /// of its dictation-URL allowlist). Confirmed current — not a stale replica.
    static let modelId = "v31pl413"
    static let host = "model-\(modelId).grpc.api.baseten.co"

    private let lock = NSLock()
    private var group: MultiThreadedEventLoopGroup?
    private var channel: GRPCChannel?

    private init() {}

    /// A client on the shared warm channel. Cheap: the client is a struct wrapping
    /// the channel, so this allocates nothing meaningful per call.
    func client() throws -> FlowApi_V1_TranscriptionServiceAsyncClient {
        FlowApi_V1_TranscriptionServiceAsyncClient(channel: try sharedChannel())
    }

    /// Establish the connection ahead of time. Called at launch and again when a
    /// dictation starts, so a connection dropped while the Mac was asleep is
    /// already redialling before the user finishes their first word.
    func warmUp() {
        do {
            _ = try sharedChannel()
        } catch {
            Log.log("flow: channel warm-up failed: \(error)")
        }
    }

    private func sharedChannel() throws -> GRPCChannel {
        lock.lock(); defer { lock.unlock() }
        if let channel { return channel }

        let group = self.group ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let channel = try GRPCChannelPool.with(
            target: .host(Self.host, port: 443),
            transportSecurity: .tls(.makeClientDefault(compatibleWith: group)),
            eventLoopGroup: group
        ) { config in
            config.keepalive = ClientConnectionKeepalive(
                interval: .seconds(4),
                timeout: .seconds(2),
                permitWithoutCalls: true,
                maximumPingsWithoutData: .max,
                minimumSentPingIntervalWithoutData: .seconds(3))
            // Keep one connection dialled and never let it idle out.
            config.connectionPool.minConnectionsPerEventLoop = 1
            config.idleTimeout = .hours(24)
            // A dictation is worthless if it has to wait 20 s to redial, so fail
            // fast and let the /llm/asr fallback take over instead.
            config.connectionBackoff = ConnectionBackoff(
                initialBackoff: 0.2, maximumBackoff: 10, multiplier: 1.6,
                minimumConnectionTimeout: 5)
            // A dictation must never queue behind a stale waiter.
            config.connectionPool.maxWaitTime = .seconds(5)
        }
        self.channel = channel
        Log.log("flow: opened warm gRPC channel to \(Self.host)")
        return channel
    }
}
