# Ideate — UR-004

**Reviewed:** 2026-05-10

## Explorer — Assumptions & Perspectives

- **"Nothing is getting recorded" is ambiguous and the brief never disambiguates.** It could mean: (a) Start Recording does nothing visible, (b) a WAV/MP3 file appears but is 0 bytes, (c) a file appears with the expected duration but plays as pure silence, or (d) the file is short/truncated. Each maps to a different layer of the stack (UI → capture → mixer → writer → encoder). Triggered by: brief omitting any artifact ("nothing"). Without this distinction Capture cannot pick a target — it could either chase a writer bug while the real issue is TCC denial, or vice versa.

- **Reproduction conditions are unspecified.** We do not know: was audio actually playing somewhere when Start was pressed? Which build (signed/notarised vs. local Xcode run)? On what macOS version? Was Audio Capture permission granted in System Settings → Privacy & Security? Triggered by: brief is one sentence. Process Taps on macOS 14.4+ deterministically return silent buffers (not an error) when TCC is denied or when the user grants only some of the prompts — so "no error, no audio" is the canonical TCC-denied symptom and we cannot rule it out without checking.

- **The screenshot is itself a clue we shouldn't ignore.** The level meter reads `−∞ dB` while the source picker is being shown. The meter is fed by REQ-011 taps inside the mixer — `−∞` means the mixer is receiving zero or all-silent buffers. That immediately localises the bug to *upstream of the mixer* (capture or normalizer), not the writer/encoder. Triggered by: the attached screenshot. Capture should treat this as a strong prior, not background detail.

- **"Everything" is defined by `AudioSourceCatalog.refresh()` — which includes every app with a bundle ID, not every audible app.** Finder, Cursor, Xcode, Terminal, Notes — all get taps even though they emit nothing. This is a perspective the brief and the spec gloss over: the user's mental model of "Everything" is "everything I can hear," not "every running app." Triggered by: filter logic at AudioEngine/Capture/AudioSourceCatalog.swift:124–128 (bundleID + not-coreaudiod). Even if the bug is fixed, the UX expectation is misaligned.

## Challenger — Risks & Edge Cases

- **Fail-fast loop in `ProcessTapCapture.init` kills the whole session if any single pid fails.** AudioEngine/Capture/ProcessTapCapture.swift:79–83 iterates pids and `try`s the factory inside the loop — one zombie pid, one denied tap, one process that died between `catalog.refresh()` and `factory.makeEmitter()` throws and aborts the entire `.everything` session. With ~30 pids, the probability that at least one fails on any given run is non-trivial. Triggered by: `for pid in pids { let emitter = try factory.makeEmitter(for: pid) }`. A single failure should degrade gracefully, not record nothing.

- **Each pid creates its own private aggregate device.** AudioEngine/Capture/ProcessTapCapture.swift:230–257 builds a new `kAudioAggregateDeviceUIDKey` device per emitter. With "Everything" wrapping every catalog entry, we may be asking macOS to spin up 20–40 private aggregate devices simultaneously. Plausible failure modes: HAL allocation limits, sample-rate negotiation thrash, or simply slow start-up where every device returns silent buffers because their AUHAL units aren't yet running by the time the writer drains. Triggered by: per-pid aggregate construction. Worth checking if a single shared aggregate device with multiple sub-taps would behave better — Apple's sample code uses one aggregate per tap-set, not per pid.

- **TCC denial is silent for process taps.** On macOS 14.4+, `AudioHardwareCreateProcessTap` may succeed but the tap returns silence if the user has not granted "Audio Capture" in Privacy & Security. There is no `OSStatus` to catch — the AUHAL render callback simply receives zero-amplitude buffers. Triggered by: REQ-019 PermissionManager exists but it's not visible from the build path that this is being checked before tap creation, or that the user has been prompted at all. Capture must rule this out before chasing code bugs.

- **Aliveness polling tears down emitters that may transiently look dead.** AudioEngine/Capture/ProcessTapCapture.swift:106–116 calls `kill(pid, 0)` once per second and rips down the emitter on first failure. If a process briefly transitions (e.g. App Nap, sandbox suspension), we may kill its tap permanently and never restore it. Triggered by: 1 Hz aliveness check with no recovery path. Probably not the root cause of "nothing recorded" but a likely future bug.

- **`BuilderError.noAudibleProcesses` is the only explicit empty-state.** Builder throws only if `pids.isEmpty` (App/AppStore.swift:109). If the catalog returns one ghost pid that fails its tap, we throw `tapCreationFailed`; if it returns several and they all run but emit silence, we record successfully and produce a silent file. The user sees no error in the silent-file case. Triggered by: lack of "did anyone actually emit audio?" check during the recording. Worth a watchdog: if the mix stream emits zero non-silent buffers for N seconds after Start, surface a warning.

## Connector — Links & Reuse

- **REQ-019 PermissionManager and REQ-034 permission failure UX already exist.** Whatever the fix turns out to be, it likely has to thread through these. If the bug is "TCC denied," REQ-034 is the surface; if the bug is "tap fails for one pid," REQ-033 ErrorSurface routes the typed error. Don't introduce a third error path. Triggered by: archived REQs covering the permission stack.

- **REQ-011 level meter is a free diagnostic and we should use it.** The mixer's tap-meter publishes per-source levels (REQ-011). If we add an `OSLog` signpost when a per-source meter has been silent for >3 s, every "nothing recorded" report becomes self-diagnosing without shipping new instrumentation. Triggered by: existing meter infrastructure that already runs in production. Connector point: this is reuse, not new work.

- **REQ-040 manual-test-plan.md and REQ-035 mock-audio-source.** Does the manual test plan exercise "Everything" with real audio playing? Does the mock-audio-source path cover multi-pid in `.everything` mode? If yes → this is a regression with a known-good baseline. If no → this is a coverage gap, and the fix should add a manual-test step and (if feasible) an integration test using mock sources. Triggered by: archive listing showing both REQs already shipped.

- **`.specificApp(pid)` and `.everything` share the same `ProcessTapCapture` code path.** App/AppStore.swift:101–134 — only the pid count differs. If "Specific app" mode also produces silent files, the bug is in the shared path (auth/TCC, AUHAL setup, format negotiation). If "Specific app" works, the bug is multi-pid-specific (aggregate device limits, fail-fast loop). The cheapest diagnostic is "try Specific app on the same machine and see." Triggered by: shared call site. Capture should propose this as the first triage step.

## Summary

The brief is a bug report without an artifact. Before Capture decomposes anything, we need to know which failure mode this actually is — empty file, silent file, or no-file — and whether Audio Capture TCC has been granted on the test machine. The screenshot's `−∞ dB` meter strongly localises the problem upstream of the mixer (capture path or TCC), not the writer/encoder. Capture should produce a triage REQ first (reproduce, classify, log) and only then split into fix REQs; otherwise we'll burn cycles fixing the wrong layer.
