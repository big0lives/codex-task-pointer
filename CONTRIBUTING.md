# Contributing

Thanks for looking into codex-task-pointer. This document covers local setup, the verification gates, and what a pull request is expected to contain.

## Setup

- Windows with PowerShell 7.5+ (`pwsh --version`). The JSON layer uses `ConvertFrom-Json -DateKind`, a parameter added in 7.5.
- Node.js 18+ only if you work on the app-server harnesses.
- No third-party runtime modules; the tests write only to the system temp directory.

## Gates

Run from the repository root:

```powershell
pwsh -NoProfile -File .\tests\run-all.ps1 -SkipAppServer      # parser / JSON / core tests / install smoke / public tree
pwsh -NoProfile -File .\scripts\validate-public-tree.ps1      # sanitization gate
```

Both must pass before you open a pull request. Changes to hook behavior additionally need a probe run against an isolated `CODEX_HOME` (`tests\app-server-hooks-list.mjs`).

## Pull requests

1. Fork, then create a feature branch (`git checkout -b feature/short-name`).
2. Keep the public tree sanitization-clean: no personal paths, credentials, session data, pointer contents or real UUID literals.
3. Register any new file in the allowlist of `scripts/validate-public-tree.ps1`.
4. Attach the receipt outputs (`run-all` JSON, validator JSON) to the pull request description.
5. Add user-visible changes under a new `Unreleased` heading in `CHANGELOG.md`.

## Reporting issues

Use the issue templates under `.github/ISSUE_TEMPLATE`. Security-sensitive reports go through the private channel in [SECURITY.md](SECURITY.md) — never a public issue.

## Agent-driven contributions

This repository ships an AGENTS.md deployment playbook. If you work through an AI agent, the same gates apply, and the agent must not modify a `CODEX_HOME` beyond what `scripts/install.ps1` owns.
