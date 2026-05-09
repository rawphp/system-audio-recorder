import Darwin

// MARK: - MeterRingBuffer
//
// A single-producer / single-consumer (SPSC) lock-free ring buffer of `Float`
// values, intended for audio-thread → main-thread meter sample handoff.
//
// **Lock-free guarantee**: every `write(_:)` and `read()` call uses only
// `OSAtomicAdd64Barrier` / `OSAtomicCompareAndSwap64Barrier` operations
// from `<libkern/OSAtomicDeprecated.h>` (available on all macOS versions).
// No mutex, no `OSAllocatedUnfairLock`, no objc_lock on the hot path.
//
// These functions are deprecated in favour of `<stdatomic.h>`, but Apple
// continues to ship them and they remain fully functional on all macOS
// versions ≥ 10.4.  The `Synchronization.Atomic` type (SE-0410) requires
// macOS 15+, which is above this project's deployment target of macOS 14.4.
//
// **Capacity**: internally rounded up to the next power-of-two so that
// index wrapping is a single bitwise-AND (no modulo on the audio thread).
//
// **Full behaviour**: if the writer is ahead of the reader by exactly
// `capacity` slots, the *oldest* unread sample is dropped and the new value
// is written in its place.  The reader never blocks or spins.

public final class MeterRingBuffer: @unchecked Sendable {

    // MARK: - Storage

    /// Actual (power-of-two) capacity.
    public let capacity: Int

    /// Bitmask: `index & mask` == `index % capacity` (when capacity is a power of 2).
    private let mask: Int

    /// Backing store — allocated once during `init`.
    private let storage: UnsafeMutableBufferPointer<Float>

    // MARK: - Atomic cursors (Int64 so OSAtomicAdd64Barrier works without casting)
    //
    // `_writeHead` is incremented only by the producer (audio thread).
    // `_readHead`  is incremented only by the consumer (main/UI thread).
    //
    // We store them in heap-allocated `Int64` boxes so we can take stable
    // pointers into them for the OSAtomic calls.
    private let writeHeadPtr: UnsafeMutablePointer<Int64>
    private let readHeadPtr: UnsafeMutablePointer<Int64>

    // MARK: - Init / Deinit

    /// Creates a ring buffer with at least `capacity` slots.
    /// Actual capacity is rounded up to the next power of two.
    public init(capacity: Int) {
        precondition(capacity > 0)
        var pow2 = 1
        while pow2 < capacity { pow2 <<= 1 }
        self.capacity = pow2
        self.mask = pow2 - 1

        storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: pow2)
        storage.initialize(repeating: 0.0)

        writeHeadPtr = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        writeHeadPtr.initialize(to: 0)
        readHeadPtr = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        readHeadPtr.initialize(to: 0)
    }

    deinit {
        storage.deallocate()
        writeHeadPtr.deallocate()
        readHeadPtr.deallocate()
    }

    // MARK: - Private helpers

    /// Atomically loads the value at `ptr` using a full barrier.
    @inline(__always)
    private func atomicLoad(_ ptr: UnsafeMutablePointer<Int64>) -> Int64 {
        // OSAtomicAdd64Barrier(0, ptr) performs an atomic add of 0 with a
        // full memory barrier, returning the current value — the canonical
        // way to do an atomic load with barrier using the OSAtomic API.
        return OSAtomicAdd64Barrier(0, ptr)
    }

    /// Atomically stores `newValue` at `ptr` using a full barrier.
    @inline(__always)
    private func atomicStore(_ newValue: Int64, _ ptr: UnsafeMutablePointer<Int64>) {
        // Compute delta = newValue - current, then add it.
        // Because only one thread writes each head pointer, there's no ABA
        // race here: the delta is always positive and the old value is what
        // we just read on this same thread.
        let current = atomicLoad(ptr)
        let delta = newValue &- current
        if delta != 0 {
            _ = OSAtomicAdd64Barrier(delta, ptr)
        }
    }

    // MARK: - Write (producer / audio thread)

    /// Writes `value` into the buffer.
    ///
    /// If the buffer is full the **oldest** unread sample is dropped so the
    /// write always succeeds immediately without spinning or blocking.
    ///
    /// Safe to call from any thread; intended for the audio thread (producer).
    public func write(_ value: Float) {
        let wh = atomicLoad(writeHeadPtr)
        let rh = atomicLoad(readHeadPtr)

        let used = Int(wh &- rh)
        if used >= capacity {
            // Buffer full — advance readHead by 1 to drop the oldest sample.
            _ = OSAtomicAdd64Barrier(1, readHeadPtr)
        }

        storage[Int(wh) & mask] = value
        // Commit the write head.
        _ = OSAtomicAdd64Barrier(1, writeHeadPtr)
    }

    // MARK: - Read (consumer / main thread)

    /// Returns the oldest available sample, or `nil` if the buffer is empty.
    ///
    /// Safe to call from any thread; intended for the main/UI thread (consumer).
    public func read() -> Float? {
        let rh = atomicLoad(readHeadPtr)
        let wh = atomicLoad(writeHeadPtr)

        guard wh != rh else { return nil }   // buffer is empty

        let value = storage[Int(rh) & mask]
        _ = OSAtomicAdd64Barrier(1, readHeadPtr)
        return value
    }

    // MARK: - Diagnostics

    /// Number of samples currently available to read (approximate).
    public var availableToRead: Int {
        let wh = atomicLoad(writeHeadPtr)
        let rh = atomicLoad(readHeadPtr)
        return max(0, Int(wh &- rh))
    }
}
