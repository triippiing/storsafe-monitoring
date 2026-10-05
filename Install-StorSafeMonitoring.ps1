<#
.SYNOPSIS
Installs the StorSafe monitoring stack from this folder: credential files, windows_exporter,
Prometheus, Grafana (with data source and dashboard provisioned) and the collector scheduled task.

.DESCRIPTION
Extract the package where it should live (e.g. C:\StorSafeMonitoring) and run this script from an
elevated PowerShell prompt, logged on as the account that will run the collector (DPAPI ties the
credential files to that user and machine). The folder you run it from is the install root:

  <root>\metrics      windows_exporter textfile directory (storsafe.prom)
  <root>\reports      CSV reports from the Get-* scripts
  <root>\creds        DPAPI credential files (ACL restricted to the run-as user and Administrators)
  <root>\installers   drop the third-party installers here (see installers\README.txt)
  <root>\state        collector state (event log bookmark, cached hourly checks)
  <root>\events       daily raw event log CSVs per appliance
  <root>\prometheus   Prometheus binaries, config and data (created at install)

Each step is idempotent and skips itself if the component is already installed or its installer is
missing, so the script can be re-run after adding installers. Use the -Skip* switches to leave a
component alone, e.g. if the server already has Grafana or Prometheus.

.EXAMPLE
.\Install-StorSafeMonitoring.ps1
.EXAMPLE
.\Install-StorSafeMonitoring.ps1 -SkipGrafana -IntervalMinutes 2
#>
[CmdletBinding()]
param(
    [string]$RunAsUser = "$env:USERDOMAIN\$env:USERNAME",
    [ValidateRange(1, 60)][int]$IntervalMinutes = 5,
    [ValidateRange(1, 3650)][int]$PrometheusRetentionDays = 180,
    [string]$GrafanaHome = "$env:ProgramFiles\GrafanaLabs\grafana",
    [switch]$SkipCredentials,
    [switch]$SkipExporter,
    [switch]$SkipPrometheus,
    [switch]$SkipGrafana,
    [switch]$SkipCollectorTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
$Installers = Join-Path $Root 'installers'
$MetricsDir = Join-Path $Root 'metrics'
$summary = [System.Collections.Generic.List[object]]::new()

function Write-Step { param([string]$Text) Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Add-Summary { param([string]$Step, [string]$Result, [string]$Note = '') $summary.Add([pscustomobject]@{ Step = $Step; Result = $Result; Note = $Note }) }

function Find-Installer {
    param([string]$Pattern)
    $found = @(Get-ChildItem -LiteralPath $Installers -Filter $Pattern -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($found.Count -gt 0) { return $found[0].FullName }
    return $null
}

function Wait-HttpOk {
    param([string]$Uri, [int]$TimeoutSec = 60, [string]$Contains)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -eq 200 -and (-not $Contains -or $r.Content -match [regex]::Escape($Contains))) { return $true }
        } catch { }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Invoke-Msi {
    param([string]$Path, [string[]]$Properties)
    $log = Join-Path $env:TEMP ("{0}.log" -f [System.IO.Path]::GetFileNameWithoutExtension($Path))
    $arguments = @('/i', "`"$Path`"", '/qn', '/norestart', '/l*v', "`"$log`"") + $Properties
    $p = Start-Process -FilePath msiexec.exe -ArgumentList $arguments -Wait -PassThru
    if ($p.ExitCode -notin @(0, 3010)) { throw "msiexec failed for $Path (exit $($p.ExitCode)); see $log" }
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell prompt (Run as Administrator).'
}

# windows_exporter's MSI does not quote TEXTFILE_DIRS, so a space in the path makes the service exit at start.
if ($Root -match '\s') {
    throw "The install folder '$Root' contains a space. Move the package to a path without spaces (e.g. C:\StorSafeMonitoring) and run the installer from there."
}

$packageVersion = try { (Get-Content -LiteralPath (Join-Path $Root 'VERSION') -ErrorAction Stop | Select-Object -First 1).Trim() } catch { 'unknown' }
Write-Host "StorSafe Monitoring package $packageVersion, install root $Root" -ForegroundColor White
Get-ChildItem -LiteralPath $Root -Recurse -Include *.ps1, *.psm1 | Unblock-File
foreach ($dir in @('metrics', 'reports', 'creds', 'installers', 'state', 'events')) {
    New-Item -ItemType Directory -Path (Join-Path $Root $dir) -Force | Out-Null
}
Import-Module (Join-Path $Root 'StorSafe.psm1') -Force -DisableNameChecking

$configPath = Join-Path $Root 'StorSafe.config.json'
if (-not (Test-Path -LiteralPath $configPath)) {
    Copy-Item (Join-Path $Root 'StorSafe.config.example.json') $configPath
    throw "Created $configPath from the example. Edit the Servers list, then re-run this script."
}
$config = Import-StorSafeConfig -Path $configPath

$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
if ($currentUser -ine $RunAsUser) {
    Write-Warning "You are logged on as $currentUser but the collector will run as $RunAsUser. Credential files created now will NOT be readable by $RunAsUser. Re-run logged on as $RunAsUser, or use -SkipCredentials and create them later as that user."
}

# ---------------------------------------------------------------------------
# 1. Credential files
# ---------------------------------------------------------------------------
Write-Step 'StorSafe API credential files'
if ($SkipCredentials) {
    Add-Summary 'Credentials' 'Skipped'
} else {
    foreach ($s in $config.Servers) {
        if (-not $s.CredentialFile) { Write-Warning "$($s.Name) has no CredentialFile in the config; the scheduled collector will fail for it."; continue }
        if (Test-Path -LiteralPath $s.CredentialFile) { Write-Host "$($s.Name): $($s.CredentialFile) exists"; continue }
        Write-Host "$($s.Name): enter the API account (a Read-only type R account is recommended)"
        New-StorSafeCredentialFile -Path $s.CredentialFile
    }
    # Restrict the creds folder to the run-as user, Administrators and SYSTEM.
    $credsDir = Join-Path $Root 'creds'
    & icacls.exe $credsDir /inheritance:r /grant:r "${RunAsUser}:(OI)(CI)F" '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
    Add-Summary 'Credentials' 'OK' "creds\ restricted to $RunAsUser, Administrators, SYSTEM"
}

# ---------------------------------------------------------------------------
# 2. Collector test run
# ---------------------------------------------------------------------------
Write-Step 'Collector test run'
& (Join-Path $Root 'Export-StorSafeMetrics.ps1') -All -NonInteractive
$collectorExit = $LASTEXITCODE
switch ($collectorExit) {
    0 { Add-Summary 'Collector test' 'OK' "metrics\storsafe.prom written" }
    2 { Add-Summary 'Collector test' 'Partial' 'A server or check failed; see warnings above. Metrics were still written.' }
    default { Add-Summary 'Collector test' 'FAILED' "Exit $collectorExit; fix before relying on the dashboard." }
}

# ---------------------------------------------------------------------------
# 3. windows_exporter (textfile collector -> <root>\metrics)
# ---------------------------------------------------------------------------
Write-Step 'windows_exporter'
if ($SkipExporter) {
    Add-Summary 'windows_exporter' 'Skipped'
} elseif (Get-Service -Name windows_exporter -ErrorAction SilentlyContinue) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='windows_exporter'"
    if ($svc.PathName -notmatch [regex]::Escape($MetricsDir)) {
        Add-Summary 'windows_exporter' 'Check' "Already installed; make sure its textfile directory includes $MetricsDir (service command: $($svc.PathName))"
    } else {
        Add-Summary 'windows_exporter' 'OK' 'Already installed'
    }
} else {
    $msi = Find-Installer 'windows_exporter-*-amd64.msi'
    if (-not $msi) {
        Add-Summary 'windows_exporter' 'Missing installer' 'Put windows_exporter-<ver>-amd64.msi in installers\ and re-run'
    } else {
        Invoke-Msi $msi @('ENABLED_COLLECTORS="textfile,cpu,memory,logical_disk,os,service"', "TEXTFILE_DIRS=`"$MetricsDir`"")
        if (Wait-HttpOk 'http://127.0.0.1:9182/metrics' 60 'storsafe_') {
            Add-Summary 'windows_exporter' 'OK' 'Serving storsafe_* on :9182'
        } else {
            Add-Summary 'windows_exporter' 'Check' 'Installed but storsafe_* not visible on http://127.0.0.1:9182/metrics yet'
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Prometheus (startup scheduled task as SYSTEM; binds 127.0.0.1:9090)
# ---------------------------------------------------------------------------
Write-Step 'Prometheus'
$promTaskName = 'StorSafe Prometheus'
$promDir = Join-Path $Root 'prometheus'
if ($SkipPrometheus) {
    Add-Summary 'Prometheus' 'Skipped' 'Add monitoring\prometheus.yml scrape job to your existing Prometheus'
} elseif (Get-ScheduledTask -TaskName $promTaskName -ErrorAction SilentlyContinue) {
    Copy-Item (Join-Path $Root 'monitoring\prometheus.yml') (Join-Path $promDir 'prometheus.yml') -Force
    Add-Summary 'Prometheus' 'OK' 'Already installed; prometheus.yml refreshed (restart the task to apply)'
} else {
    $zip = Find-Installer 'prometheus-*.windows-amd64.zip'
    if (-not $zip) {
        Add-Summary 'Prometheus' 'Missing installer' 'Put prometheus-<ver>.windows-amd64.zip in installers\ and re-run'
    } else {
        New-Item -ItemType Directory -Path $promDir -Force | Out-Null
        $staging = Join-Path $env:TEMP ("prom-" + [guid]::NewGuid())
        Expand-Archive -LiteralPath $zip -DestinationPath $staging -Force
        $exe = Get-ChildItem -LiteralPath $staging -Recurse -Filter prometheus.exe | Select-Object -First 1
        if (-not $exe) { throw "prometheus.exe not found in $zip" }
        Copy-Item -Path (Join-Path $exe.DirectoryName '*') -Destination $promDir -Recurse -Force
        Remove-Item -LiteralPath $staging -Recurse -Force
        Copy-Item (Join-Path $Root 'monitoring\prometheus.yml') (Join-Path $promDir 'prometheus.yml') -Force
        New-Item -ItemType Directory -Path (Join-Path $promDir 'data') -Force | Out-Null

        $promArgs = '--config.file="{0}" --storage.tsdb.path="{1}" --storage.tsdb.retention.time={2}d --web.listen-address=127.0.0.1:9090' -f `
            (Join-Path $promDir 'prometheus.yml'), (Join-Path $promDir 'data'), $PrometheusRetentionDays
        $action = New-ScheduledTaskAction -Execute (Join-Path $promDir 'prometheus.exe') -Argument $promArgs -WorkingDirectory $promDir
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $promTaskName -Action $action -Trigger $trigger -Settings $settings -Principal $taskPrincipal -Force | Out-Null
        Start-ScheduledTask -TaskName $promTaskName
        if (Wait-HttpOk 'http://127.0.0.1:9090/-/ready' 60) {
            Add-Summary 'Prometheus' 'OK' "Running from $promDir (task '$promTaskName', retention ${PrometheusRetentionDays}d)"
        } else {
            Add-Summary 'Prometheus' 'Check' "Task registered but http://127.0.0.1:9090 not ready yet"
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Grafana (+ provisioned data source and dashboard)
# ---------------------------------------------------------------------------
Write-Step 'Grafana'
if ($SkipGrafana) {
    Add-Summary 'Grafana' 'Skipped' 'Import the JSON files in monitoring\dashboards manually'
} else {
    $installedNow = $false
    if (-not (Get-Service -Name Grafana -ErrorAction SilentlyContinue)) {
        $msi = Find-Installer 'grafana*.msi'
        if ($msi) { Invoke-Msi $msi @(); $installedNow = $true }
    }
    if (-not (Get-Service -Name Grafana -ErrorAction SilentlyContinue)) {
        Add-Summary 'Grafana' 'Missing installer' 'Put grafana-<ver>.windows-amd64.msi in installers\ and re-run'
    } elseif (-not (Test-Path -LiteralPath (Join-Path $GrafanaHome 'conf\provisioning'))) {
        Add-Summary 'Grafana' 'Check' "Service found but $GrafanaHome\conf\provisioning does not exist; re-run with -GrafanaHome <path>"
    } else {
        $prov = Join-Path $GrafanaHome 'conf\provisioning'
        Copy-Item (Join-Path $Root 'monitoring\grafana\storsafe-datasource.yaml') (Join-Path $prov 'datasources\storsafe-datasource.yaml') -Force
        $dashDir = Join-Path $Root 'monitoring\dashboards'
        (Get-Content -LiteralPath (Join-Path $Root 'monitoring\grafana\storsafe-dashboards.yaml') -Raw).Replace('__DASHBOARD_DIR__', $dashDir.Replace("'", "''")) |
            Set-Content -LiteralPath (Join-Path $prov 'dashboards\storsafe-dashboards.yaml') -Encoding ASCII
        Restart-Service -Name Grafana
        $note = 'Data source and dashboard provisioned (folder "StorSafe")'
        if ($installedNow) { $note += '; first login admin/admin at http://localhost:3000' }
        if (Wait-HttpOk 'http://127.0.0.1:3000/api/health' 90) { Add-Summary 'Grafana' 'OK' $note } else { Add-Summary 'Grafana' 'Check' "$note, but http://localhost:3000 not responding yet" }
    }
}

# ---------------------------------------------------------------------------
# 6. Collector scheduled task
# ---------------------------------------------------------------------------
Write-Step 'Collector scheduled task'
if ($SkipCollectorTask) {
    Add-Summary 'Collector task' 'Skipped'
} else {
    & (Join-Path $Root 'monitoring\Register-StorSafeCollectorTask.ps1') -ScriptDirectory $Root -RunAsUser $RunAsUser -IntervalMinutes $IntervalMinutes
    Add-Summary 'Collector task' 'OK' "Every $IntervalMinutes min as $RunAsUser"
}

Write-Host ''
Write-Host 'Install summary' -ForegroundColor White
$summary | Format-Table -AutoSize -Wrap | Out-Host
Write-Host 'Dashboard: http://localhost:3000  (Dashboards > StorSafe > StorSafe Estate)'
