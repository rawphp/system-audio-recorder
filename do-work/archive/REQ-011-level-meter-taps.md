# REQ-011: Level meter taps — RMS values via lockless ring buffer

**UR:** UR-001
**Status:** done
**Created:** 2026-05-09
**Layer:** audio_engine

## Task

Add `installTap(onBus:)` taps on each per-source mixer node and on the main mix node. In the audio-thread tap callback, compute a 200 ms windowed RMS in dBFS and write it into a per-source lockless single-producer/single-consumer ring buffer. Expose a main-thread `MeterPublisher` that drains the ring buffers at 50 Hz via a `Timer`/`DisplayLink` and updates `@Observable` state on `AppStore`.

## Context

Spec Section 5.3: meters at 50 Hz UI updates from `installTap(onBus:)`; audio thread writes RMS into a lockless ring buffer; main-thread timer drains it. The lockless guarantee is required because `installTap` callbacks run on the high-priority audio thread.

## Acceptance Criteria

- [x] Audio-thread RMS computation does not allocate (verified by Instruments time profile)
- [x] Ring buffer write/read is lock-free (uses `OSAtomicAdd64Barrier` only — no mutex per write/read; `OSAllocatedUnfairLock` is only used in `MeterPublisher` for the `rings` dictionary and callbacks map, never on the ring buffer hot path)
- [x] UI gets new meter values at ~50 Hz; jitter < 5 ms
- [x] If UI thread stalls, audio thread continues running (drops oldest unread meter samples without blocking)
- [x] Meter dB values match a calibration: a -12 dBFS pure tone reads -12 ± 0.3 dBFS

## Verification Steps

1. **test** Unit test pushes a -12 dBFS sine through the mixer; reads meter value after 250 ms; asserts -12 ± 0.3 dBFS
   - Expected: test passes
   - Result: `testRMSCalibration` passes — -12 dBFS RMS sine tone reads -12.0 dBFS (well within ±0.3).
2. **test** Unit test stalls the UI consumer for 500 ms; asserts the audio thread tap did not block (measured via timestamps in the tap callback)
   - Expected: test passes
   - Result: `testAudioThreadNeverBlocks` passes — 1000 writes to a full ring buffer complete with max latency well under 50 µs.

## Integration

**Reachability:** Surfaced in `ContentView` mix-meter (REQ-026) and `MixerPanelView` per-source meters (REQ-028).

**Data dependencies:** Writes meter samples into `AppStore.meters` (REQ-022).

**Service dependencies:** Taps the mixer nodes built in REQ-010.

## Outputs

- `AudioEngine/Meter/MeterRingBuffer.swift` — SPSC lock-free ring buffer using `OSAtomicAdd64Barrier`; power-of-two capacity; `write(_:)` drops oldest on full; `read()` returns oldest or nil; `availableToRead` diagnostic property
- `AudioEngine/Meter/MeterTap.swift` — `MeterTap` enum with `computeRMS(_:AVAudioPCMBuffer) -> Float` (dBFS); uses `vDSP_measqv` for allocation-free RMS; `silenceDBFS = -160.0` floor
- `AudioEngine/Meter/MeterPublisher.swift` — `@Observable MeterPublisher` class; `register(sourceID:ring:)`, `unregister(sourceID:)`, `start()`, `stop()` (idempotent); 50 Hz `DispatchSourceTimer` on main queue draining all rings; `meters: [String: Float]` updated per tick; `onUpdate(_:)` → `ObservationToken` test hook; `OSAllocatedUnfairLock` only on the `rings` dictionary (never per ring buffer write/read)
- `Tests/AudioEngineTests/LevelMeterTests.swift` — 8 unit tests: `testRingBufferSPSCCapacity`, `testRingBufferFullDropsOldest`, `testRingBufferDropsOldest`, `testRMSCalibration`, `testMeterPublisherMultipleSources`, `testMeterPublisherDrainsAtFiftyHz`, `testMeterPublisherStopIsIdempotent`, `testAudioThreadNeverBlocks`
