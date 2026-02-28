#!/usr/bin/env pwsh
# =============================================================================
# GitLab — Container Management  (cross-platform PowerShell)
# Usage: ./gitlab-tfs.ps1 [-Setup|-Start|-Stop|-Restart|-Logs|-Status|-Backup|-Export|-Import|-CodeRabbit|-Tunnel|-Destroy|-Help]
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
    [Parameter(ParameterSetName = 'Tunnel',     Mandatory)][switch]$Tunnel,
    [Parameter(ParameterSetName = 'Destroy',    Mandatory)][switch]$Destroy,
    [Parameter(ParameterSetName = 'TFSSetup',   Mandatory)][switch]$TFSSetup,
    [Parameter(ParameterSetName = 'TFSStatus',  Mandatory)][switch]$TFSStatus,
    [Parameter(ParameterSetName = 'TFSSyncNow', Mandatory)][switch]$TFSSyncNow,
    [Parameter(ParameterSetName = 'TFSLogs',    Mandatory)][switch]$TFSLogs,
    [Parameter(ParameterSetName = 'OpenBrowser', Mandatory)][switch]$OpenBrowser,
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

# Update (or append) a single KEY=VALUE line in .env without destroying other entries
function Set-EnvValue {
    param([string]$Name, [string]$Value)
    $path = '.env'
    if (-not (Test-Path $path)) { return }
    $lines = Get-Content $path -Encoding UTF8
    $found = $false
    $lines = $lines | ForEach-Object {
        if ($_ -match "^${Name}=") { "${Name}=${Value}"; $found = $true }
        else { $_ }
    }
    if (-not $found) { $lines += "${Name}=${Value}" }
    $lines | Set-Content $path -Encoding UTF8
    # Reload into current process
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
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
`$pollUrl  = '$url/'
`$deadline = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt `$deadline) {
    `$code = (curl -s -o /dev/null -w '%{http_code}' -m 5 -L "`$pollUrl" 2>`$null)
    if (`$code -match '^\ *[1-4][0-9][0-9]\ *$') { break }
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
    $httpCode = (curl -s -o /dev/null -w '%{http_code}' -m 5 -L "http://localhost:$port/" 2>$null)
    if ($httpCode -match '^\s*[1-4][0-9][0-9]\s*$') {
        Write-Host 'GitLab: HEALTHY' -ForegroundColor Green
    } else {
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

# ---------------------------------------------------------------------------
# Shared helper: ensure tunnel is running and return its public URL.
# Returns $null and prints an error if the URL cannot be determined.
# ---------------------------------------------------------------------------
function Get-TunnelUrl {
    $running = docker ps --filter 'name=gitlab-tunnel' --format '{{.Status}}' 2>$null

    if (-not $running) {
        Write-Host '  Starting Cloudflare tunnel (cloudflared)...'
        if ($script:ComposeCmd -eq 'docker compose') {
            & docker compose --profile tunnel up --detach tunnel 2>&1 | Out-Null
        } else {
            & docker-compose --profile tunnel up --detach tunnel 2>&1 | Out-Null
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  ERROR: Failed to start tunnel container.' -ForegroundColor Red
            return $null
        }
        Write-Host '  Waiting for tunnel to establish (10 s)...' -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    } else {
        Write-Host '  Tunnel container is already running.' -ForegroundColor Green
    }

    # Try up to 2 times with a 10-second gap to read the URL from logs
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $logs = if ($script:ComposeCmd -eq 'docker compose') {
            (docker compose --profile tunnel logs tunnel 2>&1) -join "`n"
        } else {
            (docker-compose --profile tunnel logs tunnel 2>&1) -join "`n"
        }
        if ($logs -match '(https://[a-z0-9-]+\.trycloudflare\.com)') {
            return $matches[1]
        }
        if ($attempt -lt 2) {
            Write-Host '  URL not visible yet — retrying in 10 s...' -ForegroundColor DarkGray
            Start-Sleep -Seconds 10
        }
    }

    Write-Host '  ERROR: Could not detect tunnel URL from logs.' -ForegroundColor Red
    Write-Host '  Run "./gitlab-tfs.ps1 -Tunnel" to inspect manually.' -ForegroundColor DarkGray
    return $null
}

# ---------------------------------------------------------------------------
# Shared helper: test that a URL responds over HTTP (any status = success).
# Prints result; returns $true / $false.
# ---------------------------------------------------------------------------
function Test-UrlReachable {
    param([string]$Url)
    try {
        $curlOutput = (curl -s -o /dev/null -w '%{http_code}' -m 15 -L "$Url/" 2>&1)
        if ($curlOutput -match '(\d{3})' -and [int]$matches[1] -gt 0) { return $true }
    } catch {}
    try {
        $resp = Invoke-WebRequest -Uri "$Url/" -UseBasicParsing -TimeoutSec 15 `
                    -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction Stop
        return $true
    } catch {
        return ($null -ne $_.Exception.Response)
    }
}

function Cmd-CodeRabbit {
    Write-Host ''
    Write-Host '=== CodeRabbit AI Review Setup ===' -ForegroundColor Cyan
    Write-Host ''

    # ── Step 1: GitLab health ────────────────────────────────────────────────
    $port    = Get-EnvOrDefault 'GITLAB_HTTP_PORT' '8081'
    $localUrl = "http://localhost:$port"
    Write-Host '[1/4] Checking GitLab readiness...'
    $httpCode = (curl -s -o /dev/null -w '%{http_code}' -m 5 -L "$localUrl/" 2>$null)
    if ($httpCode -match '^\s*[1-4][0-9][0-9]\s*$') {
        Write-Host '  GitLab is HEALTHY' -ForegroundColor Green
    } else {
        Write-Host '  GitLab is NOT READY — start it first with -Start' -ForegroundColor Red
        return
    }
    Write-Host ''

    # ── Step 2: Cloudflare tunnel ────────────────────────────────────────────
    Write-Host '[2/4] Ensuring Cloudflare tunnel is running...'
    $tunnelUrl = Get-TunnelUrl
    if (-not $tunnelUrl) { return }
    Write-Host "  Public URL: $tunnelUrl" -ForegroundColor Green

    Write-Host '  Testing connectivity through the tunnel...' -ForegroundColor DarkGray
    if (Test-UrlReachable $tunnelUrl) {
        Write-Host '  Tunnel is REACHABLE' -ForegroundColor Green
    } else {
        Write-Host '  WARNING: Tunnel URL did not respond — CodeRabbit may not be able to reach GitLab.' -ForegroundColor Yellow
        Write-Host '  Continuing anyway; verify with "./gitlab-tfs.ps1 -Tunnel".' -ForegroundColor DarkGray
    }
    Write-Host ''

    # ── Step 3: Personal Access Token ───────────────────────────────────────
    Write-Host '[3/4] Creating GitLab Personal Access Token...'
    Write-Host '  This may take 30-60 s (Rails console startup)...' -ForegroundColor DarkGray
    $tokenName = "coderabbit-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $rubyCode  = "u=User.find_by_username('root');" +
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

    # ── Step 4: Instructions + open browser ─────────────────────────────────
    Write-Host '[4/4] Opening CodeRabbit — complete the connection in your browser.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  ┌─────────────────────────────────────────────────────────┐' -ForegroundColor White
    Write-Host '  │  On https://app.coderabbit.ai :                         │' -ForegroundColor White
    Write-Host '  │  1. Sign up / log in                                    │' -ForegroundColor White
    Write-Host '  │  2. Click "Add a self-managed GitLab"                   │' -ForegroundColor White
    Write-Host '  │  3. Enter the values below and click Save               │' -ForegroundColor White
    Write-Host '  └─────────────────────────────────────────────────────────┘' -ForegroundColor White
    Write-Host ''
    Write-Host "  GitLab URL    : $tunnelUrl" -ForegroundColor Yellow
    Write-Host "  Access Token  : $pat"       -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  CodeRabbit will automatically register a webhook in GitLab.' -ForegroundColor DarkGray
    Write-Host '  After that, every new Merge Request gets an AI code review.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  IMPORTANT: The tunnel URL changes on each restart.' -ForegroundColor Yellow
    Write-Host '  For a permanent URL, configure a named Cloudflare Tunnel' -ForegroundColor Yellow
    Write-Host '  with a custom domain (requires a free Cloudflare account).' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  TIP: Add a .coderabbit.yaml to each repo root to customise reviews.' -ForegroundColor Green
    Write-Host ''

    $opened = Open-BrowserUrl 'https://app.coderabbit.ai'
    if (-not $opened) {
        Write-Host '  Could not open browser automatically.' -ForegroundColor DarkGray
        Write-Host '  Navigate to https://app.coderabbit.ai manually.' -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Cmd-Tunnel {
    Write-Host ''
    Write-Host '=== Cloudflare Tunnel ===' -ForegroundColor Cyan
    Write-Host ''

    # ── Step 1: Start (or verify) tunnel container ───────────────────────────
    Write-Host '[1/3] Checking / starting tunnel...'
    $tunnelUrl = Get-TunnelUrl
    if (-not $tunnelUrl) { return }
    Write-Host "  Tunnel URL: $tunnelUrl" -ForegroundColor Green
    Write-Host ''

    # ── Step 2: Connectivity test ────────────────────────────────────────────
    Write-Host '[2/3] Testing tunnel connectivity...'
    if (Test-UrlReachable $tunnelUrl) {
        Write-Host '  Tunnel is WORKING' -ForegroundColor Green
    } else {
        Write-Host '  WARNING: No response through the tunnel — it may still be warming up.' -ForegroundColor Yellow
    }
    Write-Host ''

    # ── Step 3: Summary ──────────────────────────────────────────────────────
    Write-Host '[3/3] Summary'
    Write-Host ''
    Write-Host '  Use this URL for CodeRabbit / external access:' -ForegroundColor Cyan
    Write-Host "  $tunnelUrl" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  NOTE: URL changes each time the tunnel restarts.' -ForegroundColor DarkGray
    Write-Host '  For a permanent URL, configure a named Cloudflare Tunnel' -ForegroundColor DarkGray
    Write-Host '  with a custom domain (requires a free Cloudflare account).' -ForegroundColor DarkGray
    Write-Host ''
}

# =============================================================================
# TFS-Git integration commands
# =============================================================================

function Invoke-TFSCompose {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    if ($script:ComposeCmd -eq 'docker compose') { & docker compose --profile tfs @Arguments }
    else                                          { & docker-compose --profile tfs @Arguments }
}

function Cmd-TFSSetup {
    Write-Host ''
    Write-Host '=== TFS-Git Integration Setup ===' -ForegroundColor Cyan
    Write-Host ''

    # ── Step 1: GitLab health ────────────────────────────────────────────────
    Write-Host '[1/6] Checking GitLab health...'
    $port = Get-EnvOrDefault 'GITLAB_HTTP_PORT' '8081'
    $httpCode = (curl -s -o /dev/null -w '%{http_code}' -m 5 -L "http://localhost:$port/" 2>$null)
    if ($httpCode -match '^\s*[1-4][0-9][0-9]\s*$') {
        Write-Host '  GitLab is HEALTHY' -ForegroundColor Green
    } else {
        Write-Host '  GitLab is NOT READY — start it first with -Start' -ForegroundColor Red
        return
    }
    Write-Host ''

    # ── Step 2: TFS connection details ───────────────────────────────────────
    Write-Host '[2/6] TFS / Azure DevOps connection'
    Write-Host '  The URL must end at the COLLECTION — do NOT include the project name in it.' -ForegroundColor DarkGray
    Write-Host '  Examples:'
    Write-Host '    https://tfs.company.com/tfs/DefaultCollection' -ForegroundColor DarkGray
    Write-Host '    https://tfs.company.com/DefaultCollection'     -ForegroundColor DarkGray
    Write-Host '    https://dev.azure.com/orgname'                 -ForegroundColor DarkGray
    Write-Host ''
    $tfsUrl     = (Read-Host '  TFS URL (including collection, NOT project)').TrimEnd('/')
    $tfsProject = Read-Host '  Team project name'
    Write-Host '  Enter a PAT with Code (read) and Pull Request Threads (read+write) scopes:'
    $secPat = Read-Host '  Personal Access Token' -AsSecureString
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPat)
    $tfsPat = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    if ([string]::IsNullOrWhiteSpace($tfsPat)) {
        Write-Host '  ERROR: Personal Access Token cannot be empty.' -ForegroundColor Red
        Write-Host '  Generate a PAT in TFS → Profile → Security → Personal access tokens.' -ForegroundColor Yellow
        Write-Host '  Required scopes: Code (read)  +  Pull Request Threads (read & write).' -ForegroundColor Yellow
        return
    }
    Write-Host ''

    # ── Step 3: Test TFS connectivity and list repos ─────────────────────────
    Write-Host '[3/6] Testing TFS connectivity...'
    # Use curl (not Invoke-RestMethod) because PowerShell drops the Authorization
    # header when following HTTP redirects, causing TF400813 with a valid PAT.
    # curl --location re-sends auth on every hop.
    $tfsUri   = "${tfsUrl}/${tfsProject}/_apis/git/repositories?api-version=1.0"
    Write-Host "  Calling: $tfsUri" -ForegroundColor DarkGray
    Write-Host "  PAT length: $($tfsPat.Length) chars" -ForegroundColor DarkGray
    # Send the Authorization header explicitly rather than using --user, so curl
    # does NOT enter challenge-response negotiation (which silently skips Basic
    # when the server advertises NTLM — common on TFS on-premises IIS).
    # --location-trusted keeps ALL custom headers, including Authorization, on
    # every redirect hop (plain --location strips auth headers on redirect).
    $tfsAuth  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":${tfsPat}"))
    $curlOut  = curl -sS --location-trusted --insecure `
                     -H "Authorization: Basic ${tfsAuth}" `
                     -H 'Content-Type: application/json' `
                     -w "`n__HTTP_STATUS__%{http_code}" `
                     --max-time 15 `
                     $tfsUri 2>&1
    $curlLines   = $curlOut -join "`n"
    $httpStatus  = if ($curlLines -match '__HTTP_STATUS__(\d+)') { $Matches[1] } else { '???' }
    $jsonBody    = ($curlLines -split '__HTTP_STATUS__')[0].Trim()
    if ($httpStatus -notin @('200','203')) {
        Write-Host "  ERROR: TFS returned HTTP $httpStatus" -ForegroundColor Red
        Write-Host "  Response: $($jsonBody -replace '\s+',' ')" -ForegroundColor Red
        Write-Host ''
        Write-Host '  Checklist:' -ForegroundColor Yellow
        Write-Host '    1. URL must be collection-only, e.g. https://tfs.host/DefaultCollection' -ForegroundColor Yellow
        Write-Host '       (do NOT include the project name in the URL)' -ForegroundColor Yellow
        Write-Host '    2. Team project name is entered separately in the prompt above.' -ForegroundColor Yellow
        Write-Host '    3. PAT scopes: Code (read) + Pull Request Threads (read & write).' -ForegroundColor Yellow
        Write-Host '    4. PAT must belong to a user with access to that project.' -ForegroundColor Yellow
        return
    }
    try {
        $reposResult = $jsonBody | ConvertFrom-Json
        $allRepos    = $reposResult.value | ForEach-Object { $_.name }
        Write-Host "  Connected. Found $($allRepos.Count) repo(s):" -ForegroundColor Green
        $allRepos | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkGray }
    } catch {
        Write-Host "  ERROR: Connected but could not parse repo list — $_" -ForegroundColor Red
        Write-Host "  Raw response: $jsonBody" -ForegroundColor Red
        return
    }
    Write-Host ''

    # ── Step 4: Repo selection ────────────────────────────────────────────────
    Write-Host '[4/6] Repository selection'
    Write-Host '  Press Enter to mirror ALL repos, or enter a comma-separated list:'
    $repoInput = Read-Host '  Repos to mirror (empty = all)'
    $tfsRepos  = $repoInput.Trim()
    if ($tfsRepos) {
        Write-Host "  Will mirror: $tfsRepos" -ForegroundColor Green
    } else {
        Write-Host '  Will mirror: all repos' -ForegroundColor Green
    }
    Write-Host ''

    # ── Step 5: Create dedicated GitLab PAT for the sync container ───────────
    Write-Host '[5/6] Creating GitLab sync token (via Rails console)...'
    Write-Host '  This may take 30-60 s...' -ForegroundColor DarkGray
    $ns        = Get-EnvOrDefault 'GITLAB_TFS_NAMESPACE' 'tfs-mirrors'
    $tokenName = "tfs-sync-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $rubyCode  = "u=User.find_by_username('root');" +
                 "t=u.personal_access_tokens.create!(name:'$tokenName'," +
                 "scopes:['api','read_user','read_repository']," +
                 "expires_at:365.days.from_now);" +
                 "puts('TOKEN:'+t.token)"

    $rawOutput = (docker exec gitlab-tfs-mirror gitlab-rails runner $rubyCode 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $rawOutput -notmatch 'TOKEN:') {
        Write-Host '  Failed to create GitLab token:' -ForegroundColor Red
        Write-Host "  $rawOutput" -ForegroundColor Red
        return
    }
    $glToken = ($rawOutput | Select-String -Pattern 'TOKEN:([A-Za-z0-9_.=-]+)').Matches[0].Groups[1].Value
    Write-Host "  GitLab token created: $tokenName" -ForegroundColor Green
    Write-Host ''

    # ── Step 6: Save to .env and start the sync container ───────────────────
    Write-Host '[6/6] Saving configuration and starting sync service...'
    Set-EnvValue 'TFS_URL'              $tfsUrl
    Set-EnvValue 'TFS_PROJECT'          $tfsProject
    Set-EnvValue 'TFS_PAT'              $tfsPat
    Set-EnvValue 'TFS_REPOS'            $tfsRepos
    Set-EnvValue 'GITLAB_TFS_TOKEN'     $glToken
    Set-EnvValue 'GITLAB_TFS_NAMESPACE' $ns
    Set-EnvValue 'TFS_SYNC_INTERVAL'    (Get-EnvOrDefault 'TFS_SYNC_INTERVAL' '60')
    Write-Host '  Configuration saved to .env' -ForegroundColor Green

    # Reload env so Compose picks up the new values
    Import-EnvFile

    Write-Host '  Building sync image...'
    Invoke-TFSCompose build --no-cache sync
    Write-Host '  Starting sync container (detached)...'
    Invoke-TFSCompose up --detach sync

    Write-Host ''
    Write-Host '=== TFS Integration Active ===' -ForegroundColor Green
    Write-Host ''
    Write-Host '  The sync container mirrors TFS repos to GitLab and bridges PRs.'
    Write-Host '  View sync activity: ./gitlab-tfs.ps1 -TFSLogs'
    Write-Host "  GitLab namespace : http://localhost:$port/${ns}"
    Write-Host ''
}

function Cmd-TFSStatus {
    Write-Host ''
    Write-Host '=== TFS Sync Status ===' -ForegroundColor Cyan
    Write-Host ''

    $running = docker ps --filter 'name=gitlab-tfs-sync' --format '{{.Status}}' 2>$null
    if ($running) {
        Write-Host "  Container : $running" -ForegroundColor Green
    } else {
        Write-Host '  Container : NOT RUNNING' -ForegroundColor Yellow
        Write-Host '  Run ./gitlab-tfs.ps1 -TFSSetup to configure.' -ForegroundColor DarkGray
        return
    }

    $tfsUrl     = Get-EnvOrDefault 'TFS_URL'     '(not set)'
    $tfsProject = Get-EnvOrDefault 'TFS_PROJECT' '(not set)'
    $tfsRepos   = Get-EnvOrDefault 'TFS_REPOS'   '(all)'
    $ns         = Get-EnvOrDefault 'GITLAB_TFS_NAMESPACE' 'tfs-mirrors'
    $interval   = Get-EnvOrDefault 'TFS_SYNC_INTERVAL' '60'
    Write-Host "  TFS URL   : $tfsUrl/$tfsProject"
    Write-Host "  Repos     : $( if ($tfsRepos) { $tfsRepos } else { 'all (auto-discover)' } )"
    Write-Host "  Namespace : $ns"
    Write-Host "  Interval  : ${interval}s"
    Write-Host ''
    Write-Host '  Recent sync log (last 25 lines):' -ForegroundColor Cyan
    Invoke-TFSCompose logs --tail 25 sync 2>&1 | ForEach-Object {
        Write-Host "  $_" -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Cmd-TFSSyncNow {
    Write-Host ''
    Write-Host '=== Triggering Immediate Sync ===' -ForegroundColor Cyan
    Write-Host ''
    $running = docker ps --filter 'name=gitlab-tfs-sync' --format '{{.ID}}' 2>$null
    if (-not $running) {
        Write-Host '  Sync container is not running. Start with -TFSSetup first.' -ForegroundColor Yellow
        return
    }
    Write-Host '  Restarting sync container (triggers a fresh sync cycle)...'
    Invoke-TFSCompose restart sync
    Write-Host '  Done. Follow progress with: ./gitlab-tfs.ps1 -TFSLogs' -ForegroundColor Green
    Write-Host ''
}

function Cmd-TFSLogs {
    Invoke-TFSCompose logs -f --tail 50 sync
}

function Cmd-OpenBrowser {
    Import-EnvFile
    $port = Get-EnvOrDefault 'GITLAB_HTTP_PORT' '8081'
    $url  = "http://localhost:${port}"
    Write-Host "Opening GitLab at $url ..." -ForegroundColor Cyan
    $opened = Open-BrowserUrl $url
    if (-not $opened) {
        Write-Host "Could not open browser automatically. Navigate to: $url" -ForegroundColor Yellow
    }
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
    Write-Host '  1) Setup      - First-time build'
    Write-Host '  2) Start      - Start container'
    Write-Host '  3) Stop       - Stop container'
    Write-Host '  4) Restart    - Restart container'
    Write-Host '  5) Logs       - View container logs'
    Write-Host '  6) Status     - Show health'
    Write-Host '  7) Backup     - Backup .env'
    Write-Host '  8) Export     - Save image to .tar.gz'
    Write-Host '  9) Import     - Load image from .tar.gz'
    Write-Host ' 10) CodeRabbit - Setup AI code review'
    Write-Host ' 11) Tunnel     - Start & test Cloudflare tunnel'
    Write-Host ' 12) Destroy    - Remove container'
    Write-Host ''
    Write-Host ' --- TFS Integration ---'                  -ForegroundColor DarkCyan
    Write-Host ' 13) TFS Setup    - Configure TFS mirroring' -ForegroundColor DarkCyan
    Write-Host ' 14) TFS Status   - Show sync container status' -ForegroundColor DarkCyan
    Write-Host ' 15) TFS Sync Now - Trigger immediate sync'  -ForegroundColor DarkCyan
    Write-Host ' 16) TFS Logs     - Stream sync logs'         -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host ' 17) Open Browser - Open GitLab in browser'
    Write-Host ''
    Write-Host '  0) Exit'
    Write-Host ''
}

function Start-InteractiveMenu {
    while ($true) {
        Show-Menu
        $choice = Read-Host '  Choose [0-17]'
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
                '11' { Cmd-Tunnel }
                '12' { Cmd-Destroy }
                '13' { Cmd-TFSSetup }
                '14' { Cmd-TFSStatus }
                '15' { Cmd-TFSSyncNow }
                '16' { Cmd-TFSLogs }
                '17' { Cmd-OpenBrowser }
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
    'Setup'      { Cmd-Setup }
    'Start'      { Cmd-Start }
    'Stop'       { Cmd-Stop }
    'Restart'    { Cmd-Restart }
    'Logs'       { Cmd-Logs }
    'Status'     { Cmd-Status }
    'Backup'     { Cmd-Backup }
    'Export'     { Cmd-Export }
    'Import'     { Cmd-Import -FilePath $File }
    'CodeRabbit' { Cmd-CodeRabbit }
    'Tunnel'     { Cmd-Tunnel }
    'Destroy'    { Cmd-Destroy }
    'TFSSetup'   { Cmd-TFSSetup }
    'TFSStatus'  { Cmd-TFSStatus }
    'TFSSyncNow' { Cmd-TFSSyncNow }
    'TFSLogs'    { Cmd-TFSLogs }
    'OpenBrowser' { Cmd-OpenBrowser }
    'Help'       {
        Write-Host 'Usage: ./gitlab-tfs.ps1 [-Setup|-Start|-Stop|-Restart|-Logs|-Status|-Backup|-Export|-Import -File <path>|-CodeRabbit|-Tunnel|-Destroy|-TFSSetup|-TFSStatus|-TFSSyncNow|-TFSLogs|-OpenBrowser|-Help]'
        Write-Host '       ./gitlab-tfs.ps1   (no args — interactive menu)'
    }
    default   { Start-InteractiveMenu }
}
