<#
.SYNOPSIS
Registers a scheduled task that runs Export-StorSafeMetrics.ps1 every N minutes.

.DESCRIPTION
Run from an elevated PowerShell prompt (Install-StorSafeMonitoring.ps1 calls this for you). The task runs as -RunAsUser whether or not that user is logged on.
The StorSafe credential files (New-StorSafeCredentialFile) must have been created while logged on as that
same user, because DPAPI ties them to the user and machine.

.EXAMPLE
.\Register-StorSafeCollectorTask.ps1 -ScriptDirectory C:\Scripts\StorSafe -RunAsUser "$env:USERDOMAIN\$env:USERNAME"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScriptDirectory,
    [Parameter(Mandatory)][string]$RunAsUser,
    [ValidateRange(1, 60)][int]$IntervalMinutes = 5,
    [string]$TaskName = 'StorSafe Metrics Collector',
    [string]$PowerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$collector = Join-Path $ScriptDirectory 'Export-StorSafeMetrics.ps1'
if (-not (Test-Path -LiteralPath $collector)) { throw "Not found: $collector" }

$arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -All -NonInteractive' -f $collector
$action = New-ScheduledTaskAction -Execute $PowerShellPath -Argument $arguments -WorkingDirectory $ScriptDirectory
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes ([Math]::Max(2, $IntervalMinutes - 1))) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

$credential = Get-Credential -UserName $RunAsUser -Message "Windows password for $RunAsUser (used to run the task while logged off)"
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -User $credential.UserName -Password $credential.GetNetworkCredential().Password -RunLevel Limited -Force | Out-Null

Write-Host "Registered '$TaskName': every $IntervalMinutes min as $RunAsUser."
Write-Host "Test it now with: Start-ScheduledTask -TaskName '$TaskName'; then check (Get-ScheduledTaskInfo -TaskName '$TaskName').LastTaskResult (0 = OK, 2 = a check failed)."
