#!/usr/bin/env pwsh
# =============================================================================
# GitLab — Container Management  (cross-platform PowerShell)
# Usage: ./gitlab-tfs.ps1 [-Setup|-Start|-Stop|-Restart|-Logs|-Status|-Backup|-Export|-Import|-CodeRabbit|-Destroy|-Help]
#        ./gitlab-tfs.ps1           (no args → interactive menu)
# =============================================================================
[CmdletBinding(DefaultParameterSetName = 'Menu')]
param(
    [Parameter(ParameterSetName = 'Setup',   Mandatory)][switch]$Setup,
    [Parameter(ParameterSetName = 'Start',   Mandatory)][switch]$Start,
    [Parameter(ParameterSetName = 'Stop',    Mandatory)][switch]$Stop,
    [Parameter(ParameterSetName = 'Restart', Mandatory)][switch]$Restart,
    [Parameter(ParameterSetName = 'Logs',    Mandatory)][switch]$Logs,
    [Parameter(ParameterSetName = 'Status',  Mandatory)][switch]$Status,
    [Parameter(ParameterSetName = 'Backup',  Mandatory)][switch]$Backup,
    [Parameter(ParameterSetName = 'Export',     Mandatory)][switch]$Export,
    [Parameter(ParameterSetName = 'Import',     Mandatory)][switch]$Import,
    [Parameter(ParameterSetName = 'Import',     Mandatory)][string]$File,
    [Parameter(ParameterSetName = 'CodeRabbit', Mandatory)][switch]$CodeRabbit,
    [Parameter(ParameterSetName = 'Destroy',    Mandatory)][switch]$Destroy,
    [Parameter(ParameterSetName = 'Help',    Mandatory)][switch]$Help
)
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir

# =============================================================================
# Helpers
# =============================================================================

function Find-ComposeCmd {
    try {
        docker compose version 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return 'docker compose' }
    } catch {}
    if (Get-Command docker-compose -ErrorAction SilentlyContinue) { return 'docker-compose' }
    Write-Host 'ERROR: Docker Compose not found' -ForegroundColor Red
    exit 1
}

function Invoke-Compose {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    if ($script:ComposeCmd -eq 'docker compose') { & docker compose @Arguments }
    else                                          { & docker-compose @Arguments }
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "docker compose exited with code $LASTEXITCODE" }
}

function Import-EnvFile {
    if (-not (Test-Path '.env')) { return }
    Get-Content '.env' | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            $parts = $line -split '=', 2
            if ($parts.Count -eq 2) {
                [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), 'Process')
            }
        }
    }
}

function Get-EnvOrDefault {
    param([string]$Name, [string]$Default)
    $val = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($val)) { $Default } else { $val }
}

function Open-BrowserUrl {
    param([string]$Url)
    if ($IsMacOS) {
        try { Start-Process 'open' -ArgumentList $Url -ErrorAction Stop; return $true } catch {}
        return $false
    }
    if (-not $IsLinux) {
        # Windows
        try { Start-Process $Url -ErrorAction Stop; return $true } catch {}
        return $false
    }
    # Linux: try real browser binaries first to avoid broken xdg/kde-open handlers
    foreach ($browser in @('google-chrome', 'google-chrome-stable', 'chromium-browser', 'chromium', 'firefox', 'brave-browser', 'microsoft-edge')) {
        $bin = Get-Command $browser -ErrorAction SilentlyContinue
        if ($bin) {
            try { Start-Process $bin.Source -ArgumentList $Url -ErrorAction Stop; return $true } catch {}
        }
    }
    # Last resort: xdg-open
    try { Start-Process 'xdg-open' -ArgumentList $Url -ErrorAction Stop; return $true } catch {}
    return $false
}

$script:ComposeCmd = Find-ComposeCmd
Import-EnvFile

# =============================================================================
# Commands
# =============================================================================

function Cmd-Setup {
    Write-Host ''
    Write-Host '=== GitLab Setup ===' -ForegroundColor Cyan
    Write-Host ''

    Write-Host '[1/3] Checking prerequisites...'
    foreach ($cmd in @('docker', 'git')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            Write-Host "  ERROR: '$cmd' is not installed." -ForegroundColor Red
            exit 1
        }
    }
    Write-Host "  Docker:  $(docker --version)"
    Write-Host "  Git:     $(git --version)"
    Write-Host ''

    Write-Host '[2/3] Setting up environment...'
    if (-not (Test-Path '.env')) {
        Copy-Item '.env.example' '.env'
        Write-Host '  Created .env from .env.example'
        Write-Host '  Edit .env and set at least GITLAB_ROOT_PASSWORD.' -ForegroundColor Yellow
    } else {
        Write-Host '  .env already exists, skipping'
    }
    Write-Host ''

    Write-Host '[3/3] Building GitLab image...'
    Invoke-Compose build --no-cache gitlab
    Write-Host '  Done'
    Write-Host ''
    Write-Host '=== Setup Complete ===' -ForegroundColor Green
    Write-Host 'Run "./gitlab-tfs.ps1 -Start" to start GitLab.'
    Write-Host ''
}

function Cmd-Start {
    Write-Host 'Starting GitLab (isolated container)...'
    Invoke-Compose up --detach --build
    $port = Get-EnvOrDefault 'GITLAB_HTTP_PORT' '8081'
    $url  = "http://localhost:$port"
    Write-Host ''
    Write-Host "GitLab is starting up (may take 3-5 minutes)."
    Write-Host "Access it at: $url"
    Write-Host 'Browser will open automatically once GitLab is ready.'
    Write-Host 'Monitor: ./gitlab-tfs.ps1 -Logs'

    # Detached process: poll readiness then open browser — survives parent script exit
    $pollScript = @"
`$readinessUrl = '$url/-/readiness'
`$deadline     = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt `$deadline) {
    try {
        `$resp = Invoke-WebRequest -Uri `$readinessUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if (`$resp.StatusCode -lt 500) { break }
    } catch {}
    Start-Sleep -Seconds 10
}
if (`$IsMacOS) {
    Start-Process 'open' -ArgumentList '$url'
} elseif (-not `$IsLinux) {
    Start-Process '$url'
} else {
    `$opened = `$false
    foreach (`$b in @('google-chrome','google-chrome-stable','chromium-browser','chromium','firefox','brave-browser','microsoft-edge')) {
        `$bin = Get-Command `$b -ErrorAction SilentlyContinue
        if (`$bin) { Start-Process `$bin.Source -ArgumentList '$url'; `$opened = `$true; break }
    }
    if (-not `$opened) { Start-Process 'xdg-open' -ArgumentList '$url' }
}
"@
    # Launch as a fully detached process so it survives this script exiting
    $encodedCmd = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($pollScript))
    if ($IsLinux -or $IsMacOS) {
        # Use nohup + sh to fully detach from parent process
        # Pass DISPLAY/WAYLAND_DISPLAY so the child can open a browser
        $pwshBin = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if (-not $pwshBin) { $pwshBin = 'pwsh' }
        $envPrefix = ''
        $disp = $env:DISPLAY
        $wdisp = $env:WAYLAND_DISPLAY
        if ($disp)  { $envPrefix += "DISPLAY=$disp " }
        if ($wdisp) { $envPrefix += "WAYLAND_DISPLAY=$wdisp " }
        & sh -c "nohup env $envPrefix $pwshBin -NoProfile -NonInteractive -EncodedCommand $encodedCmd </dev/null >/dev/null 2>&1 &"
    } else {
        $pwshBin = (Get-Process -Id $PID).Path
        if (-not $pwshBin) { $pwshBin = 'pwsh' }
        Start-Process -FilePath $pwshBin -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedCmd -WindowStyle Hidden
    }
}

function Cmd-Stop {
    Write-Host 'Stopping all services...'
    Invoke-Compose down
}

function Cmd-Restart {
    Write-Host 'Restarting GitLab...'
    Invoke-Compose restart
}

function Cmd-Logs {
    Invoke-Compose logs -f gitlab
}

function Cmd-Status {
    Write-Host ''
    Write-Host '=== GitLab Status ===' -ForegroundColor Cyan
    Invoke-Compose ps
    Write-Host ''
    $port = Get-EnvOrDefault 'GITLAB_HTTP_PORT' '8081'
    try {
        $null = Invoke-WebRequest -Uri "http://localhost:$port/-/readiness" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        Write-Host 'GitLab: HEALTHY' -ForegroundColor Green
    } catch {
        Write-Host 'GitLab: NOT READY (starting up or stopped)' -ForegroundColor Yellow
    }
    Write-Host ''
}

function Cmd-Backup {
    $ts        = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupDir = "backups/$ts"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    if (Test-Path '.env') {
        Copy-Item '.env' "$backupDir/.env"
        Write-Host "Saved: $backupDir/.env"
    }
    Write-Host "Backup complete: $backupDir"
}

function Cmd-Destroy {
    Write-Host ''
    Write-Host 'WARNING: This will remove the GitLab container and all its internal data!' -ForegroundColor Red
    $confirm = Read-Host "Type 'yes' to confirm"
    if ($confirm -eq 'yes') {
        Invoke-Compose down --rmi local
        Write-Host 'Container removed.'
    } else {
        Write-Host 'Aborted.'
    }
}

function Cmd-Export {
    $imageName = 'gitlab-gitlab:latest'
    $ts        = Get-Date -Format 'yyyyMMdd_HHmmss'
    $outFile   = "gitlab-image-$ts.tar.gz"

    # Verify image exists
    $exists = docker image inspect $imageName 2>$null
    if (-not $exists) {
        Write-Host "Image '$imageName' not found — run -Setup or -Start first." -ForegroundColor Red
        return
    }

    Write-Host "Exporting $imageName to $outFile ..."
    docker save $imageName | gzip > $outFile
    $sizeMB = [math]::Round((Get-Item $outFile).Length / 1MB, 1)
    Write-Host "Done: $outFile ($sizeMB MB)" -ForegroundColor Green
}

function Cmd-Import {
    param([string]$FilePath)

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        $FilePath = Read-Host 'Path to .tar.gz image file'
    }
    if (-not (Test-Path $FilePath)) {
        Write-Host "File not found: $FilePath" -ForegroundColor Red
        return
    }

    Write-Host "Importing image from $FilePath ..."
    if ($FilePath -match '\.gz$') {
        # Stream-decompress then load
        if ($IsLinux -or $IsMacOS) {
            & sh -c "gzip -dc '$FilePath' | docker load"
        } else {
            # Windows — use .NET GZipStream to avoid requiring gzip
            $inStream  = [System.IO.File]::OpenRead($FilePath)
            $gzStream  = [System.IO.Compression.GZipStream]::new($inStream, [System.IO.Compression.CompressionMode]::Decompress)
            $proc = Start-Process docker -ArgumentList 'load' -RedirectStandardInput $null -PassThru -NoNewWindow
            $gzStream.CopyTo($proc.StandardInput.BaseStream)
            $proc.WaitForExit()
            $gzStream.Dispose(); $inStream.Dispose()
        }
    } else {
        docker load --input $FilePath
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'Image imported successfully.' -ForegroundColor Green
    } else {
        Write-Host 'Import failed.' -ForegroundColor Red
    }
}

function Cmd-CodeRabbit {
    Write-Host ''
    Write-Host '=== CodeRabbit AI Review Setup ===' -ForegroundColor Cyan
    Write-Host ''

    # 1. Check GitLab health
    $port = Get-EnvOrDefault 'GITLAB_HTTP_PORT' '8081'
    $baseUrl = "http://localhost:$port"
    Write-Host '[1/3] Checking GitLab readiness...'
    try {
        $null = Invoke-WebRequest -Uri "$baseUrl/-/readiness" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        Write-Host '  GitLab is HEALTHY' -ForegroundColor Green
    } catch {
        Write-Host '  GitLab is NOT READY — start it first with -Start' -ForegroundColor Red
        return
    }
    Write-Host ''

    # 2. Create Personal Access Token via Rails console
    Write-Host '[2/3] Creating Personal Access Token (api scope)...'
    Write-Host '  This may take 30-60 s (Rails console startup)...' -ForegroundColor DarkGray
    $tokenName = "coderabbit-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $rubyCode = "u=User.find_by_username('root');" +
                "t=u.personal_access_tokens.create!(name:'$tokenName'," +
                "scopes:['api','read_user','read_repository']," +
                "expires_at:365.days.from_now);" +
                "puts('TOKEN:'+t.token)"

    $rawOutput = (docker exec gitlab-tfs-mirror gitlab-rails runner $rubyCode 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  Failed to create token:' -ForegroundColor Red
        Write-Host "  $rawOutput" -ForegroundColor Red
        return
    }

    if ($rawOutput -match 'TOKEN:([A-Za-z0-9_-]+)') {
        $pat = $matches[1]
    } else {
        Write-Host '  Could not parse token from Rails output.' -ForegroundColor Red
        Write-Host "  Output: $rawOutput" -ForegroundColor DarkGray
        return
    }
    Write-Host "  Token created: $tokenName" -ForegroundColor Green
    Write-Host ''

    # 3. Display setup instructions
    Write-Host '[3/3] Complete setup at CodeRabbit:' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  1. Open  https://app.coderabbit.ai  and sign up / log in'
    Write-Host '  2. Choose "Add Self-Managed GitLab"'
    Write-Host '  3. Enter the values below:'
    Write-Host ''
    Write-Host "     GitLab URL:    $baseUrl" -ForegroundColor White
    Write-Host "     Access Token:  $pat" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  CodeRabbit will auto-configure webhooks once connected.'
    Write-Host ''
    Write-Host '  NOTE: If this GitLab is not publicly accessible,' -ForegroundColor Yellow
    Write-Host '  expose it via a tunnel first:' -ForegroundColor Yellow
    Write-Host "    ngrok http $port"
    Write-Host '  Then use the ngrok URL as the GitLab URL.'
    Write-Host ''
    Write-Host '  Copy .coderabbit.yaml to each repo root to customize reviews.' -ForegroundColor Green
    Write-Host ''
}

# =============================================================================
# Interactive menu
# =============================================================================

function Show-Menu {
    Write-Host ''
    Write-Host '+==============================+' -ForegroundColor Cyan
    Write-Host '|   GitLab Container Manager   |' -ForegroundColor Cyan
    Write-Host '+==============================+' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  1) Setup    - First-time build'
    Write-Host '  2) Start    - Start container'
    Write-Host '  3) Stop     - Stop container'
    Write-Host '  4) Restart  - Restart container'
    Write-Host '  5) Logs     - View container logs'
    Write-Host '  6) Status   - Show health'
    Write-Host '  7) Backup   - Backup .env'
    Write-Host '  8) Export     - Save image to .tar.gz'
    Write-Host '  9) Import     - Load image from .tar.gz'
    Write-Host ' 10) CodeRabbit - Setup AI code review'
    Write-Host ' 11) Destroy    - Remove container'
    Write-Host '  0) Exit'
    Write-Host ''
}

function Start-InteractiveMenu {
    while ($true) {
        Show-Menu
        $choice = Read-Host '  Choose [0-11]'
        Write-Host ''
        if ($choice -eq '0') {
            Write-Host 'Bye.'
            exit 0
        }
        try {
            switch ($choice) {
                '1'  { Cmd-Setup }
                '2'  { Cmd-Start }
                '3'  { Cmd-Stop }
                '4'  { Cmd-Restart }
                '5'  { Cmd-Logs }
                '6'  { Cmd-Status }
                '7'  { Cmd-Backup }
                '8'  { Cmd-Export }
                '9'  { Cmd-Import }
                '10' { Cmd-CodeRabbit }
                '11' { Cmd-Destroy }
                default { Write-Host 'Invalid choice.' }
            }
        } catch {
            Write-Host "Error: $_" -ForegroundColor Red
        }
        Write-Host ''
        Read-Host 'Press Enter to continue...'
    }
}

# =============================================================================
# CLI entry point
# =============================================================================

switch ($PSCmdlet.ParameterSetName) {
    'Setup'   { Cmd-Setup }
    'Start'   { Cmd-Start }
    'Stop'    { Cmd-Stop }
    'Restart' { Cmd-Restart }
    'Logs'    { Cmd-Logs }
    'Status'  { Cmd-Status }
    'Backup'  { Cmd-Backup }
    'Export'     { Cmd-Export }
    'Import'     { Cmd-Import -FilePath $File }
    'CodeRabbit' { Cmd-CodeRabbit }
    'Destroy'    { Cmd-Destroy }
    'Help'       {
        Write-Host 'Usage: ./gitlab-tfs.ps1 [-Setup|-Start|-Stop|-Restart|-Logs|-Status|-Backup|-Export|-Import -File <path>|-CodeRabbit|-Destroy|-Help]'
        Write-Host '       ./gitlab-tfs.ps1   (no args — interactive menu)'
    }
    default   { Start-InteractiveMenu }
}
