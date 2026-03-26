# Requirement: Codex `vibe` Duplicate Surface Fix

- Date: 2026-03-26
- Issue: `#42`

## Goal

Prevent Codex from exposing two `vibe` skills when both `~/.codex/skills/vibe` and a legacy sibling copy under `~/.agents/skills/vibe` exist.

## Acceptance

- Codex default-root install quarantines the legacy `.agents/skills/vibe` duplicate instead of leaving both surfaces discoverable.
- `check.sh` and `check.ps1` fail clearly when the duplicate surface still exists.
- Non-default custom target roots are not mutated as part of this mitigation.
- Automated tests cover shell install quarantine and shell health-check failure on duplicate reintroduction.
