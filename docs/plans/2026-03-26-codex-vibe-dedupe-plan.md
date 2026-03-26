# Plan: Codex `vibe` Duplicate Surface Fix

- Internal grade: `M`
- Scope: `install.sh`, `install.ps1`, `check.sh`, `check.ps1`, runtime-neutral install/check tests

## Steps

1. Detect the bounded duplicate candidate only for Codex default roots shaped like `.../.codex`.
2. During install, quarantine legacy `.agents/skills/vibe` into `.agents/skills-disabled/`.
3. During check, fail explicitly if the duplicate surface still exists.
4. Verify with targeted runtime script tests and direct shell/PowerShell checks where available.
