import Foundation
import CoreGraphics

struct WindowMotionPlan {
    let from: [Int: CGPoint]
    let to: [Int: CGPoint]
    let startTime: Double
    let duration: Double

    init(from: [Int: CGPoint], to: [Int: CGPoint], startTime: Double, duration: Double) {
        self.to = to.filter { $0.value.x.isFinite && $0.value.y.isFinite }
        self.from = self.to.mapValues { $0 }
            .merging(from.filter { $0.value.x.isFinite && $0.value.y.isFinite }) { _, start in start }
        self.startTime = startTime.isFinite ? startTime : 0
        // A malformed preference must not create an animation that never finishes.
        self.duration = duration.isFinite ? min(1, max(0, duration)) : 0
    }

    func isFinished(at time: Double) -> Bool {
        !time.isFinite || duration == 0 || time - startTime >= duration
    }

    func sample(at time: Double) -> [Int: CGPoint] {
        if isFinished(at: time) { return to }
        let progress = min(1, max(0, (time - startTime) / duration))
        let eased = CGFloat(progress * progress * (3 - 2 * progress))
        return to.map { id, destination in
            let origin = from[id] ?? destination
            // Weighted endpoints avoid overflowing destination-origin for distant
            // but finite coordinates. The final sample returns targets verbatim.
            return (id, CGPoint(x: origin.x * (1 - eased) + destination.x * eased,
                                y: origin.y * (1 - eased) + destination.y * eased))
        }.reduce(into: [:]) { $0[$1.0] = $1.1 }
    }
}

/// Serial blocking writes with one replaceable pending batch. This class never
/// calls AX or AppKit; its write closure must impose its own IPC timeout.
/// Completion runs on the writer queue. UI callbacks must also check their
/// service generation before applying a result dispatched back to the main queue.
final class CoalescingWindowMotionWriter: @unchecked Sendable {
    struct Stats: Sendable {
        let positions: [Int: CGPoint]
        let successfulWrites: Int
        let failedWrites: Int
        let skippedWrites: Int
        let elapsed: Double
        let isCancelled: Bool
        let firstWriteDelay: Double
        let maxWriteDuration: Double
    }

    private struct Batch {
        let positions: [Int: CGPoint]
        let isFinal: Bool
    }

    private let queue = DispatchQueue(label: "Macarchy.WindowMotion", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private let write: (Int, CGPoint) -> Bool
    private let completion: (Stats) -> Void
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var finishedAt: Double?
    private var positions: [Int: CGPoint]
    private var successfulWrites = 0
    private var failedWrites = 0
    private var skippedWrites = 0
    private var firstWriteStartedAt: Double?
    private var maxWriteDuration = 0.0
    private var pending: Batch?
    private var draining = false
    private var cancelled = false
    private var finalSubmitted = false
    private var completed = false

    init(initialPositions: [Int: CGPoint], write: @escaping (Int, CGPoint) -> Bool,
         completion: @escaping (Stats) -> Void) {
        positions = initialPositions.filter { $0.value.x.isFinite && $0.value.y.isFinite }
        self.write = write
        self.completion = completion
        queue.setSpecific(key: queueKey, value: 1)
    }

    func submit(positions: [Int: CGPoint], isFinal: Bool) {
        lock.lock()
        guard !cancelled, !completed, !finalSubmitted else { lock.unlock(); return }
        let valid = positions.filter { $0.value.x.isFinite && $0.value.y.isFinite }
        failedWrites += positions.count - valid.count
        pending = Batch(positions: valid, isFinal: isFinal)
        finalSubmitted = isFinal
        let shouldStart = !draining
        draining = true
        lock.unlock()
        if shouldStart { queue.async { self.drain() } }
    }

    /// Cancellation cannot preempt a write already inside another process.
    /// Wait for that one write/callback to leave the serial queue before restoring
    /// windows. After this returns, this worker can issue no further writes.
    /// Call from outside the write/completion queue.
    @discardableResult
    func cancelAndWait() -> Stats {
        precondition(DispatchQueue.getSpecific(key: queueKey) == nil,
                     "cancelAndWait must be called outside the motion writer queue")
        lock.lock()
        cancelled = true
        pending = nil
        lock.unlock()
        queue.sync { }
        lock.lock()
        if finishedAt == nil { finishedAt = ProcessInfo.processInfo.systemUptime }
        let result = statsLocked()
        lock.unlock()
        return result
    }

    func snapshot() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return statsLocked()
    }

    private func statsLocked() -> Stats {
        Stats(positions: positions, successfulWrites: successfulWrites, failedWrites: failedWrites,
              skippedWrites: skippedWrites, elapsed: max(0, (finishedAt ?? ProcessInfo.processInfo.systemUptime) - startedAt),
              isCancelled: cancelled, firstWriteDelay: firstWriteStartedAt.map { max(0, $0 - startedAt) } ?? 0,
              maxWriteDuration: maxWriteDuration)
    }

    private func drain() {
        while true {
            lock.lock()
            guard !cancelled, let batch = pending else {
                pending = nil
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            for id in batch.positions.keys.sorted() {
                lock.lock()
                // Stop an obsolete batch before its next window. New samples
                // replace pending work rather than building a queue of AX bursts.
                guard !cancelled, pending == nil else { lock.unlock(); break }
                let target = batch.positions[id]!
                if positions[id] == target {
                    skippedWrites += 1
                    lock.unlock()
                    continue
                }
                lock.unlock()

                let writeStartedAt = ProcessInfo.processInfo.systemUptime
                let succeeded = write(id, target)
                let writeDuration = max(0, ProcessInfo.processInfo.systemUptime - writeStartedAt)
                lock.lock()
                if firstWriteStartedAt == nil { firstWriteStartedAt = writeStartedAt }
                maxWriteDuration = max(maxWriteDuration, writeDuration)
                if succeeded { positions[id] = target; successfulWrites += 1 }
                else { failedWrites += 1 }
                lock.unlock()
            }

            lock.lock()
            if batch.isFinal && !cancelled {
                completed = true
                draining = false
                finishedAt = ProcessInfo.processInfo.systemUptime
                let result = statsLocked()
                lock.unlock()
                completion(result)
                return
            }
            lock.unlock()
        }
    }
}
