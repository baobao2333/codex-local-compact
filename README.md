# Local Codex Compaction

Small PowerShell helper for saving a local handoff snapshot from Codex session history.

It reads Codex JSONL session logs from `~/.codex/sessions`, asks the local Claude Code environment for a structured summary, and writes Markdown/JSON handoff files under `~/.codex/local-compaction`.

## Files

- `local-compact.ps1` - the compaction script.
- `README.md` - instructions for Codex agents and humans.

## Install

Copy the script into the Codex scripts directory:

```powershell
New-Item -ItemType Directory -Force -Path "$HOME\.codex\scripts" | Out-Null
Copy-Item -Force .\local-compact.ps1 "$HOME\.codex\scripts\local-compact.ps1"
```

## Codex Agent Instruction

Add this rule to the relevant `AGENTS.md` or session instructions:

```text
When the user asks to compact, compress, summarize, snapshot, hand off, or preserve context, first run:
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codex\scripts\local-compact.ps1" -Trigger instruction -Force

After a resume or compaction, check:
$HOME\.codex\local-compaction\latest.md
```

## Usage

Run manually:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codex\scripts\local-compact.ps1" -Trigger manual -Force
```

Run against a specific session file:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codex\scripts\local-compact.ps1" -SessionPath "C:\path\to\session.jsonl" -Trigger manual -Force
```

Pipe a user prompt into trigger detection:

```powershell
"please compact this context" | powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codex\scripts\local-compact.ps1" -Trigger prompt
```

## Outputs

By default, outputs are written to:

```text
~/.codex/local-compaction/
```

Important files:

- `latest.md` - latest human-readable handoff.
- `threads/<thread-id>/latest.md` - latest handoff for one thread.
- `threads/<thread-id>/latest.json` - latest structured summary for one thread.
- `events.jsonl` - append-only event log.
- `last-<runner>-raw.txt` - latest raw Claude Code response for debugging.

## Requirements

- Windows PowerShell.
- Codex session logs under `~/.codex/sessions`.
- Claude Code CLI available at the default npm location or on `PATH`.

## Parameters

- `-SessionPath` - explicit Codex session JSONL file.
- `-ThreadId` - thread/session UUID used to find a matching session file.
- `-Trigger` - trigger name written into output metadata.
- `-OutDir` - output directory, defaulting to `~/.codex/local-compaction`.
- `-MaxChars` - transcript character budget before truncation.
- `-ClaudeTimeoutSec` - local Claude Code invocation timeout.
- `-ClaudeArgs` - optional arguments passed through to the local Claude Code CLI.
- `-Force` - force output even when trigger detection would otherwise skip.
