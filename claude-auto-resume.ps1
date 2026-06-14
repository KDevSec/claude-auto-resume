#!/usr/bin/env pwsh
<#
.SYNOPSIS
Enhanced Auto-resume script for Claude CLI tasks (PowerShell)
Supports multiple session discovery and parallel resume.

.NOTES
Version: 2.0.0
Based on original by terryso, enhanced with multi-session support.
#>
$ErrorActionPreference = 'Stop'
$VERSION = '2.0.0'
$DEFAULT_PROMPT = 'continue'
$USE_CONTINUE_FLAG = $false
$USE_RESUME_FLAG = $false
$RESUME_TARGET = ''        # session ID or name to resume
$DISCOVER_MODE = $false    # --discover: list all sessions
$RESUME_ALL_MODE = $false  # --resume-all: resume all discovered sessions
$PARALLEL_MODE = $false    # --parallel: resume sessions in parallel (default: sequential)
$EXECUTE_MODE = $false
$CUSTOM_COMMAND = ''
$TEST_MODE = $false
$TEST_WAIT_SECONDS = 0
$script:CLEANUP_DONE = $false
$script:CLAUDE_PROCESS = $null

# ============================================================
# Utility Functions
# ============================================================

function Cleanup-Resources {
    if ($script:CLEANUP_DONE) { return }
    if ($script:CLAUDE_PROCESS -and -not $script:CLAUDE_PROCESS.HasExited) {
        try { $script:CLAUDE_PROCESS.Kill() } catch {}
        Start-Sleep -Seconds 1
        try {
            if (-not $script:CLAUDE_PROCESS.HasExited) {
                $script:CLAUDE_PROCESS.Kill()
            }
        } catch {}
    }
    $script:CLAUDE_PROCESS = $null
    $script:CLEANUP_DONE = $true
}

function On-CtrlC {
    Write-Host ""
    Write-Host "[INFO] Script interrupted by user (Ctrl+C)"
    Write-Host "[INFO] Cleaning up and exiting gracefully..."
    Cleanup-Resources
    exit 130
}

$null = Register-EngineEvent -SourceIdentifier Console_CancelKeyPress -Action { On-CtrlC }

function Show-Help {
    @"
claude-auto-resume v$VERSION — Enhanced Edition
=================================================
Automatically resume Claude CLI tasks after usage limits are lifted.
Supports multiple sessions: discover, resume specific, or resume ALL.

USAGE:
    claude-auto-resume [OPTIONS] [PROMPT]

CORE OPTIONS:
    -p, --prompt PROMPT      Custom prompt (default: "continue")
    -c, --continue           Continue the most recent conversation
    -h, --help               Show this help
    -v, --version            Show version information
    --check                  Show system check information
    --test-mode SECONDS      [DEV] Simulate usage limit wait

CUSTOM COMMAND:
    -e, --execute COMMAND    Execute custom command after wait period
    --cmd COMMAND            Alias for -e

SESSION MANAGEMENT (NEW in v2.0):
    --resume <name|id>       Resume a specific session by name or session ID
    --discover               List all saved sessions in current project
    --resume-all             Auto-discover and resume ALL sessions in this project
    --parallel               (With --resume-all) Resume sessions in parallel
    --show-names             Show session display names alongside IDs
    --prompt-all PROMPT      Custom prompt for --resume-all (default: "continue")

EXAMPLES:
    # Basic: resume the most recent session
    claude-auto-resume -c "continue task"

    # Resume a specific named session
    claude-auto-resume --resume "auth-module"

    # Resume by session ID
    claude-auto-resume --resume "abc123de-f456-7890-abcd-ef1234567890"

    # Discover all sessions in this project
    claude-auto-resume --discover

    # Resume ALL sessions after limit lifts (sequential)
    claude-auto-resume --resume-all

    # Resume ALL sessions in parallel
    claude-auto-resume --resume-all --parallel

    # Resume all with custom prompt
    claude-auto-resume --resume-all --prompt-all "pick up where you left off"

    # Execute custom command after limit
    claude-auto-resume -e "npm run build"

    # DEV: test with 10s wait
    claude-auto-resume --test-mode 10 --resume-all
"@ | Write-Host
}

function Check-NetworkConnectivity {
    try {
        if (Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue) { return $true }
        if (Test-Connection -ComputerName 1.1.1.1 -Count 1 -Quiet -ErrorAction SilentlyContinue) { return $true }
    } catch {}
    try {
        $null = Invoke-WebRequest -Uri 'https://www.google.com' -UseBasicParsing -TimeoutSec 5
        return $true
    } catch {}
    return $false
}

function Validate-ClaudeCLI {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Host "[ERROR] Claude CLI not found. Please install Claude CLI first."
        exit 1
    }
    try {
        $help = & claude --help 2>$null
        if ($help -notmatch 'dangerously-skip-permissions') {
            Write-Host "[WARNING] Your Claude CLI may not support --dangerously-skip-permissions."
        }
    } catch {}
}

function Invoke-ProcessWithTimeout {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 300
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($Arguments -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $null = $p.Start()
    $script:CLAUDE_PROCESS = $p
    if ($TimeoutSeconds -le 0) {
        $p.WaitForExit()
    } else {
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            try { $p.Kill() } catch {}
            return @{ ExitCode = 124; Output = ($p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()) }
        }
    }
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    return @{ ExitCode = $p.ExitCode; Output = ($out + $err) }
}

function Execute-CustomCommand {
    param([string]$Command)
    Write-Host "WARNING: About to execute custom command: '$Command'"
    Write-Host "WARNING: Press Ctrl+C within 5 seconds to cancel..."
    for ($i = 5; $i -ge 1; $i--) {
        Write-Host -NoNewline ("`rExecuting in {0} seconds... " -f $i)
        Start-Sleep -Seconds 1
    }
    Write-Host ""
    $start = Get-Date
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $Command) -Wait -PassThru -NoNewWindow
    $exitCode = $proc.ExitCode
    $duration = (Get-Date) - $start
    Write-Host (">> Command finished in {0}s, exit code: {1}" -f [int]$duration.TotalSeconds, $exitCode)
    return $exitCode
}

function Extract-OldFormatTimestamp {
    param([string]$ClaudeOutput)
    $parts = $ClaudeOutput -split '\|'
    if ($parts.Length -lt 2) {
        Write-Host "[ERROR] Failed to extract resume timestamp from Claude output."
        exit 2
    }
    $ts = $parts[1].Trim()
    if (-not ($ts -match '^[0-9]+$') -or [int64]$ts -le 0) {
        Write-Host "[ERROR] Invalid timestamp extracted: '$ts'"
        exit 2
    }
    return [int64]$ts
}

function Extract-NewFormatTimestamp {
    param([string]$ClaudeOutput)
    $m = [regex]::Match($ClaudeOutput, 'resets\s+(\d+)(am|pm)', 'IgnoreCase')
    if (-not $m.Success) {
        Write-Host "[ERROR] Failed to extract reset time from Claude output."
        exit 2
    }
    $hour = [int]$m.Groups[1].Value
    $period = $m.Groups[2].Value.ToLowerInvariant()
    if ($period -eq 'am') { if ($hour -eq 12) { $hour = 0 } }
    else { if ($hour -ne 12) { $hour += 12 } }
    $now = Get-Date
    $todayReset = $now.Date.AddHours($hour)
    if ($now -gt $todayReset) { $resume = $todayReset.AddDays(1) }
    else { $resume = $todayReset }
    return [int64]([DateTimeOffset]$resume).ToUnixTimeSeconds()
}

# ============================================================
# Session Discovery (NEW)
# ============================================================

function Get-ProjectEncodedPath {
    <#
    .SYNOPSIS
    Encode the current working directory path the way Claude Code does.
    Rule: replace \, /, : with -
    #>
    $cwd = (Get-Location).Path
    $encoded = $cwd -replace '[\\/:]', '-'
    return $encoded
}

function Get-ProjectSessionsDir {
    <#
    .SYNOPSIS
    Returns the ~/.claude/projects/<encoded-path> directory if it exists.
    #>
    $encodedPath = Get-ProjectEncodedPath
    $projectsDir = Join-Path $env:USERPROFILE '.claude\projects'
    $sessionDir = Join-Path $projectsDir $encodedPath
    if (Test-Path $sessionDir) {
        return $sessionDir
    }
    return $null
}

function Get-SessionName {
    <#
    .SYNOPSIS
    Try to resolve a human-readable session name for a given session ID.
    Checks session-env directory for metadata.
    #>
    param([string]$SessionId)
    
    # Try session-env metadata (newer Claude Code versions)
    $sessionEnvDir = Join-Path $env:USERPROFILE '.claude\session-env'
    if (Test-Path $sessionEnvDir) {
        $envFile = Join-Path $sessionEnvDir "$SessionId.json"
        if (Test-Path $envFile) {
            try {
                $envData = Get-Content $envFile -Raw | ConvertFrom-Json
                if ($envData.name) { return $envData.name }
                if ($envData.sessionName) { return $envData.sessionName }
            } catch {}
        }
    }

    # Try sessions directory metadata
    $sessionsDir = Join-Path $env:USERPROFILE '.claude\sessions'
    if (Test-Path $sessionsDir) {
        $metaFile = Join-Path $sessionsDir "$SessionId.json"
        if (Test-Path $metaFile) {
            try {
                $meta = Get-Content $metaFile -Raw | ConvertFrom-Json
                if ($meta.name) { return $meta.name }
                if ($meta.displayName) { return $meta.displayName }
            } catch {}
        }
    }

    # Try reading first line of jsonl for session metadata
    $sessionsDir = Get-ProjectSessionsDir
    if ($sessionsDir) {
        $jsonlFile = Join-Path $sessionsDir "$SessionId.jsonl"
        if (Test-Path $jsonlFile) {
            try {
                $firstLine = Get-Content $jsonlFile -First 1
                $obj = $firstLine | ConvertFrom-Json
                if ($obj.sessionName) { return $obj.sessionName }
                if ($obj.name) { return $obj.name }
            } catch {}
        }
    }

    return $null
}

function Get-AllSessions {
    <#
    .SYNOPSIS
    Discover all Claude Code sessions in the current project.
    Returns array of objects with: SessionId, Name, LastModified, Size, FirstPrompt
    #>
    $sessionDir = Get-ProjectSessionsDir
    if (-not $sessionDir) {
        Write-Host "[WARN] No Claude sessions found for current project."
        Write-Host "[INFO] Project encoded path: $(Get-ProjectEncodedPath)"
        Write-Host "[INFO] Looking in: ~/.claude/projects/"
        Write-Host "[HINT] Start a Claude CLI session in this directory first."
        return @()
    }

    $sessions = @()
    $jsonlFiles = Get-ChildItem -Path $sessionDir -Filter '*.jsonl' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending

    foreach ($file in $jsonlFiles) {
        $sessionId = $file.BaseName
        $name = Get-SessionName -SessionId $sessionId
        
        # Try to extract the first user prompt for context
        $firstPrompt = ''
        try {
            $lines = Get-Content $file.FullName -TotalCount 20
            foreach ($line in $lines) {
                try {
                    $obj = $line | ConvertFrom-Json
                    if ($obj.role -eq 'user' -and $obj.content) {
                        $content = if ($obj.content -is [string]) { $obj.content } 
                                   elseif ($obj.content.text) { $obj.content.text }
                                   else { '' }
                        $firstPrompt = ($content -replace '\n', ' ').Substring(0, [Math]::Min(80, $content.Length))
                        if ($firstPrompt.Length -eq 80) { $firstPrompt += '...' }
                        break
                    }
                } catch {}
            }
        } catch {}

        $sessions += [PSCustomObject]@{
            SessionId    = $sessionId
            Name         = if ($name) { $name } else { '(unnamed)' }
            LastModified = $file.LastWriteTime
            SizeKB       = [math]::Round($file.Length / 1024, 1)
            FirstPrompt  = if ($firstPrompt) { $firstPrompt } else { '(no content)' }
        }
    }

    return $sessions
}

function Show-DiscoveredSessions {
    <#
    .SYNOPSIS
    Pretty-print all sessions in the current project.
    #>
    $sessions = Get-AllSessions
    if ($sessions.Count -eq 0) {
        Write-Host "No Claude Code sessions found in this project."
        return @()
    }

    Write-Host ""
    Write-Host "========================================"
    Write-Host " Sessions in current project"
    Write-Host "========================================"
    Write-Host ("Project: {0}" -f (Get-Location).Path)
    Write-Host ("Encoded: {0}" -f (Get-ProjectEncodedPath))
    Write-Host ("Total:   {0} session(s)" -f $sessions.Count)
    Write-Host "========================================"
    Write-Host ""

    $index = 1
    foreach ($s in $sessions) {
        $nameStr = if ($s.Name -ne '(unnamed)') { " [$($s.Name)]" } else { '' }
        Write-Host ("[{0}] {1}{2}" -f $index, $s.SessionId, $nameStr) -ForegroundColor Cyan
        Write-Host ("    Modified : {0:yyyy-MM-dd HH:mm:ss}" -f $s.LastModified)
        Write-Host ("    Size     : {0} KB" -f $s.SizeKB)
        Write-Host ("    Prompt   : {0}" -f $s.FirstPrompt)
        Write-Host ("    Command  : claude-auto-resume --resume `"{0}`"" -f $s.SessionId) -ForegroundColor Green
        Write-Host ""
        $index++
    }

    Write-Host "========================================"
    Write-Host " Resume Commands"
    Write-Host "========================================"
    Write-Host ""
    Write-Host "# Resume a specific session:"
    foreach ($s in $sessions) {
        if ($s.Name -ne '(unnamed)') {
            Write-Host ("  claude-auto-resume --resume `"{0}`"" -f $s.Name) -ForegroundColor Green
        }
    }
    Write-Host ""
    Write-Host "# Resume ALL sessions (after limit resets):"
    Write-Host "  claude-auto-resume --resume-all" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "# Resume ALL in parallel:"
    Write-Host "  claude-auto-resume --resume-all --parallel" -ForegroundColor Yellow

    return $sessions
}

# ============================================================
# Multi-Session Resume Engine (NEW)
# ============================================================

function Start-SingleClaudeResume {
    <#
    .SYNOPSIS
    Start a single claude --resume <id> process.
    #>
    param(
        [string]$SessionId,
        [string]$Prompt = $DEFAULT_PROMPT
    )
    Write-Host ("[RESUME] Starting session: {0}" -f $SessionId) -ForegroundColor Cyan
    $res = Invoke-ProcessWithTimeout -FilePath 'claude' `
        -Arguments @('--resume', $SessionId, '--dangerously-skip-permissions', '-p', $Prompt) `
        -TimeoutSeconds 0
    Write-Host ("[RESUME] Session {0} finished (exit code: {1})" -f $SessionId, $res.ExitCode)
    return $res
}

function Start-ParallelClaudeResume {
    <#
    .SYNOPSIS
    Start multiple claude --resume processes in parallel using PowerShell Jobs.
    #>
    param(
        [array]$Sessions,
        [string]$Prompt = $DEFAULT_PROMPT
    )
    Write-Host ""
    Write-Host ("[PARALLEL] Launching {0} sessions in parallel..." -f $Sessions.Count) -ForegroundColor Yellow
    
    $jobs = @()
    foreach ($s in $Sessions) {
        $sid = $s.SessionId
        $job = Start-Job -Name "claude-$sid" -ScriptBlock {
            param($sid, $prompt)
            & claude --resume $sid --dangerously-skip-permissions -p $prompt *>&1
        } -ArgumentList $sid, $Prompt
        $jobs += $job
        Write-Host ("  [+] Started: {0} (Job ID: {1})" -f $sid, $job.Id) -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "[PARALLEL] Waiting for all sessions to complete..." -ForegroundColor Yellow
    Write-Host "[PARALLEL] Tip: Use 'Get-Job' to monitor progress in another terminal."
    Write-Host ""

    # Wait for all jobs
    $jobs | ForEach-Object {
        $null = $_ | Wait-Job
        $output = $_ | Receive-Job
        Write-Host ("[DONE] Session job {0} completed." -f $_.Id) -ForegroundColor Green
        $_ | Remove-Job
    }

    Write-Host "[PARALLEL] All sessions completed." -ForegroundColor Green
}

function Start-SequentialClaudeResume {
    <#
    .SYNOPSIS
    Start multiple claude --resume processes one at a time.
    #>
    param(
        [array]$Sessions,
        [string]$Prompt = $DEFAULT_PROMPT
    )
    Write-Host ""
    Write-Host ("[SEQUENTIAL] Resuming {0} sessions one by one..." -f $Sessions.Count) -ForegroundColor Yellow
    Write-Host ""

    $total = $Sessions.Count
    $current = 0
    foreach ($s in $Sessions) {
        $current++
        Write-Host ("[{0}/{1}] Resuming session: {2}" -f $current, $total, $s.SessionId) -ForegroundColor Cyan
        if ($s.Name -ne '(unnamed)') {
            Write-Host ("        Name: {0}" -f $s.Name)
        }
        $res = Start-SingleClaudeResume -SessionId $s.SessionId -Prompt $Prompt
        if ($res.ExitCode -ne 0) {
            Write-Host ("        [WARN] Session exited with code {0}" -f $res.ExitCode) -ForegroundColor Yellow
        }
        Write-Host ""
    }
    Write-Host "[SEQUENTIAL] All {0} sessions processed." -f $total -ForegroundColor Green
}

# ============================================================
# Main Execution
# ============================================================

try {
    # ---- Parse Arguments ----
    $CUSTOM_PROMPT = $DEFAULT_PROMPT
    $PROMPT_ALL = $DEFAULT_PROMPT

    if ($args.Count -eq 0 -and -not $DISCOVER_MODE) {
        Show-Help
        exit 0
    }

    for ($i = 0; $i -lt $args.Count; $i++) {
        $arg = $args[$i]
        switch ($arg) {
            '-p'              { if ($i+1 -ge $args.Count) { Write-Host "[ERROR] -p requires a prompt."; exit 1 }
                                $CUSTOM_PROMPT = $args[$i+1]; $i++ }
            '--prompt'        { if ($i+1 -ge $args.Count) { Write-Host "[ERROR] --prompt requires a prompt."; exit 1 }
                                $CUSTOM_PROMPT = $args[$i+1]; $i++ }
            '--prompt-all'    { if ($i+1 -ge $args.Count) { Write-Host "[ERROR] --prompt-all requires a prompt."; exit 1 }
                                $PROMPT_ALL = $args[$i+1]; $i++ }
            '-c'              { $USE_CONTINUE_FLAG = $true }
            '--continue'      { $USE_CONTINUE_FLAG = $true }
            '--resume'        { if ($i+1 -ge $args.Count) { Write-Host "[ERROR] --resume requires a session name or ID."; exit 1 }
                                $USE_RESUME_FLAG = $true; $RESUME_TARGET = $args[$i+1]; $i++ }
            '--discover'      { $DISCOVER_MODE = $true }
            '--show-names'    { }  # no-op, names shown by default
            '--resume-all'    { $RESUME_ALL_MODE = $true }
            '--parallel'      { $PARALLEL_MODE = $true }
            '-e'              { if ($i+1 -ge $args.Count) { Write-Host "[ERROR] -e requires a command."; exit 1 }
                                $EXECUTE_MODE = $true; $CUSTOM_COMMAND = $args[$i+1]; $i++ }
            '--execute'       { if ($i+1 -ge $args.Count) { Write-Host "[ERROR] --execute requires a command."; exit 1 }
                                $EXECUTE_MODE = $true; $CUSTOM_COMMAND = $args[$i+1]; $i++ }
            '--cmd'           { if ($i+1 -ge $args.Count) { Write-Host "[ERROR] --cmd requires a command."; exit 1 }
                                $EXECUTE_MODE = $true; $CUSTOM_COMMAND = $args[$i+1]; $i++ }
            '-h'              { Show-Help; exit 0 }
            '--help'          { Show-Help; exit 0 }
            '-v'              { Write-Host "claude-auto-resume v$VERSION (Enhanced)"; exit 0 }
            '--version'       { Write-Host "claude-auto-resume v$VERSION (Enhanced)"; exit 0 }
            '--test-mode'     { if ($i+1 -ge $args.Count -or -not ($args[$i+1] -match '^[0-9]+$')) {
                                    Write-Host "[ERROR] --test-mode requires a valid number of seconds."; exit 1 }
                                $TEST_MODE = $true; $TEST_WAIT_SECONDS = [int]$args[$i+1]; $i++ }
            '--check'         {
                Write-Host "claude-auto-resume v$VERSION (Enhanced) — System Check"
                Write-Host "=========================================================="
                Write-Host ""
                Write-Host "Script Information:"
                Write-Host "  Version: $VERSION"
                Write-Host "  Location: $PSCommandPath"
                Write-Host ""
                Write-Host "Claude CLI:"
                $cmd = Get-Command claude -ErrorAction SilentlyContinue
                if ($cmd) { Write-Host "  Status: Available ($($cmd.Source))" }
                else { Write-Host "  Status: NOT FOUND" }
                Write-Host ""
                Write-Host "Session Storage:"
                $sessionDir = Get-ProjectSessionsDir
                if ($sessionDir) { Write-Host "  Project dir: $sessionDir" }
                else { Write-Host "  Project dir: NOT FOUND (try starting a Claude session first)" }
                $allSessions = Get-AllSessions
                Write-Host ("  Total sessions: {0}" -f $allSessions.Count)
                foreach ($s in $allSessions) {
                    $nameStr = if ($s.Name -ne '(unnamed)') { " [$($s.Name)]" } else { '' }
                    Write-Host ("    - {0}{1}" -f $s.SessionId, $nameStr)
                }
                Write-Host ""
                Write-Host "System:"
                Write-Host ("  OS: {0}" -f [System.Environment]::OSVersion.VersionString)
                Write-Host ("  Shell: {0} PowerShell {1}" -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
                exit 0
            }
            default           {
                if ($arg -like '-*') {
                    Write-Host "Unknown option: $arg"
                    Show-Help
                    exit 1
                }
                $CUSTOM_PROMPT = $arg
            }
        }
    }

    # ---- Validation ----
    if ($EXECUTE_MODE -and ($USE_CONTINUE_FLAG -or $USE_RESUME_FLAG -or $RESUME_ALL_MODE)) {
        Write-Host "[ERROR] Cannot combine -e/--execute with session resume options."
        exit 1
    }

    # ---- Discovery Mode (no wait, just list) ----
    if ($DISCOVER_MODE) {
        $null = Show-DiscoveredSessions
        exit 0
    }

    # ---- Validate Claude CLI ----
    if (-not $EXECUTE_MODE) {
        Validate-ClaudeCLI
    }

    # ---- Network Check ----
    Write-Host "Checking network connectivity..."
    if (-not (Check-NetworkConnectivity)) {
        Write-Host "[ERROR] Network connectivity check failed."
        exit 3
    }
    Write-Host "Network OK."

    # ---- Discover sessions if needed ----
    $TARGET_SESSIONS = @()
    
    if ($RESUME_ALL_MODE) {
        $TARGET_SESSIONS = Get-AllSessions
        if ($TARGET_SESSIONS.Count -eq 0) {
            Write-Host "[ERROR] No sessions found for --resume-all."
            Write-Host "[HINT] Create Claude sessions in this project first, then retry."
            exit 1
        }
        Write-Host ""
        Write-Host ("[RESUME-ALL] Found {0} session(s) in this project:" -f $TARGET_SESSIONS.Count) -ForegroundColor Yellow
        foreach ($s in $TARGET_SESSIONS) {
            $nameStr = if ($s.Name -ne '(unnamed)') { " [$($s.Name)]" } else { '' }
            Write-Host ("  • {0}{1}" -f $s.SessionId, $nameStr)
        }
        Write-Host ""
        if ($PARALLEL_MODE) {
            Write-Host "[RESUME-ALL] Mode: PARALLEL" -ForegroundColor Magenta
        } else {
            Write-Host "[RESUME-ALL] Mode: SEQUENTIAL" -ForegroundColor Cyan
        }
    }

    # ---- Execute claude check for usage limit ----
    $CLAUDE_OUTPUT = ''
    $RET_CODE = 0
    if ($EXECUTE_MODE) {
        Write-Host "Execute mode: Checking for usage limits..."
        if (Get-Command claude -ErrorAction SilentlyContinue) {
            $res = Invoke-ProcessWithTimeout -FilePath 'claude' -Arguments @('-p','check') -TimeoutSeconds 300
            $RET_CODE = $res.ExitCode
            $CLAUDE_OUTPUT = $res.Output
        } else {
            Write-Host "[WARNING] Claude CLI not found. Skipping limit check."
            $RET_CODE = 0
            $CLAUDE_OUTPUT = ''
        }
    } else {
        Write-Host "Checking Claude usage limit..."
        $res = Invoke-ProcessWithTimeout -FilePath 'claude' -Arguments @('-p','check') -TimeoutSeconds 300
        $RET_CODE = $res.ExitCode
        $CLAUDE_OUTPUT = $res.Output
    }

    if ($RET_CODE -eq 124) {
        if ($EXECUTE_MODE) {
            Write-Host "[WARNING] Claude check timed out. Proceeding without limit detection."
        } else {
            Write-Host "[ERROR] Claude CLI operation timed out after 300 seconds."
            exit 3
        }
    }

    # ---- Detect usage limit message ----
    $LIMIT_MSG = ''
    $limitPattern = '(?i)(usage limit|limit reached|hit your limit).*resets'
    $resetPattern = '(?i)resets\s+\d+(am|pm)'
    if ($CLAUDE_OUTPUT -match $limitPattern -or $CLAUDE_OUTPUT -match $resetPattern) {
        $LIMIT_MSG = $CLAUDE_OUTPUT
    }

    if ($TEST_MODE) {
        Write-Host "[TEST MODE] Simulating usage limit with ${TEST_WAIT_SECONDS}s wait..."
        $LIMIT_MSG = 'Claude AI usage limit reached|simulated'
    }

    # ---- Wait for limit to reset ----
    if ($LIMIT_MSG) {
        if ($TEST_MODE) {
            $nowTs = [DateTimeOffset]::Now.ToUnixTimeSeconds()
            $resumeTs = $nowTs + $TEST_WAIT_SECONDS
            $waitSeconds = $TEST_WAIT_SECONDS
        } else {
            if ($CLAUDE_OUTPUT -match 'Claude AI usage limit reached\|') {
                $resumeTs = Extract-OldFormatTimestamp -ClaudeOutput $CLAUDE_OUTPUT
            } else {
                $resumeTs = Extract-NewFormatTimestamp -ClaudeOutput $CLAUDE_OUTPUT
            }
            $nowTs = [DateTimeOffset]::Now.ToUnixTimeSeconds()
            $waitSeconds = [int]($resumeTs - $nowTs)
        }

        if ($waitSeconds -le 0) {
            Write-Host "Resume time has arrived. Retrying now."
        } else {
            $resumeTime = [DateTimeOffset]::FromUnixTimeSeconds($resumeTs).LocalDateTime
            Write-Host ("Claude usage limit detected. Waiting until {0:yyyy-MM-dd HH:mm:ss}..." -f $resumeTime)
            while ($waitSeconds -gt 0) {
                $h = [int]($waitSeconds / 3600)
                $m = [int](($waitSeconds % 3600) / 60)
                $s = [int]($waitSeconds % 60)
                $info = if ($RESUME_ALL_MODE) {
                    " | {0} session(s) queued" -f $TARGET_SESSIONS.Count
                } else { '' }
                Write-Host -NoNewline ("`rResuming in {0:00}:{1:00}:{2:00}{3}..." -f $h, $m, $s, $info)
                Start-Sleep -Seconds 1
                $nowTs = [DateTimeOffset]::Now.ToUnixTimeSeconds()
                $waitSeconds = [int]($resumeTs - $nowTs)
            }
            Write-Host ""
            Write-Host "[INFO] Resume time reached. Starting tasks..." -ForegroundColor Green
        }

        Start-Sleep -Seconds 5

        # Re-check network
        if (-not $EXECUTE_MODE) {
            Write-Host "Re-checking network..."
            if (-not (Check-NetworkConnectivity)) {
                Write-Host "[ERROR] Network lost during wait period."
                exit 3
            }
        }

        # ---- Execute after limit reset ----
        if ($EXECUTE_MODE) {
            Write-Host "Executing custom command..."
            $exitCode2 = Execute-CustomCommand -Command $CUSTOM_COMMAND
            exit $exitCode2
        }
        elseif ($RESUME_ALL_MODE) {
            # ---- RESUME ALL: Sequential or Parallel ----
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Yellow
            Write-Host " RESUME-ALL: Starting all sessions" -ForegroundColor Yellow
            Write-Host "========================================" -ForegroundColor Yellow
            
            if ($PARALLEL_MODE) {
                Start-ParallelClaudeResume -Sessions $TARGET_SESSIONS -Prompt $PROMPT_ALL
            } else {
                Start-SequentialClaudeResume -Sessions $TARGET_SESSIONS -Prompt $PROMPT_ALL
            }
            Write-Host ""
            Write-Host "[RESUME-ALL] Complete. All sessions processed." -ForegroundColor Green
        }
        elseif ($USE_RESUME_FLAG) {
            # ---- RESUME specific session ----
            Write-Host ("Resuming specific session: {0}" -f $RESUME_TARGET) -ForegroundColor Cyan
            $res2 = Start-SingleClaudeResume -SessionId $RESUME_TARGET -Prompt $CUSTOM_PROMPT
            if ($res2.ExitCode -ne 0) {
                Write-Host "[ERROR] Session resume failed (exit code: $($res2.ExitCode))"
                exit 4
            }
            Write-Host "[OK] Session resumed successfully."
            Write-Host $res2.Output
        }
        else {
            # ---- Standard mode: new session or continue ----
            if ($USE_CONTINUE_FLAG) {
                Write-Host ("Continuing previous conversation: '{0}'" -f $CUSTOM_PROMPT)
                $res2 = Invoke-ProcessWithTimeout -FilePath 'claude' `
                    -Arguments @('-c','--dangerously-skip-permissions','-p',"$CUSTOM_PROMPT") `
                    -TimeoutSeconds 0
            } else {
                Write-Host ("Starting new session: '{0}'" -f $CUSTOM_PROMPT)
                $res2 = Invoke-ProcessWithTimeout -FilePath 'claude' `
                    -Arguments @('--dangerously-skip-permissions','-p',"$CUSTOM_PROMPT") `
                    -TimeoutSeconds 0
            }
            if ($res2.ExitCode -ne 0) {
                Write-Host "[ERROR] Claude CLI failed after resume."
                Write-Host "[DEBUG] Exit code: $($res2.ExitCode)"
                exit 4
            }
            Write-Host "[OK] Task completed."
            Write-Host $res2.Output
        }
        exit 0
    }

    # ---- No limit detected ----
    if ($RET_CODE -ne 0 -and -not $EXECUTE_MODE) {
        Write-Host "[ERROR] Claude CLI execution failed."
        Write-Host "[DEBUG] Exit code: $RET_CODE"
        Write-Host "[DEBUG] Output: $CLAUDE_OUTPUT"
        exit 1
    }

    if ($EXECUTE_MODE) {
        Write-Host "No usage limit detected. Custom command not executed."
        Write-Host "[INFO] Use -e only when you expect usage limits."
        exit 0
    }

    Write-Host "No usage limit detected. Task ready to proceed."
    exit 0

} finally {
    Cleanup-Resources
}
