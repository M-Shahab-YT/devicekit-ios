import Foundation
import Network

/// TCP server that serves a `RingStream` with a resumable handshake.
///
/// Handshake (16 bytes, big-endian):
///   "GRS1" | mode u8 | pad[3] | offset u64
/// Reply (16 bytes):
///   "GRA1" | status u8 | pad[3] | start u64
///
/// mode 0 = LIVE (start at current end), mode 1 = RESUME (replay from offset).
/// status 1 = RESET (requested offset older than the ring; start = ringStart).
///
/// A connection only becomes active after a valid handshake, so stray probes
/// cannot steal the live stream.
final class RingServer {
    private let port: UInt16
    private let ring: RingStream
    private let queue = DispatchQueue(label: "ring.server")
    private let lock = NSLock()

    private var listener: NWListener?
    private var pending: NWConnection?
    private var active: NWConnection?

    init(port: UInt16, ring: RingStream) {
        self.port = port
        self.ring = ring
    }

    func start() throws {
        listener?.cancel()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "RingServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid port"])
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)

        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                print("[RingServer] listening on \(self.port)")
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        pending?.cancel()
        pending = nil
        active?.cancel()
        active = nil
        lock.unlock()
        ring.stopConsumer()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        pending?.cancel()
        pending = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.readHello(connection)
            case .failed, .cancelled:
                self?.cleanup(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.pending === connection {
                connection.cancel()
            }
            self.lock.unlock()
        }
    }

    private func readHello(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 16, maximumLength: 16) { [weak self] data, _, _, error in
            guard let self else { return }
            guard
                error == nil,
                let data = data,
                data.count == 16,
                String(data: data.prefix(4), encoding: .ascii) == "GRS1"
            else {
                connection.cancel()
                return
            }

            let mode = data[4]
            var offset: UInt64 = 0
            for byte in data[8..<16] {
                offset = (offset << 8) | UInt64(byte)
            }

            let ringStart = self.ring.ringStart
            let total = self.ring.totalWritten
            var start = total
            var status: UInt8 = 0
            if mode == 1 {
                if offset < ringStart {
                    start = ringStart
                    status = 1
                } else {
                    start = min(offset, total)
                }
            }

            var ack = Data("GRA1".utf8)
            ack.append(status)
            ack.append(contentsOf: [0, 0, 0])
            for shift in stride(from: 56, through: 0, by: -8) {
                ack.append(UInt8((start >> UInt64(shift)) & 0xff))
            }

            // Promote this connection to the active consumer.
            self.lock.lock()
            if self.pending === connection {
                self.pending = nil
            }
            let previous = self.active
            self.active = connection
            self.lock.unlock()

            previous?.cancel()

            connection.send(content: ack, completion: .contentProcessed { _ in })
            self.ring.attach(connection, from: start)
            NSLog("[RingServer] port \(self.port) client attached mode=\(mode) start=\(start) status=\(status)")
        }
    }

    private func cleanup(_ connection: NWConnection) {
        lock.lock()
        if pending === connection {
            pending = nil
        }
        if active === connection {
            active = nil
            ring.detach(connection)
        }
        lock.unlock()
    }
}
