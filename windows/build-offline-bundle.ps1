<#
.SYNOPSIS
  Builds a self-contained, OFFLINE Windows bundle of Open Notebook (no Docker).

.DESCRIPTION
  Run on a Windows x64 machine WITH internet access (or in GitHub Actions:
  .github/workflows/build-windows-offline.yml). The resulting folder / zip is
  copied to the closed network and needs nothing else installed:

    OpenNotebook\
      python\     portable CPython 3.12 + all Python dependencies
      node\       portable node.exe (runs the Next.js frontend)
      bin\        surreal.exe (+ ffmpeg.exe / ffprobe.exe)
      app\        backend source (api, open_notebook, commands, prompts)
      frontend\   Next.js standalone build
      tiktoken-cache\
      Start-OpenNotebook.bat / Stop-OpenNotebook.bat
      open-notebook.env.example

  Requirements on the build machine: uv, Node.js 22 + npm, PowerShell 5.1+.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File windows\build-offline-bundle.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot "..\dist\OpenNotebook"),
    [string]$PythonVersion = "3.12",
    [string]$NodeMajor = "22",
    # e.g. "v2.3.10". Empty = latest stable v2.x release from GitHub.
    [string]$SurrealVersion = "",
    [switch]$SkipFfmpeg,
    [switch]$Zip
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # much faster Invoke-WebRequest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Work = Join-Path $RepoRoot "dist\_work"

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Download($url, $dest) {
    Write-Host "    downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
}

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { throw "uv is required (https://docs.astral.sh/uv/)" }
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { throw "Node.js/npm is required to build the frontend" }

if (Test-Path $OutputDir) { Remove-Item $OutputDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutputDir, $Work | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path
foreach ($d in "bin", "node", "app", "frontend", "tiktoken-cache") {
    New-Item -ItemType Directory -Force -Path (Join-Path $OutputDir $d) | Out-Null
}

# ---------------------------------------------------------------------------
Step "Portable Python $PythonVersion"
$pyInstallDir = Join-Path $Work "uv-python"
uv python install $PythonVersion --install-dir $pyInstallDir
if ($LASTEXITCODE -ne 0) { throw "uv python install failed" }
# Skip uv's minor-version junctions (reparse points); take the real patch-version folder
$pyHome = Get-ChildItem $pyInstallDir -Directory |
    Where-Object { $_.Name -like "cpython-$PythonVersion.*-windows-x86_64*" -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
    Sort-Object Name -Descending |
    Select-Object -First 1
if (-not $pyHome) { throw "Could not find the installed CPython $PythonVersion" }
Copy-Item $pyHome.FullName (Join-Path $OutputDir "python") -Recurse
$Py = Join-Path $OutputDir "python\python.exe"
# uv marks managed interpreters as externally managed; this copy is private to the bundle
Get-ChildItem (Join-Path $OutputDir "python") -Recurse -Filter "EXTERNALLY-MANAGED" | Remove-Item -Force

# ---------------------------------------------------------------------------
Step "Python dependencies (from uv.lock)"
$req = Join-Path $Work "requirements.txt"
Push-Location $RepoRoot
uv export --frozen --no-dev --no-hashes --no-emit-project --output-file $req
if ($LASTEXITCODE -ne 0) { throw "uv export failed" }
Pop-Location
uv pip install --python $Py --system --break-system-packages --link-mode copy -r $req
if ($LASTEXITCODE -ne 0) { throw "Python dependency install failed" }
# Sanity check the critical imports
& $Py -c "import fastapi, uvicorn, surrealdb, surreal_commands, esperanto, langchain, truststore, tiktoken; print('python deps OK')"
if ($LASTEXITCODE -ne 0) { throw "Python import check failed" }

# ---------------------------------------------------------------------------
Step "Backend source"
foreach ($item in "api", "open_notebook", "commands", "prompts", "pyproject.toml", "run_api.py", "LICENSE") {
    $src = Join-Path $RepoRoot $item
    if (Test-Path $src) { Copy-Item $src (Join-Path $OutputDir "app") -Recurse }
}
Get-ChildItem (Join-Path $OutputDir "app") -Recurse -Directory -Filter "__pycache__" | Remove-Item -Recurse -Force

# ---------------------------------------------------------------------------
Step "tiktoken encodings (offline cache)"
$env:TIKTOKEN_CACHE_DIR = Join-Path $OutputDir "tiktoken-cache"
& $Py -c "import tiktoken; [tiktoken.get_encoding(e) for e in ('o200k_base','cl100k_base')]; print('tiktoken cache OK')"
if ($LASTEXITCODE -ne 0) { throw "tiktoken cache download failed" }
Remove-Item Env:\TIKTOKEN_CACHE_DIR

# ---------------------------------------------------------------------------
Step "Frontend (Next.js standalone build)"
Push-Location (Join-Path $RepoRoot "frontend")
$env:NEXT_TELEMETRY_DISABLED = "1"
# Rewrites are resolved at build time; use IPv4 explicitly (Windows may resolve localhost to ::1)
$env:INTERNAL_API_URL = "http://127.0.0.1:5055"
npm ci
if ($LASTEXITCODE -ne 0) { throw "npm ci failed" }
npm run build
if ($LASTEXITCODE -ne 0) { throw "npm run build failed" }
Pop-Location
$fe = Join-Path $RepoRoot "frontend"
$feOut = Join-Path $OutputDir "frontend"
Copy-Item (Join-Path $fe ".next\standalone\*") $feOut -Recurse -Force
New-Item -ItemType Directory -Force -Path (Join-Path $feOut ".next") | Out-Null
Copy-Item (Join-Path $fe ".next\static") (Join-Path $feOut ".next\static") -Recurse -Force
if (Test-Path (Join-Path $fe "public")) { Copy-Item (Join-Path $fe "public") (Join-Path $feOut "public") -Recurse -Force }
if (-not (Test-Path (Join-Path $feOut "server.js"))) { throw "Next.js standalone server.js not found" }

# ---------------------------------------------------------------------------
Step "Portable Node.js $NodeMajor"
$index = Invoke-RestMethod "https://nodejs.org/dist/index.json"
$nodeRel = $index | Where-Object { $_.version -like "v$NodeMajor.*" -and $_.files -contains "win-x64-zip" } | Select-Object -First 1
if (-not $nodeRel) { throw "No Node.js v$NodeMajor release found" }
$nodeZip = Join-Path $Work "node.zip"
Download "https://nodejs.org/dist/$($nodeRel.version)/node-$($nodeRel.version)-win-x64.zip" $nodeZip
Expand-Archive $nodeZip (Join-Path $Work "node") -Force
$nodeExe = Get-ChildItem (Join-Path $Work "node") -Recurse -Filter "node.exe" | Select-Object -First 1
Copy-Item $nodeExe.FullName (Join-Path $OutputDir "node\node.exe")

# ---------------------------------------------------------------------------
Step "SurrealDB (Windows binary)"
if (-not $SurrealVersion) {
    $headers = @{ "User-Agent" = "open-notebook-build" }
    if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN" }
    $releases = Invoke-RestMethod "https://api.github.com/repos/surrealdb/surrealdb/releases?per_page=50" -Headers $headers
    $rel = $releases | Where-Object { -not $_.prerelease -and -not $_.draft -and $_.tag_name -like "v2.*" } | Select-Object -First 1
    if (-not $rel) { throw "No stable SurrealDB v2 release found; pass -SurrealVersion" }
    $SurrealVersion = $rel.tag_name
    $asset = $rel.assets | Where-Object { $_.name -like "*windows-amd64.exe" } | Select-Object -First 1
    $surrealUrl = if ($asset) { $asset.browser_download_url } else { "https://download.surrealdb.com/$SurrealVersion/surreal-$SurrealVersion.windows-amd64.exe" }
} else {
    $surrealUrl = "https://download.surrealdb.com/$SurrealVersion/surreal-$SurrealVersion.windows-amd64.exe"
}
Write-Host "    SurrealDB $SurrealVersion"
Download $surrealUrl (Join-Path $OutputDir "bin\surreal.exe")
& (Join-Path $OutputDir "bin\surreal.exe") version
if ($LASTEXITCODE -ne 0) { throw "surreal.exe does not run" }

# ---------------------------------------------------------------------------
if (-not $SkipFfmpeg) {
    Step "ffmpeg (audio/video sources, podcasts)"
    try {
        $ffZip = Join-Path $Work "ffmpeg.zip"
        Download "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" $ffZip
        Expand-Archive $ffZip (Join-Path $Work "ffmpeg") -Force
        foreach ($exe in "ffmpeg.exe", "ffprobe.exe") {
            $f = Get-ChildItem (Join-Path $Work "ffmpeg") -Recurse -Filter $exe | Select-Object -First 1
            Copy-Item $f.FullName (Join-Path $OutputDir "bin\$exe")
        }
    } catch {
        Write-Warning "ffmpeg download failed ($_). Audio/video features need ffmpeg in bin\ ."
    }
}

# ---------------------------------------------------------------------------
Step "Launcher scripts"
Copy-Item (Join-Path $PSScriptRoot "bundle\*") $OutputDir -Recurse -Force
@{
    built_at        = (Get-Date).ToString("s")
    open_notebook   = (Select-String -Path (Join-Path $RepoRoot "pyproject.toml") -Pattern '^version = "(.*)"').Matches[0].Groups[1].Value
    python          = (& $Py -c "import platform; print(platform.python_version())")
    node            = $nodeRel.version
    surrealdb       = $SurrealVersion
} | ConvertTo-Json | Set-Content (Join-Path $OutputDir "BUILD-INFO.json") -Encoding UTF8

if ($Zip) {
    Step "Zip"
    $zipPath = "$OutputDir.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path $OutputDir -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Host "    $zipPath"
}

Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
Step "Done: $OutputDir"
