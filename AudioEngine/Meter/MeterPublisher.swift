import Foundation
import os.lock

// MARK: - MeterPublisher
//
// Main-thread 50 Hz drain of per-source `MeterRingBuffer`s.
//
// **Design** (spec Section 5.3):
//  • Each audio source has one `MeterRingBuffer` (written by the audio thread
//    inside `installTap(onBus:)` callbacks via `MeterTap.computeRMS`).
//  • `MeterPublisher` owns a `DispatchSourceTimer` firing at 50 Hz on the
//    main queue.  On each tick it drains every registered ring buffer and
//    updates `meters[sourceID]` with the latest dBFS value.
//  • `meters` is `@Observable` — SwiftUI views bind to it directly.
//
// **AppStore integration** (REQ-022, not yet built):
//  The AppStore will hold a `MeterPublisher` instance and bind
//  `AppStore.meters` to `publisher.meters`.  REQ-011 does NOT create AppStore.
//
// **Thread safety**:
//  • `rings`    is protected by `OSAllocatedUnfairLock` (register/unregister
//               can happen on any thread, but typically main).
//  • `meters`   is mutated only on the main queue (inside the timer handler).
//  • Timer start/stop is idempotent and thread-safe.

@Observable
public final class MeterPublisher: @unchecked Sendable {

    // MARK: - Observable state

    /// Most-recent dBFS level per source ID.
    /// Updated at ~50 Hz on the main queue.
    public private(set) var meters: [String: Float] = [:]

    // MARK: - Private

    /// Registered ring buffers, guarded by a lock (register can be called
    /// before `start()` from any thread).
    private var rings: [String: MeterRingBuffer] = [:]
    private let ringsLock = OSAllocatedUnfairLock()

    /// The drain timer.
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue.main

    // MARK: - Update callbacks (for testing)

    private typealias UpdateCallback = ([String: Float]) -> Void
    private var updateCallbacks: [UUID: UpdateCallback] = [:]
    private let callbackLock = OSAllocatedUnfairLock()

    // MARK: - Init

    public init() {}

    // MARK: - Registration

    /// Registers a `MeterRingBuffer` for `sourceID`.
    ///
    /// The audio thread writes dBFS values into `ring` via `MeterTap.computeRMS`.
    /// `MeterPublisher` drains it on the main queue at 50 Hz.
    ///
    /// Thread-safe. Safe to call before or after `start()`.
    public func register(sourceID: String, ring: MeterRingBuffer) {
        ringsLock.lock()
        rings[sourceID] = ring
        ringsLock.unlock()
    }

    /// Removes the ring buffer for `sourceID`. Idempotent.
    public func unregister(sourceID: String) {
        ringsLock.lock()
        rings.removeValue(forKey: sourceID)
        ringsLock.unlock()

        // Remove the meter value on the main queue to stay @Observable-safe.
        DispatchQueue.main.async { [weak self] in
            self?.meters.removeValue(forKey: sourceID)
        }
    }

    // MARK: - Lifecycle

    /// Starts the 50 Hz drain timer. Idempotent.
    public func start() {
        guard timer == nil else { return }

        let src = DispatchSource.makeTimerSource(flags: [], queue: timerQueue)
        // 20 ms period = 50 Hz. Leeway 2 ms.
        src.schedule(deadline: .now() + .milliseconds(20),
                     repeating: .milliseconds(20),
                     leeway: .milliseconds(2))
        src.setEventHandler { [weak self] in self?.drain() }
        src.resume()
        timer = src
    }

    /// Stops the drain timer. Idempotent.
    public func stop() {
        guard let src = timer else { return }
        src.cancel()
        timer = nil
    }

    // MARK: - Internal drain

    /// Drains each registered ring buffer and updates `meters`.
    /// Called on the main queue at 50 Hz.
    private func drain() {
        ringsLock.lock()
        let snapshot = rings   // copy the dictionary of references (cheap)
        ringsLock.unlock()

        var didUpdate = false
        for (id, ring) in snapshot {
            // Drain all available samples; keep the latest.
            var latest: Float? = nil
            while let v = ring.read() { latest = v }
            if let v = latest {
                meters[id] = v
                didUpdate = true
            }
        }

        guard didUpdate else { return }

        // Notify test observers.
        callbackLock.lock()
        let cbs = updateCallbacks
        callbackLock.unlock()

        for (_, cb) in cbs { cb(meters) }
    }

    // MARK: - Test support

    /// Registers a callback invoked on the main queue after each drain tick
    /// that produced at least one update.  Returns a token; call `cancel()`
    /// to remove the callback.
    @discardableResult
    public func onUpdate(_ callback: @escaping ([String: Float]) -> Void) -> ObservationToken {
        let id = UUID()
        callbackLock.lock()
        updateCallbacks[id] = callback
        callbackLock.unlock()
        return ObservationToken { [weak self] in
            self?.callbackLock.lock()
            self?.updateCallbacks.removeValue(forKey: id)
            self?.callbackLock.unlock()
        }
    }
}

// MARK: - ObservationToken

/// A lightweight cancellable returned by `MeterPublisher.onUpdate(_:)`.
public final class ObservationToken {
    private let block: () -> Void
    public init(_ block: @escaping () -> Void) { self.block = block }
    public func cancel() { block() }
}
