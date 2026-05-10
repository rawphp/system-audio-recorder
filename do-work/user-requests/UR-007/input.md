---
ur: UR-007
received: 2026-05-10
status: closed
closed: 2026-05-10
resolution: no-bug
---

# UR-007: User Request

## Request

fix 'make release'

DEVELOPMENT_TEAM exists in env

## Resolution

Closed — no bug. `make release` builds successfully from an interactive shell where `.zshrc` is sourced and `DEVELOPMENT_TEAM` is exported. The apparent failure was reproducible only from non-interactive shells (which do not source `.zshrc`); user confirmed the interactive path is the supported invocation.
