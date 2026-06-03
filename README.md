# Local Codex Compaction

Small PowerShell helper for saving a local handoff snapshot from Codex session history.

It reads Codex JSONL session logs from `~/.codex/sessions`, asks the local Claude Code environment for a structured summary, and writes Markdown/JSON handoff files under `~/.codex/local-compaction`.

## Files

- `local-compact.ps1` - the compaction script.
- `examples/hooks.json` - copyable Codex hooks example.
- `README.md` - instructions for Codex agents and humans.

## Install

Copy the script into the Codex scripts directory:

```powershell
New-Item -ItemType Directory -Force -Path "$HOME\.codex\scripts" | Out-Null
Copy-Item -Force .\local-compact.ps1 "$HOME\.codex\scripts\local-compact.ps1"
```

## Codex Setup Checklist

For a complete Codex setup, update all of these local files:

- `~/.codex/hooks.json` - add `UserPromptSubmit`, `PreCompact`, and `PostCompact` hooks. `SessionStart` with matcher `compact` is optional.
- `~/.codex/config.toml` - set `experimental_compact_prompt_file` and enable hooks.
- Optional full replacement path: run `compact-proxy.mjs` and point an OpenAI-named provider at it, so `/responses/compact` is handled locally while normal `/responses` calls are forwarded.
- `~/.codex/compact_prompt_local.txt` - create the compact prompt used by Codex's built-in compaction.
- `~/.codex/AGENTS.md` - add the local compaction instruction.

Merge these entries with existing files. Do not replace unrelated hooks, settings, project trust entries, plugin config, or generated hook trust state.

## Hooks

Add or merge these entries under the top-level `hooks` object in `~/.codex/hooks.json`.

The copyable example is in `examples/hooks.json`. It resolves the script through `$HOME`, so it should work across Windows user names without replacing `C:\Users\...` manually.
After changing hooks, review and trust new hook entries with `/hooks`.

When the `PreCompact` hook runs, `local-compact.ps1` writes the local handoff and exits without hook control output. Keep request compression enabled/default so Codex still raises the compact lifecycle event. Returning `continue: false` from `PreCompact` stops before compacting and can stop the current turn before the model replies.

`SessionStart` with matcher `compact` can read the latest local handoff and return it as extra developer context if Codex starts a new session with source `compact`. In current in-turn automatic compaction tests, Codex runs `PreCompact` and `PostCompact` but does not run `SessionStart(compact)`, so this is only an optional overlay path. Hooks cannot replace Codex's built-in compact result directly.

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "compact",
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -Command \"& { & (Join-Path $HOME '.codex\\scripts\\local-compact.ps1') -Trigger sessionstart }\"",
            "timeout": 30,
            "statusMessage": "Loading local compaction handoff"
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "manual|auto",
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -Command \"& { & (Join-Path $HOME '.codex\\scripts\\local-compact.ps1') -Trigger precompact -Force }\"",
            "timeout": 1500,
            "statusMessage": "Running local Codex compaction"
          }
        ]
      }
    ],
    "PostCompact": [
      {
        "matcher": "manual|auto",
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -Command \"& { & (Join-Path $HOME '.codex\\scripts\\local-compact.ps1') -Trigger postcompact -Force }\"",
            "timeout": 1500,
            "statusMessage": "Refreshing local compaction handoff"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -Command \"& { & (Join-Path $HOME '.codex\\scripts\\local-compact.ps1') -Trigger prompt }\"",
            "timeout": 1500
          }
        ]
      }
    ]
  }
}
```

## Full Local Compact Replacement

Hooks alone cannot inject replacement history for automatic compaction. To fully replace remote compaction, run the compact proxy and configure Codex to use it as an OpenAI-named Responses provider. The proxy intercepts `POST /responses/compact`, runs `local-compact.ps1 -Trigger proxycompact`, returns the local handoff as compact replacement history, and forwards normal `POST /responses` traffic upstream.

Start the proxy:

```powershell
node .\compact-proxy.mjs
```

Use this provider shape in `~/.codex/config.toml` or with `codex exec -c` overrides:

```toml
model_provider = "local_compact_proxy"

[model_providers.local_compact_proxy]
name = "OpenAI"
base_url = "http://127.0.0.1:18080/backend-api/codex"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false
```

`name = "OpenAI"` is intentional: Codex uses it to select the remote compact code path, and the proxy then handles that compact request locally.

## Compact Prompt

Create `~/.codex/compact_prompt_local.txt`:

```text
You are compacting a Codex thread.

Preserve the durable state needed to resume work without the original transcript:
- current goal and definition of done
- user preferences and hard instructions
- files, config, commands, and tool results that changed the task state
- failed or weak attempts and why they failed
- unresolved uncertainty and exact next actions

Do not erase negative evidence, rejected approaches, user corrections, or ordering-sensitive decisions.

If the transcript includes a local Codex compaction handoff from `~/.codex/local-compaction/`, treat that handoff as resume context and keep later corrections or current instructions higher priority.
```

Then add or update this setting in `~/.codex/config.toml`:

```toml
experimental_compact_prompt_file = 'C:\Users\YOU\.codex\compact_prompt_local.txt'
```

If hooks are not already enabled in the same config file, enable them:

```toml
[features]
hooks = true
```

Restart Codex or start a new thread after changing `config.toml`, so the updated feature flags are loaded.

## Agent Instruction

Add this rule to the relevant `~/.codex/AGENTS.md` or session instructions:

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
