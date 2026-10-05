<#
.SYNOPSIS
Shows, stops, starts, pauses or resumes the StorSafe monitoring components on this host.

.DESCRIPTION
Components: the collector scheduled task ('StorSafe Metrics Collector'), the Prometheus scheduled task
('StorSafe Prometheus') and the windows_exporter and Grafana Windows services. Nothing here touches the
appliances.

  Status   state of each component, the last collector result, and whether Prometheus, Grafana and
           windows_exporter answer on their ports
  Stop     before host maintenance: disable the collector task, then stop Prometheus, Grafana and
           windows_exporter. Nothing restarts until Start (a reboot alone does not re-enable the collector).
  Start    start windows_exporter, Grafana and Prometheus, re-enable the collector task and run it once
  Pause    appliance maintenance: disable the collector task only, so a rebooting appliance produces no
           failed checks or login events. Prometheus and Grafana keep running and show the last values.
  Resume   re-enable the collector task and run it once

Run from an elevated prompt (Run as Administrator).

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\StorSafeMonitoring\StorSafeMonitoringControl.ps1 Status
.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\StorSafeMonitoring\StorSafeMonitoringControl.ps1 Stop
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)][ValidateSet('Status', 'Stop', 'Start', 'Pause', 'Resume')][string]$Action,
    [string]$CollectorTask = 'StorSafe Metrics Collector',
    [string]$PrometheusTask = 'StorSafe Prometheus'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated prompt (Run as Administrator).'
}

function Get-TaskState { param([string]$Name) $t = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue; if ($t) { [string]$t.State } else { 'not registered' } }
function Get-ServiceState { param([string]$Name) $s = Get-Service -Name $Name -ErrorAction SilentlyContinue; if ($s) { [string]$s.Status } else { 'not installed' } }
function Test-Http { param([string]$Uri) try { $null = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 5; $true } catch { $false } }
function Wait-TaskState {
    param([string]$Name, [string]$Not, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-TaskState $Name) -eq $Not -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
}
function Format-TaskResult {
    param($Code)
    switch ($Code) { 0 { '0 (OK)' } 2 { '2 (a check failed)' } 3 { '3 (config error)' } 267009 { 'running now' } 267011 { 'not run yet' } default { "$Code" } }
}

function Show-Status {
    $rows = [System.Collections.Generic.List[object]]::new()
    $info = Get-ScheduledTaskInfo -TaskName $CollectorTask -ErrorAction SilentlyContinue
    $detail = if ($info) { 'last run {0}, result {1}' -f $info.LastRunTime, (Format-TaskResult $info.LastTaskResult) } else { '' }
    $rows.Add([pscustomobject]@{ Component = "Task '$CollectorTask'"; State = Get-TaskState $CollectorTask; Detail = $detail })
    $detail = if (Test-Http 'http://127.0.0.1:9090/-/ready') { 'answering on 127.0.0.1:9090' } else { 'not answering on 9090' }
    $rows.Add([pscustomobject]@{ Component = "Task '$PrometheusTask'"; State = Get-TaskState $PrometheusTask; Detail = $detail })
    $detail = if (Test-Http 'http://127.0.0.1:9182/metrics') { 'answering on 9182' } else { 'not answering on 9182' }
    $rows.Add([pscustomobject]@{ Component = 'Service windows_exporter'; State = Get-ServiceState 'windows_exporter'; Detail = $detail })
    $detail = if (Test-Http 'http://127.0.0.1:3000/api/health') { 'http://localhost:3000 answering' } else { 'not answering on 3000' }
    $rows.Add([pscustomobject]@{ Component = 'Service Grafana'; State = Get-ServiceState 'Grafana'; Detail = $detail })
    $rows | Format-Table -AutoSize -Wrap | Out-Host
}

function Stop-Collector {
    if ((Get-TaskState $CollectorTask) -eq 'not registered') { Write-Warning "Task '$CollectorTask' is not registered"; return }
    Disable-ScheduledTask -TaskName $CollectorTask | Out-Null
    Stop-ScheduledTask -TaskName $CollectorTask -ErrorAction SilentlyContinue
    Wait-TaskState $CollectorTask -Not 'Running'
    Write-Host "Collector task disabled"
}
function Start-Collector {
    if ((Get-TaskState $CollectorTask) -eq 'not registered') { Write-Warning "Task '$CollectorTask' is not registered"; return }
    Enable-ScheduledTask -TaskName $CollectorTask | Out-Null
    Start-ScheduledTask -TaskName $CollectorTask
    Write-Host "Collector task enabled and started (every run takes a few seconds per appliance)"
}

switch ($Action) {
    'Status' { Show-Status }
    'Pause' {
        Stop-Collector
        Write-Host 'Paused. Dashboards keep the last collected values; the Instance page shows the last run time. Use Resume afterwards.'
        Show-Status
    }
    'Resume' {
        Start-Collector
        Start-Sleep -Seconds 3
        Show-Status
    }
    'Stop' {
        Stop-Collector
        if ((Get-TaskState $PrometheusTask) -eq 'Running') {
            Stop-ScheduledTask -TaskName $PrometheusTask
            Wait-TaskState $PrometheusTask -Not 'Running'
            Write-Host 'Prometheus stopped'
        }
        Disable-ScheduledTask -TaskName $PrometheusTask -ErrorAction SilentlyContinue | Out-Null
        foreach ($svc in @('Grafana', 'windows_exporter')) {
            if ((Get-ServiceState $svc) -eq 'Running') { Stop-Service -Name $svc; Write-Host "$svc stopped" }
        }
        Write-Host 'Stopped. Run this script with Start when maintenance is over.'
        Show-Status
    }
    'Start' {
        foreach ($svc in @('windows_exporter', 'Grafana')) {
            $state = Get-ServiceState $svc
            if ($state -eq 'not installed') { Write-Warning "Service $svc is not installed"; continue }
            if ($state -ne 'Running') { Start-Service -Name $svc; Write-Host "$svc started" }
        }
        if ((Get-TaskState $PrometheusTask) -eq 'not registered') {
            Write-Warning "Task '$PrometheusTask' is not registered"
        } else {
            Enable-ScheduledTask -TaskName $PrometheusTask | Out-Null
            if ((Get-TaskState $PrometheusTask) -ne 'Running') { Start-ScheduledTask -TaskName $PrometheusTask; Write-Host 'Prometheus started (replays its write-ahead log first; a minute or two after a long run)' }
        }
        Start-Collector
        Start-Sleep -Seconds 5
        Show-Status
    }
}
