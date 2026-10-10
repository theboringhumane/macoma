import Foundation
import CoreGraphics

private final class MotionWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(Int, CGPoint)] = []
    private var completions = 0

    func record(_ id: Int, _ point: CGPoint) {
        lock.lock(); events.append((id, point)); lock.unlock()
    }
    func completed() { lock.lock(); completions += 1; lock.unlock() }
    func snapshot() -> (events: [(Int, CGPoint)], completions: Int) {
        lock.lock(); defer { lock.unlock() }
        return (events, completions)
    }
}

extension ScrollingWindowLayoutTests {
    static func testWindowMotion() {
        let start = [1: CGPoint(x: 0, y: 10), 2: CGPoint(x: 30, y: 10)]
        let end = [1: CGPoint(x: 100, y: 10), 2: CGPoint(x: 30, y: 10)]
        let plan = WindowMotionPlan(from: start, to: end, startTime: 10, duration: 0.2)
        expect(plan.sample(at: 10) == start, "Motion starts at the captured positions")
        expect(plan.sample(at: 10.1)[1]!.x > 0 && plan.sample(at: 10.1)[1]!.x < 100,
               "Intermediate positions remain between endpoints")
        expect(plan.sample(at: 11) == end && plan.isFinished(at: 11), "Final positions are exact")
        expect(plan.sample(at: .nan) == end && plan.isFinished(at: .nan), "Invalid clock input terminates motion")
        let invalid = WindowMotionPlan(from: [1: CGPoint(x: CGFloat.nan, y: 0)], to: end, startTime: .nan, duration: .infinity)
        expect(invalid.duration == 0 && invalid.sample(at: 0) == end, "Invalid timing and initial positions have finite fallbacks")
        expect(WindowMotionPlan(from: start, to: end, startTime: 0, duration: 100).duration <= 1,
               "Motion duration has a finite upper bound")

        do {
            let completed = DispatchSemaphore(value: 0)
            let recorder = MotionWriteRecorder()
            let writer = CoalescingWindowMotionWriter(initialPositions: start, write: { id, point in
                recorder.record(id, point); return true
            }, completion: { _ in recorder.completed(); completed.signal() })
            writer.submit(positions: end, isFinal: true)
            expect(completed.wait(timeout: .now() + 2) == .success, "A final batch completes")
            let stats = writer.cancelAndWait()
            expect(stats.positions == end && stats.successfulWrites == 1 && stats.skippedWrites == 1,
                   "The writer reaches exact targets and skips unchanged positions")
            writer.submit(positions: start, isFinal: true)
            _ = writer.cancelAndWait()
            expect(recorder.snapshot().completions == 1, "Final completion is emitted only once")
            expect(stats.elapsed.isFinite && stats.elapsed >= 0, "Elapsed timing is finite")
            expect(stats.firstWriteDelay.isFinite && stats.firstWriteDelay >= 0 && stats.maxWriteDuration.isFinite,
                   "Write latency diagnostics use finite monotonic timing")
        }

        do {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let completed = DispatchSemaphore(value: 0)
            let recorder = MotionWriteRecorder()
            let writer = CoalescingWindowMotionWriter(initialPositions: start, write: { id, point in
                recorder.record(id, point)
                if point.x == 1 { entered.signal(); release.wait() }
                return true
            }, completion: { _ in recorder.completed(); completed.signal() })
            writer.submit(positions: [1: CGPoint(x: 1, y: 10), 2: CGPoint(x: 1, y: 10)], isFinal: false)
            expect(entered.wait(timeout: .now() + 2) == .success, "The stalled writer fixture began")
            for index in 2...100 {
                writer.submit(positions: [1: CGPoint(x: index, y: 10), 2: CGPoint(x: index, y: 10)], isFinal: index == 100)
            }
            expect(completed.wait(timeout: .now() + 0.02) == .timedOut, "A stalled write cannot report early completion")
            release.signal()
            expect(completed.wait(timeout: .now() + 2) == .success, "The latest target completes after the stalled write returns")
            let stats = writer.cancelAndWait()
            let events = recorder.snapshot().events
            expect(events.count == 3 && events.dropFirst().allSatisfy { $0.1.x == 100 },
                   "Rapid submissions keep one latest batch, with no stale per-window burst")
            expect(stats.positions[1]?.x == 100 && stats.positions[2]?.x == 100, "Coalescing preserves the exact final target")
            expect(stats.maxWriteDuration >= 0.015 && stats.firstWriteDelay <= stats.elapsed,
                   "Write timing captures the stalled closure rather than just submission time")
        }

        do {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let cancellationReturned = DispatchSemaphore(value: 0)
            let recorder = MotionWriteRecorder()
            let writer = CoalescingWindowMotionWriter(initialPositions: start, write: { id, point in
                recorder.record(id, point); entered.signal(); release.wait(); return true
            }, completion: { _ in recorder.completed() })
            writer.submit(positions: [1: CGPoint(x: 90, y: 10), 2: CGPoint(x: 90, y: 10)], isFinal: false)
            expect(entered.wait(timeout: .now() + 2) == .success, "The cancellation fixture has an in-flight write")
            writer.submit(positions: end, isFinal: true)
            DispatchQueue.global().async { _ = writer.cancelAndWait(); cancellationReturned.signal() }
            let cancellationDeadline = ProcessInfo.processInfo.systemUptime + 2
            while !writer.snapshot().isCancelled && ProcessInfo.processInfo.systemUptime < cancellationDeadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            expect(writer.snapshot().isCancelled, "Cancellation is recorded before the barrier wait")
            expect(cancellationReturned.wait(timeout: .now() + 0.02) == .timedOut,
                   "The cancellation barrier waits for the in-flight write before restore may begin")
            release.signal()
            expect(cancellationReturned.wait(timeout: .now() + 2) == .success, "Cancellation returns after the current write leaves")
            writer.submit(positions: end, isFinal: true)
            let stats = writer.cancelAndWait()
            expect(recorder.snapshot().events.count == 1 && recorder.snapshot().completions == 0,
                   "Cancellation drops pending work and prevents completion or later writes")
            expect(stats.successfulWrites == 1 && stats.positions[1]?.x == 90,
                   "Cancellation returns the last successful position for safe handoff")
        }

        do {
            let completed = DispatchSemaphore(value: 0)
            let writer = CoalescingWindowMotionWriter(initialPositions: start, write: { _, _ in false },
                                                       completion: { _ in completed.signal() })
            writer.submit(positions: end, isFinal: true)
            expect(completed.wait(timeout: .now() + 2) == .success, "A rejected write still finishes the batch")
            let stats = writer.cancelAndWait()
            expect(stats.failedWrites == 1 && stats.positions == start,
                   "A failed write does not claim the requested position was reached")
        }
    }
}
