<#
.SYNOPSIS
  Stops all Open Notebook processes started by Start-OpenNotebook.ps1.
#>
[CmdletBinding()]
param([switch]$Quiet)

$pidFile = Join-Path $PSScriptRoot "run\pids.json"
if (-not (Test-Path $pidFile)) {
    if (-not $Quiet) { Write-Host "[open-notebook] Not running." }
    exit 0
}
$pids = Get-Content $pidFile -Raw | ConvertFrom-Json
# Stop in reverse start order: frontend, worker, api, surrealdb
$names = @($pids.PSObject.Properties.Name)
[array]::Reverse($names)
foreach ($name in $names) {
    $id = $pids.$name
    if (Get-Process -Id $id -ErrorAction SilentlyContinue) {
        & taskkill.exe /PID $id /T /F | Out-Null
        if (-not $Quiet) { Write-Host "[open-notebook] stopped $name (pid $id)" }
    }
}
Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
