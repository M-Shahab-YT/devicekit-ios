import Foundation
import Network

/// Disk-backed, append-only, resumable byte stream.
///
/// Encoded bytes are written to rotating segment files and kept for a bounded
/// window (time/size). A single consumer can attach at any byte offset still
/// inside the window; it receives everything from that offset and then follows
/// live. This lets the PC reconnect after a USB drop and replay the gap from
/// the phone's disk instead of losing footage.
final class RingStream {
    private struct Segment {
        let start: UInt64
        let url: URL
        var length: UInt64
    }

    private let directory: URL
    private let maxBytes: UInt64
    private let segmentBytes: UInt64
    private let lock = NSLock()

    private var segments: [Segment] = []
    private var current: FileHandle?
    private var globalEnd: UInt64 = 0
    private var currentLength: UInt64 = 0
    private var nextIndex = 0

    private var consumer: NWConnection?
    private var consumerOffset: UInt64 = 0
    private var sending = false

    var totalWritten: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return globalEnd
    }

    var ringStart: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return segments.first?.start ?? globalEnd
    }

    var bufferedBytes: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return globalEnd - (segments.first?.start ?? globalEnd)
    }

    init(
        directory: URL,
        maxBytes: UInt64 = 2_000_000_000,
        segmentBytes: UInt64 = 8_000_000
    ) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.segmentBytes = segmentBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reset()
    }

    /// Clears the ring (new broadcast session).
    func reset() {
        lock.lock()
        try? current?.close()
        current = nil
        for seg in segments {
            try? FileManager.default.removeItem(at: seg.url)
        }
        segments.removeAll()
        globalEnd = 0
        currentLength = 0
        nextIndex = 0
        consumer?.cancel()
        consumer = nil
        consumerOffset = 0
        sending = false
        openSegmentLocked()
        lock.unlock()
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard let handle = current else {
            lock.unlock()
            return
        }
        handle.write(data)
        currentLength += UInt64(data.count)
        globalEnd += UInt64(data.count)
        if !segments.isEmpty {
            segments[segments.count - 1].length = currentLength
        }
        if currentLength >= segmentBytes {
            openSegmentLocked()
        }
        trimLocked()
        pumpLocked()
        lock.unlock()
    }

    func attach(_ connection: NWConnection, from offset: UInt64) {
        lock.lock()
        consumer?.cancel()
        consumer = connection
        consumerOffset = min(offset, globalEnd)
        sending = false
        pumpLocked()
        lock.unlock()
    }

    func detach(_ connection: NWConnection?) {
        lock.lock()
        if let connection = connection {
            if consumer === connection {
                consumer = nil
                sending = false
            }
        } else {
            consumer = nil
            sending = false
        }
        lock.unlock()
    }

    func stopConsumer() {
        lock.lock()
        consumer?.cancel()
        consumer = nil
        sending = false
        lock.unlock()
    }

    // MARK: - Private (all called with `lock` held)

    private func openSegmentLocked() {
        try? current?.close()
        nextIndex += 1
        var url = directory.appendingPathComponent(String(format: "seg_%06d.bin", nextIndex))
        FileManager.default.createFile(atPath: url.path, contents: nil)
        var handle = try? FileHandle(forWritingTo: url)
        if handle == nil {
            // The app-support container can be unavailable in some extension
            // contexts; fall back to the temporary directory rather than
            // silently dropping frames.
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent(String(format: "dkring_%06d.bin", nextIndex))
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
        }
        guard let handle = handle else {
            current = nil
            return
        }
        // Keep the ring readable if the device is locked while replaying.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        current = handle
        currentLength = 0
        segments.append(Segment(start: globalEnd, url: url, length: 0))
    }

    private func trimLocked() {
        var total = segments.reduce(UInt64(0)) { $0 + $1.length }
        while total > maxBytes && segments.count > 1 {
            let removed = segments.removeFirst()
            total -= removed.length
            try? FileManager.default.removeItem(at: removed.url)
        }
        // If the consumer fell behind the retained window, force a reconnect so
        // it can handshake again and receive a RESET at ringStart.
        if let first = segments.first, let connection = consumer, consumerOffset < first.start {
            connection.cancel()
            consumer = nil
            sending = false
        }
    }

    private func pumpLocked() {
        guard let connection = consumer, !sending, consumerOffset < globalEnd else {
            return
        }
        guard let chunk = readLocked(at: consumerOffset, max: 256 * 1024), !chunk.isEmpty else {
            return
        }
        sending = true
        let advance = UInt64(chunk.count)
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            self.sending = false
            if error != nil {
                if self.consumer === connection {
                    self.consumer = nil
                }
            } else {
                self.consumerOffset += advance
                self.pumpLocked()
            }
            self.lock.unlock()
        })
    }

    private func readLocked(at offset: UInt64, max: Int) -> Data? {
        guard let segment = segments.first(where: { offset >= $0.start && offset < $0.start + $0.length }) else {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: segment.url) else {
            return nil
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset - segment.start)
            let available = segment.length - (offset - segment.start)
            let count = min(UInt64(max), available)
            return try handle.read(upToCount: Int(count))
        } catch {
            return nil
        }
    }
}
