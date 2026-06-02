param(
    [string]$SessionPath,
    [string]$ThreadId,
    [string]$Trigger = "manual",
    [string]$OutDir,
    [int]$MaxChars = 160000,
    [int]$ModelTimeoutSec = 1200,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
if (-not $OutDir) {
    $OutDir = Join-Path $CodexHome "local-compaction"
}

function Read-RedirectedInput {
    if ([Console]::IsInputRedirected) {
        return [Console]::In.ReadToEnd()
    }
    return ""
}

function Find-FirstUuid([string]$Text) {
    if (-not $Text) {
        return $null
    }
    $match = [regex]::Match($Text, "\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
    if ($match.Success) {
        return $match.Value
    }
    return $null
}

function Test-Trigger([string]$Text) {
    if (-not $Text) {
        return $false
    }
    if ([regex]::IsMatch($Text, "(?i)(/compact|\bcompact\b|compaction|compress context|context compression|handoff|snapshot|summari[sz]e context)")) {
        return $true
    }

    $context = -join ([char[]](0x4E0A, 0x4E0B, 0x6587))
    $compress = -join ([char[]](0x538B, 0x7F29))
    $summary = -join ([char[]](0x603B, 0x7ED3))
    $handoff = -join ([char[]](0x4EA4, 0x63A5))
    $snapshot = -join ([char[]](0x5FEB, 0x7167))

    return $Text.Contains($compress) -or
        $Text.Contains($handoff) -or
        $Text.Contains($snapshot) -or
        ($Text.Contains($context) -and $Text.Contains($summary))
}

function Limit-Text([string]$Text, [int]$Limit) {
    if (-not $Text -or $Text.Length -le $Limit) {
        return $Text
    }
    return $Text.Substring(0, $Limit) + "`n[...truncated...]"
}

function Get-ContentText($Content) {
    if ($null -eq $Content) {
        return ""
    }
    if ($Content -is [string]) {
        return $Content
    }
    if ($Content -is [System.Array]) {
        $parts = foreach ($part in $Content) {
            if ($part.text) {
                $part.text
            } elseif ($part.type -and $part.type -ne "text") {
                "[$($part.type)]"
            }
        }
        return ($parts -join "`n")
    }
    if ($Content.text) {
        return $Content.text
    }
    return ($Content | ConvertTo-Json -Depth 8)
}

function Find-SessionPath([string]$Path, [string]$Id, [string]$HomeDir) {
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $sessions = Join-Path $HomeDir "sessions"
    if (-not (Test-Path -LiteralPath $sessions)) {
        throw "Codex sessions directory was not found: $sessions"
    }

    if ($Id) {
        $hit = Get-ChildItem -LiteralPath $sessions -Recurse -File -Filter "*$Id*.jsonl" |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($hit) {
            return $hit.FullName
        }
    }

    $latest = Get-ChildItem -LiteralPath $sessions -Recurse -File -Filter "*.jsonl" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($latest) {
        return $latest.FullName
    }

    throw "No Codex session JSONL file was found under $sessions"
}

function Build-Transcript([string]$Path, [int]$Budget) {
    $items = New-Object System.Collections.Generic.List[string]
    $sessionId = $null
    $cwd = $null

    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if (-not $line.Trim()) {
            continue
        }

        try {
            $obj = $line | ConvertFrom-Json
        } catch {
            continue
        }

        $ts = $obj.timestamp
        if ($obj.type -eq "session_meta") {
            $sessionId = $obj.payload.id
            $cwd = $obj.payload.cwd
            $items.Add("[$ts] session: id=$sessionId cwd=$cwd cli=$($obj.payload.cli_version) model=$($obj.payload.model_provider)")
            continue
        }

        if ($obj.type -eq "response_item") {
            $p = $obj.payload
            if ($p.type -eq "message") {
                $text = (Get-ContentText $p.content).Trim()
                if ($text) {
                    $items.Add("[$ts] $($p.role): $text")
                }
            } elseif ($p.type -eq "function_call") {
                $items.Add("[$ts] tool_call: $($p.name) " + (Limit-Text $p.arguments 2500))
            } elseif ($p.type -eq "function_call_output") {
                $items.Add("[$ts] tool_output: $($p.call_id) " + (Limit-Text $p.output 4000))
            } elseif ($p.type -eq "reasoning" -and $p.summary) {
                $summary = (Get-ContentText $p.summary).Trim()
                if ($summary) {
                    $items.Add("[$ts] reasoning_summary: $summary")
                }
            }
            continue
        }

        if ($obj.type -eq "event_msg" -and $obj.payload.type -eq "agent_message") {
            $items.Add("[$ts] assistant_event: $($obj.payload.message)")
        }
    }

    $text = $items -join "`n"
    if ($text.Length -le $Budget) {
        return @{
            Text = $text
            SessionId = $sessionId
            Cwd = $cwd
        }
    }

    $head = [Math]::Min(30000, [Math]::Max(2000, [int]($Budget / 5)))
    $head = [Math]::Min($head, [Math]::Max(0, $Budget - 1000))
    $tail = [Math]::Max(0, $Budget - $head - 80)
    $tail = [Math]::Min($tail, $text.Length - $head)
    $trimmed = $text.Substring(0, $head) + "`n[...middle truncated by local-compact.ps1...]`n" + $text.Substring($text.Length - $tail)
    return @{
        Text = $trimmed
        SessionId = $sessionId
        Cwd = $cwd
    }
}

function Strip-Fence([string]$Text) {
    $body = $Text.Trim()
    $body = [regex]::Replace($body, "^```(?:json)?\s*", "")
    $body = [regex]::Replace($body, "\s*```$", "")
    return $body.Trim()
}

function Quote-Arg([string]$Text) {
    if ($null -eq $Text) {
        return '""'
    }
    if ($Text -eq "") {
        return '""'
    }
    if ($Text -match '[\s"]') {
        return '"' + ($Text -replace '\\', '\\' -replace '"', '\"') + '"'
    }
    return $Text
}

function Invoke-CommandWithInput([string]$Prompt, [string]$FilePath, [string[]]$ArgList, [int]$TimeoutSec) {
    $runDir = Join-Path ([System.IO.Path]::GetTempPath()) "codex-local-compact"
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null

    $id = [guid]::NewGuid().ToString("N")
    $promptFile = Join-Path $runDir "$id.prompt.txt"
    $stdoutFile = Join-Path $runDir "$id.stdout.txt"
    $stderrFile = Join-Path $runDir "$id.stderr.txt"

    $Prompt | Set-Content -LiteralPath $promptFile -Encoding UTF8
    $argText = ($ArgList | ForEach-Object { Quote-Arg $_ }) -join " "

    $proc = Start-Process -FilePath $FilePath `
        -ArgumentList $argText `
        -RedirectStandardInput $promptFile `
        -RedirectStandardOutput $stdoutFile `
        -RedirectStandardError $stderrFile `
        -PassThru `
        -WindowStyle Hidden

    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try {
            $proc.Kill($true)
        } catch {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
        return @{ ExitCode = 124; Text = "Timed out after $TimeoutSec seconds." }
    }

    $stdout = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -Raw -LiteralPath $stdoutFile -Encoding UTF8 } else { "" }
    $stderr = if (Test-Path -LiteralPath $stderrFile) { Get-Content -Raw -LiteralPath $stderrFile -Encoding UTF8 } else { "" }
    $proc.Refresh()
    $exitCode = $proc.ExitCode
    if ($null -eq $exitCode -and $stdout.Trim()) {
        $exitCode = 0
    }
    Remove-Item -LiteralPath $promptFile, $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    return @{ ExitCode = $exitCode; Text = ($stdout + "`n" + $stderr).Trim() }
}

function Invoke-Compactor([string]$Prompt, [string]$SystemPrompt, [string]$Provider) {
    $defaultClaude = Join-Path $env:APPDATA "npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"
    if (-not (Test-Path -LiteralPath $defaultClaude)) {
        $defaultClaude = (Get-Command claude -ErrorAction Stop).Source
    }

    if ($Provider -eq "deepseek") {
        $key = [Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "User")
        if (-not $key -or -not (Test-Path -LiteralPath $defaultClaude)) {
            return @{ ExitCode = 1; Text = "DeepSeek fallback is not configured." }
        }

        $oldBase = $env:ANTHROPIC_BASE_URL
        $oldToken = $env:ANTHROPIC_AUTH_TOKEN
        $oldModel = $env:ANTHROPIC_MODEL
        try {
            $env:ANTHROPIC_BASE_URL = "https://api.deepseek.com/anthropic"
            $env:ANTHROPIC_AUTH_TOKEN = $key
            $env:ANTHROPIC_MODEL = "deepseek-v4-pro[1m]"
            $argv = @("-p", "--setting-sources", "project,local", "--model", "deepseek-v4-pro[1m]", "--system-prompt", $SystemPrompt, "--tools", "", "--no-session-persistence", "--output-format", "json")
            return Invoke-CommandWithInput $Prompt $defaultClaude $argv $ModelTimeoutSec
        } finally {
            $env:ANTHROPIC_BASE_URL = $oldBase
            $env:ANTHROPIC_AUTH_TOKEN = $oldToken
            $env:ANTHROPIC_MODEL = $oldModel
        }
    }

    $argv = @("-p", "--setting-sources", "user", "--model", "mimo-v2.5-pro", "--system-prompt", $SystemPrompt, "--tools", "", "--no-session-persistence", "--output-format", "json")
    return Invoke-CommandWithInput $Prompt $defaultClaude $argv $ModelTimeoutSec
}

function Parse-ModelJson([string]$Raw) {
    $outer = $Raw | ConvertFrom-Json
    $body = if ($outer.result) { $outer.result } else { $Raw }
    $json = Strip-Fence $body
    try {
        return $json | ConvertFrom-Json
    } catch {
        $start = $json.IndexOf("{")
        $end = $json.LastIndexOf("}")
        if ($start -ge 0 -and $end -gt $start) {
            return $json.Substring($start, $end - $start + 1) | ConvertFrom-Json
        }
        throw
    }
}

function Write-RawAttempt([string]$BaseDir, [string]$Provider, $Attempt) {
    New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
    $path = Join-Path $BaseDir "last-$Provider-raw.txt"
    @(
        "exit_code=$($Attempt.ExitCode)"
        "generated_at=$((Get-Date).ToString("o"))"
        ""
        $Attempt.Text
    ) -join "`n" | Set-Content -LiteralPath $path -Encoding UTF8
}

function Format-Value($Value) {
    if ($null -eq $Value) {
        return "- None"
    }
    if ($Value -is [string] -or $Value -is [System.ValueType]) {
        return [string]$Value
    }
    if ($Value -is [System.Array]) {
        if ($Value.Count -eq 0) {
            return "- None"
        }
        return (($Value | ForEach-Object {
            if ($_ -is [string] -or $_ -is [System.ValueType]) {
                "- $_"
            } elseif ($_ -is [pscustomobject]) {
                "- " + (($_.PSObject.Properties | ForEach-Object { "$($_.Name): $($_.Value)" }) -join "; ")
            } else {
                "- $_"
            }
        }) -join "`n")
    }
    if ($Value -is [pscustomobject]) {
        return (($Value.PSObject.Properties | ForEach-Object { "- $($_.Name): $($_.Value)" }) -join "`n")
    }
    return [string]$Value
}

function Write-Outputs($Summary, [string]$Provider, [string]$SourcePath, [string]$SessionId, [string]$Thread, [string]$TriggerName, [string]$BaseDir) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $safeThread = if ($Thread) { $Thread } elseif ($SessionId) { $SessionId } else { "unknown-thread" }
    $threadDir = Join-Path $BaseDir "threads\$safeThread"
    New-Item -ItemType Directory -Force -Path $threadDir | Out-Null

    $record = [ordered]@{
        generated_at = (Get-Date).ToString("o")
        provider = $Provider
        trigger = $TriggerName
        source_session = $SourcePath
        session_id = $SessionId
        thread_id = $safeThread
        summary = $Summary
    }

    $json = $record | ConvertTo-Json -Depth 18
    $jsonPath = Join-Path $threadDir "$stamp-$TriggerName.json"
    $latestJson = Join-Path $threadDir "latest.json"
    $json | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    $json | Set-Content -LiteralPath $latestJson -Encoding UTF8

    $md = @(
        "# Local Codex Compaction"
        ""
        "- Generated: $($record.generated_at)"
        "- Provider: $Provider"
        "- Trigger: $TriggerName"
        "- Source session: $SourcePath"
        ""
        "## Current Goal"
        (Format-Value $Summary.current_goal)
        ""
        "## Hard Constraints"
        (Format-Value $Summary.hard_constraints)
        ""
        "## User Preferences"
        (Format-Value $Summary.user_preferences)
        ""
        "## Established Facts"
        (Format-Value $Summary.established_facts)
        ""
        "## Completed Work"
        (Format-Value $Summary.completed_work)
        ""
        "## Files Or Config Changed"
        (Format-Value $Summary.files_or_config_changed)
        ""
        "## Failed Or Weak Attempts"
        (Format-Value $Summary.failed_or_weak_attempts)
        ""
        "## Open Questions"
        (Format-Value $Summary.open_questions)
        ""
        "## Next Actions"
        (Format-Value $Summary.next_actions)
        ""
        "## Resume Note"
        (Format-Value $Summary.resume_note)
    ) -join "`n"

    $mdPath = Join-Path $threadDir "$stamp-$TriggerName.md"
    $latestMd = Join-Path $threadDir "latest.md"
    $globalLatest = Join-Path $BaseDir "latest.md"
    $md | Set-Content -LiteralPath $mdPath -Encoding UTF8
    $md | Set-Content -LiteralPath $latestMd -Encoding UTF8
    $md | Set-Content -LiteralPath $globalLatest -Encoding UTF8

    $log = Join-Path $BaseDir "events.jsonl"
    ([ordered]@{
        generated_at = $record.generated_at
        provider = $Provider
        trigger = $TriggerName
        source_session = $SourcePath
        markdown = $mdPath
        json = $jsonPath
    } | ConvertTo-Json -Compress) | Add-Content -LiteralPath $log -Encoding UTF8

    return @{
        status = "ok"
        provider = $Provider
        markdown = $mdPath
        json = $jsonPath
        latest = $globalLatest
    }
}

$stdinText = Read-RedirectedInput
if (-not $Force -and $Trigger -eq "prompt" -and -not (Test-Trigger $stdinText)) {
    exit 0
}

try {
    if (-not $ThreadId) {
        $ThreadId = Find-FirstUuid $stdinText
    }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $SessionPath = Find-SessionPath $SessionPath $ThreadId $CodexHome
    $bundle = Build-Transcript $SessionPath $MaxChars
    if (-not $ThreadId) {
        $ThreadId = $bundle.SessionId
    }

    $system = "You are a strict local context compaction engine for Codex. Return only a valid JSON object. No markdown. No prose outside JSON. Preserve user intent, hard constraints, durable preferences, tool results, file/config edits, failed attempts, uncertainties, and the exact next action. Do not add new requirements or invented facts."

    $prompt = @"
Compress this Codex transcript into JSON with exactly these keys:
current_goal, hard_constraints, user_preferences, established_facts, completed_work, files_or_config_changed, failed_or_weak_attempts, open_questions, next_actions, resume_note.

Context:
- trigger: $Trigger
- source_session: $SessionPath
- thread_id: $ThreadId

Transcript:
$($bundle.Text)
"@

    $provider = "mimo"
    $raw = Invoke-Compactor $prompt $system $provider
    Write-RawAttempt $OutDir $provider $raw
    $summary = $null

    if ($raw.ExitCode -eq 0 -and $raw.Text.Trim()) {
        try {
            $summary = Parse-ModelJson $raw.Text
        } catch {
            $_.Exception.Message | Set-Content -LiteralPath (Join-Path $OutDir "last-$provider-parse-error.txt") -Encoding UTF8
            $summary = $null
        }
    }

    if ($null -eq $summary -and $raw.ExitCode -ne 124) {
        $provider = "deepseek"
        $raw = Invoke-Compactor $prompt $system $provider
        Write-RawAttempt $OutDir $provider $raw
        if ($raw.ExitCode -eq 0 -and $raw.Text.Trim()) {
            try {
                $summary = Parse-ModelJson $raw.Text
            } catch {
                $_.Exception.Message | Set-Content -LiteralPath (Join-Path $OutDir "last-$provider-parse-error.txt") -Encoding UTF8
                $summary = $null
            }
        }
    }

    if ($null -eq $summary) {
        throw "Local compaction model did not return parseable JSON."
    }

    $result = Write-Outputs $summary $provider $SessionPath $bundle.SessionId $ThreadId $Trigger $OutDir
    $result | ConvertTo-Json -Compress
} catch {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    ([ordered]@{
        generated_at = (Get-Date).ToString("o")
        trigger = $Trigger
        status = "error"
        message = $_.Exception.Message
    } | ConvertTo-Json -Compress) | Add-Content -LiteralPath (Join-Path $OutDir "events.jsonl") -Encoding UTF8
    if ($Force -or $Trigger -ne "prompt") {
        ([ordered]@{ status = "error"; message = $_.Exception.Message } | ConvertTo-Json -Compress)
    }
    exit 0
}
