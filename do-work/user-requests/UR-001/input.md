---
ur: UR-001
received: 2026-05-09
status: captured
classification: feature
layers_in_scope: [audio_engine, ui, supporting]
layer_decisions: {}
reqs:
  - { id: REQ-001, layer: supporting,   integration_confidence: partial }
  - { id: REQ-002, layer: supporting,   integration_confidence: partial }
  - { id: REQ-003, layer: supporting,   integration_confidence: partial }
  - { id: REQ-004, layer: supporting,   integration_confidence: partial }
  - { id: REQ-005, layer: supporting,   integration_confidence: partial }
  - { id: REQ-006, layer: audio_engine, integration_confidence: partial }
  - { id: REQ-007, layer: audio_engine, integration_confidence: partial }
  - { id: REQ-008, layer: audio_engine, integration_confidence: partial }
  - { id: REQ-009, layer: audio_engine, integration_confidence: partial }
  - { id: REQ-010, layer: audio_engine, integration_confidence: partial }
  - { id: REQ-011, layer: audio_engine, integration_confidence: partial }
  - { id: REQ-012, layer: audio_engine, integration_confidence: partial }
  - { id: REQ-013, layer: audio_engine, integration_confidence: partial }
  - { id: REQ-014, layer: audio_engine, integration_confidence: partial }
  - { id: REQ-015, layer: audio_engine, integration_confidence: partial }
  - { id: REQ-016, layer: audio_engine, integration_confidence: partial }
  - { id: REQ-017, layer: audio_engine, integration_confidence: partial }
  - { id: REQ-018, layer: audio_engine, integration_confidence: partial }
  - { id: REQ-019, layer: supporting,   integration_confidence: partial }
  - { id: REQ-020, layer: supporting,   integration_confidence: partial }
  - { id: REQ-021, layer: supporting,   integration_confidence: partial }
  - { id: REQ-022, layer: ui,           integration_confidence: partial }
  - { id: REQ-023, layer: ui,           integration_confidence: partial }
  - { id: REQ-024, layer: ui,           integration_confidence: partial }
  - { id: REQ-025, layer: ui,           integration_confidence: partial }
  - { id: REQ-026, layer: ui,           integration_confidence: partial }
  - { id: REQ-027, layer: ui,           integration_confidence: partial }
  - { id: REQ-028, layer: ui,           integration_confidence: partial }
  - { id: REQ-029, layer: ui,           integration_confidence: partial }
  - { id: REQ-030, layer: ui,           integration_confidence: partial }
  - { id: REQ-031, layer: ui,           integration_confidence: partial }
  - { id: REQ-032, layer: ui,           integration_confidence: partial }
  - { id: REQ-033, layer: ui,           integration_confidence: partial }
  - { id: REQ-034, layer: ui,           integration_confidence: partial }
  - { id: REQ-035, layer: none,         integration_confidence: n/a }
  - { id: REQ-036, layer: none,         integration_confidence: n/a }
  - { id: REQ-037, layer: none,         integration_confidence: n/a }
  - { id: REQ-038, layer: none,         integration_confidence: n/a }
  - { id: REQ-039, layer: none,         integration_confidence: n/a }
  - { id: REQ-040, layer: none,         integration_confidence: n/a }
  - { id: REQ-041, layer: supporting,   integration_confidence: partial }
  - { id: REQ-042, layer: supporting,   integration_confidence: partial }
acknowledged_partials:
  - REQ-001
  - REQ-002
  - REQ-003
  - REQ-004
  - REQ-005
  - REQ-006
  - REQ-007
  - REQ-008
  - REQ-009
  - REQ-010
  - REQ-011
  - REQ-012
  - REQ-013
  - REQ-014
  - REQ-015
  - REQ-016
  - REQ-017
  - REQ-018
  - REQ-019
  - REQ-020
  - REQ-021
  - REQ-022
  - REQ-023
  - REQ-024
  - REQ-025
  - REQ-026
  - REQ-027
  - REQ-028
  - REQ-029
  - REQ-030
  - REQ-031
  - REQ-032
  - REQ-033
  - REQ-034
  - REQ-041
  - REQ-042
---

<!-- capture-summary-start -->
## Capture summary (2026-05-09)

| Item | Value |
|---|---|
| Classification | feature |
| Layers in scope | audio_engine, ui, supporting |
| Layer decisions | (none — all covered) |
| REQs generated | 42 |

Note on integration confidence: this is a greenfield project. Every cited future file path is from Section 9 of the design spec but does not yet exist on disk, so the capture rule downgrades each new-surface REQ to `partial`. The brief authorizes the design spec as source of truth, so per-REQ user prompting was skipped — the spec itself is the authoritative wiring contract.

| REQ | Layer | Integration confidence |
|---|---|---|
| REQ-001 init-xcode-project              | supporting   | partial |
| REQ-002 add-spm-dependencies            | supporting   | partial |
| REQ-003 vendor-lame-xcframework         | supporting   | partial |
| REQ-004 entitlements-and-info-plist     | supporting   | partial |
| REQ-005 ci-pipeline                     | supporting   | partial |
| REQ-006 audio-source-catalog            | audio_engine | partial |
| REQ-007 process-tap-capture             | audio_engine | partial |
| REQ-008 microphone-capture              | audio_engine | partial |
| REQ-009 format-normalization            | audio_engine | partial |
| REQ-010 mixer-graph                     | audio_engine | partial |
| REQ-011 level-meter-taps                | audio_engine | partial |
| REQ-012 wav-writer                      | audio_engine | partial |
| REQ-013 recording-session               | audio_engine | partial |
| REQ-014 auto-stop-duration              | audio_engine | partial |
| REQ-015 auto-stop-silence               | audio_engine | partial |
| REQ-016 crash-safety-recovery           | audio_engine | partial |
| REQ-017 lame-encoder                    | audio_engine | partial |
| REQ-018 encoding-queue                  | audio_engine | partial |
| REQ-019 permission-manager              | supporting   | partial |
| REQ-020 hotkey-manager                  | supporting   | partial |
| REQ-021 settings-persistence            | supporting   | partial |
| REQ-022 app-store                       | ui           | partial |
| REQ-023 content-view                    | ui           | partial |
| REQ-024 source-picker-view              | ui           | partial |
| REQ-025 record-controls-view            | ui           | partial |
| REQ-026 mix-level-meter-view            | ui           | partial |
| REQ-027 post-stop-toast                 | ui           | partial |
| REQ-028 mixer-panel-view                | ui           | partial |
| REQ-029 output-settings-view            | ui           | partial |
| REQ-030 encoding-jobs-view              | ui           | partial |
| REQ-031 menu-bar-controller             | ui           | partial |
| REQ-032 show-in-dock-toggle             | ui           | partial |
| REQ-033 error-surfacing-infrastructure  | ui           | partial |
| REQ-034 permission-failure-ux           | ui           | partial |
| REQ-035 mock-audio-source               | none         | n/a     |
| REQ-036 recording-session-int-tests     | none         | n/a     |
| REQ-037 lame-encoder-unit-tests         | none         | n/a     |
| REQ-038 wav-writer-unit-tests           | none         | n/a     |
| REQ-039 format-normalizer-unit-tests    | none         | n/a     |
| REQ-040 manual-test-plan                | none         | n/a     |
| REQ-041 developer-id-signing            | supporting   | partial |
| REQ-042 notarization-and-dmg            | supporting   | partial |
<!-- capture-summary-end -->

# UR-001: User Request

## Request

build the macOS system audio → MP3 recorder per the approved design spec at /Users/tomkaczocha/EA/projects/system-audio-to-mp3/docs/superpowers/specs/2026-05-09-system-audio-to-mp3-design.md. The spec is the source of truth for scope, modules, UX, and non-goals.
