# piyano — Agent Protocols

## Project overview

Bash project that configures a Raspberry Pi 5 as a headless Pianoteq instrument.
Target OS: Raspberry Pi OS Lite 64-bit (Debian Bookworm-based, aarch64).

## Language and style

- All scripts are **bash** (shebang: `#!/usr/bin/env bash`)
- Use `set -euo pipefail` at the top of every script
- 2-space indentation, formatted with `shfmt -i 2 -ci`
- Must pass `shellcheck` with no warnings
- Run `mise run check` before committing

## Conventions

- Import modules rather than specific objects (N/A for bash; included for any future Python/JS helpers)
- Config file edits must be **idempotent** (grep before append)
- All user-facing output uses helper functions: `info()`, `warn()`, `error()`, `success()`
- No hardcoded paths for Pianoteq binary version — use variables
- Scripts must work when re-run on an already-configured system

## File structure

- `setup.sh` — main entry point, runs on the Pi as root
- `config/` — static config files deployed by setup.sh
- `scripts/` — user-facing helper scripts (run post-setup)
- `tweaks/` — optional performance tweaks (flag-gated)

## Testing

- No Pi hardware required for lint/format checks: `mise run check`
- Functional testing requires a Raspberry Pi 5 with HiFiBerry DAC+
- When making changes, verify idempotency by describing what happens on second run

## Do NOT

- Download or redistribute Pianoteq binaries (licence restrictions)
- Modify network config beyond wifi disable (user needs SSH)
- Add GUI dependencies
- Use PulseAudio, PipeWire, or JACK — direct ALSA only
- Add comments that merely narrate what the code does
