<#
.SYNOPSIS
  Starts Open Notebook from the offline Windows bundle (no Docker, no internet).
  Processes: SurrealDB -> API (FastAPI) -> worker -> frontend (Next.js).
  Logs: .\logs\   Stop: Stop-OpenNotebook.bat
#>
[CmdletBinding()]
param([switch]$NoBrowser)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$Logs = Join-Path $Root "logs"
$Run  = Join-Path $Root "run"
New-Item -ItemType Directory -Force -Path $Logs, $Run, (Join-Path $Root "db"), (Join-Path $Root "app\data") | Out-Null

function Info($m) { Write-Host "[open-notebook] $m" -ForegroundColor Cyan }

# --- Already running? --------------------------------------------------------
$pidFile = Join-Path $Run "pids.json"
if (Test-Path $pidFile) {
    $alive = (Get-Content $pidFile -Raw | ConvertFrom-Json).PSObject.Properties |
        Where-Object { Get-Process -Id $_.Value -ErrorAction SilentlyContinue }
    if ($alive) {
        Info "Already running. Use Stop-OpenNotebook.bat first."
        if (-not $NoBrowser) { Start-Process "http://127.0.0.1:8502" }
        exit 0
    }
}

# --- Configuration (.env) ----------------------------------------------------
$envFile = Join-Path $Root ".env"
if (-not (Test-Path $envFile)) {
    Copy-Item (Join-Path $Root "open-notebook.env.example") $envFile
    Info "Created .env from open-notebook.env.example"
}
# Generate a random encryption key on first run (protects stored API keys)
$envText = Get-Content $envFile -Raw
if ($envText -notmatch '(?m)^[ \t]*OPEN_NOTEBOOK_ENCRYPTION_KEY[ \t]*=[ \t]*[^\s#]+' -or $envText -match '(?m)^[ \t]*OPEN_NOTEBOOK_ENCRYPTION_KEY[ \t]*=[ \t]*change-me') {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $key = [Convert]::ToBase64String($bytes)
    $envText = [regex]::Replace($envText, '(?m)^[ \t]*#?[ \t]*OPEN_NOTEBOOK_ENCRYPTION_KEY[ \t]*=.*$', '')
    $envText = $envText.TrimEnd() + "`r`nOPEN_NOTEBOOK_ENCRYPTION_KEY=$key`r`n"
    Set-Content -Path $envFile -Value $envText -Encoding UTF8
    Info "Generated OPEN_NOTEBOOK_ENCRYPTION_KEY in .env (keep this file - it decrypts your saved API keys)"
}
foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
        $val = $Matches[2].Trim('"').Trim("'")
        [Environment]::SetEnvironmentVariable($Matches[1], $val, "Process")
    }
}

function Default($name, $value) {
    if (-not [Environment]::GetEnvironmentVariable($name, "Process")) {
        [Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
}
Default "SURREAL_USER" "root"
Default "SURREAL_PASSWORD" "root"
Default "SURREAL_NAMESPACE" "open_notebook"
Default "SURREAL_DATABASE" "open_notebook"
Default "SURREAL_PORT" "8000"
Default "API_HOST" "127.0.0.1"
Default "API_PORT" "5055"
Default "FRONTEND_HOST" "127.0.0.1"
Default "FRONTEND_PORT" "8502"
Default "OPEN_NOTEBOOK_WORKER_MAX_TASKS" "2"
Default "OPEN_NOTEBOOK_USE_SYSTEM_CERTS" "true"       # trust the internal CA from the Windows store
Default "OPEN_NOTEBOOK_DISABLE_VERSION_CHECK" "true"  # no internet
Default "SURREAL_URL" "ws://127.0.0.1:$($env:SURREAL_PORT)/rpc"
Default "INTERNAL_API_URL" "http://127.0.0.1:$($env:API_PORT)"
$env:TIKTOKEN_CACHE_DIR = Join-Path $Root "tiktoken-cache"
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONDONTWRITEBYTECODE = "1"
$env:NEXT_TELEMETRY_DISABLED = "1"
$env:HF_HUB_OFFLINE = "1"
$env:PATH = "$(Join-Path $Root 'bin');$(Join-Path $Root 'node');$env:PATH"
$noProxy = "localhost,127.0.0.1,::1"
$env:NO_PROXY = if ($env:NO_PROXY) { "$env:NO_PROXY,$noProxy" } else { $noProxy }
$env:no_proxy = $env:NO_PROXY

$Py   = Join-Path $Root "python\python.exe"
$Node = Join-Path $Root "node\node.exe"

# --- Helpers -----------------------------------------------------------------
$pids = [ordered]@{}
function Start-Svc($name, $exe, $argList, $workDir, [hashtable]$extraEnv = @{}) {
    foreach ($k in $extraEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $extraEnv[$k], "Process") }
    # Windows PowerShell joins arguments with spaces; quote any that contain spaces
    $quoted = $argList | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { "$_" } }
    $p = Start-Process -FilePath $exe -ArgumentList $quoted -WorkingDirectory $workDir `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $Logs "$name.log") `
        -RedirectStandardError  (Join-Path $Logs "$name.err.log")
    $pids[$name] = $p.Id
    $pids | ConvertTo-Json | Set-Content $pidFile
    Info "started $name (pid $($p.Id))"
}
function Wait-Port($port, $name, $timeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $c = New-Object Net.Sockets.TcpClient
            $c.Connect("127.0.0.1", [int]$port); $c.Close(); return
        } catch { Start-Sleep -Milliseconds 700 }
    }
    throw "$name did not start on port $port - see logs\$name.err.log"
}
function Wait-Http($url, $name, $timeoutSec = 180) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 | Out-Null; return }
        catch { Start-Sleep -Seconds 2 }
    }
    throw "$name not ready at $url - see logs\$name.err.log"
}

try {
    # 1. SurrealDB (embedded RocksDB files in .\db)
    Start-Svc "surrealdb" (Join-Path $Root "bin\surreal.exe") @(
        "start", "--log", "info",
        "--user", $env:SURREAL_USER, "--pass", $env:SURREAL_PASSWORD,
        "--bind", "127.0.0.1:$($env:SURREAL_PORT)",
        "rocksdb:db/open-notebook.db"
    ) $Root
    Wait-Port $env:SURREAL_PORT "surrealdb"

    # 2. API (runs DB migrations on startup)
    Start-Svc "api" $Py @("-m", "uvicorn", "api.main:app", "--host", $env:API_HOST, "--port", $env:API_PORT) (Join-Path $Root "app")
    Wait-Http "http://127.0.0.1:$($env:API_PORT)/health" "api"

    # 3. Background worker (source processing, embeddings, podcasts)
    Start-Svc "worker" $Py @("-m", "surreal_commands.cli.worker", "--import-modules", "commands", "--max-tasks", $env:OPEN_NOTEBOOK_WORKER_MAX_TASKS) (Join-Path $Root "app")

    # 4. Frontend (Next.js standalone)
    Start-Svc "frontend" $Node @("server.js") (Join-Path $Root "frontend") @{
        PORT = $env:FRONTEND_PORT; HOSTNAME = $env:FRONTEND_HOST; NODE_ENV = "production"
    }
    Wait-Port $env:FRONTEND_PORT "frontend"
} catch {
    Write-Host "`n$_" -ForegroundColor Red
    Write-Host "Stopping what was started..." -ForegroundColor Yellow
    & (Join-Path $Root "Stop-OpenNotebook.ps1") -Quiet
    exit 1
}

$url = "http://127.0.0.1:$($env:FRONTEND_PORT)"
Info "Open Notebook is running: $url"
if (-not $NoBrowser) { Start-Process $url }
exit 0
