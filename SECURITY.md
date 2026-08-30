# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 0.1.x | yes |

## Reporting a vulnerability

Use GitHub's private vulnerability reporting (Security tab → Report a vulnerability) on this repository. Please do not open public issues for security reports.

Include: the affected component (store / lifecycle / publisher / installer / migrator), the command or hook path involved, expected versus actual behavior, and a minimal reproduction. Receipts and state files help — redact pointer text and session identifiers first.

## Scope

In scope: the scripts shipped in this repository (`src/`, `scripts/`, `hooks/`, `schemas/`) — path handling and escapes, JSON parsing and encoding, CAS and concurrency behavior, installer backup/rollback integrity, and hook definition generation.

Out of scope: the Codex host application itself, its hook trust review mechanism, and model or provider behavior. Report those upstream to https://github.com/openai/codex/security.

## Design boundaries

The runtime never sends network requests, never reads or writes beyond its owned roots, and treats hook stdin as untrusted input (strict UTF-8, fixed field sets, size limits). See [docs/security.md](docs/security.md) for the full boundary description.
