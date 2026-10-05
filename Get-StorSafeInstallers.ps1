<#
.SYNOPSIS
Downloads the three third-party installers into installers\ (windows_exporter, Prometheus, Grafana).

.DESCRIPTION
Versions default to the ones this package was tested with; override them with the -*Version parameters
(check https://github.com/prometheus-community/windows_exporter/releases, https://prometheus.io/download/
and https://grafana.com/grafana/download?platform=windows for newer ones). Files that already exist are
kept unless -Force. Uses the system proxy; pass -Proxy http://host:port if the machine needs one.

If the host has no internet access, download the three URLs printed below on another machine and copy
the files into installers\.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\StorSafeMonitoring\Get-StorSafeInstallers.ps1
.EXAMPLE
.\Get-StorSafeInstallers.ps1 -GrafanaVersion 12.1.0 -Proxy http://proxy.example.com:8080
#>
[CmdletBinding()]
param(
    [string]$WindowsExporterVersion = '0.31.8',
    [string]$PrometheusVersion = '3.15.0',
    [string]$GrafanaVersion = '12.0.2',
    [string]$Proxy,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dest = Join-Path $PSScriptRoot 'installers'
New-Item -ItemType Directory -Path $dest -Force | Out-Null
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$files = @(
    @{ Name = "windows_exporter-$WindowsExporterVersion-amd64.msi"
       Url  = "https://github.com/prometheus-community/windows_exporter/releases/download/v$WindowsExporterVersion/windows_exporter-$WindowsExporterVersion-amd64.msi" },
    @{ Name = "prometheus-$PrometheusVersion.windows-amd64.zip"
       Url  = "https://github.com/prometheus/prometheus/releases/download/v$PrometheusVersion/prometheus-$PrometheusVersion.windows-amd64.zip" },
    @{ Name = "grafana-$GrafanaVersion.windows-amd64.msi"
       Url  = "https://dl.grafana.com/oss/release/grafana-$GrafanaVersion.windows-amd64.msi" }
)

$failed = 0
foreach ($f in $files) {
    $path = Join-Path $dest $f.Name
    if ((Test-Path -LiteralPath $path) -and -not $Force) { Write-Host ("exists  {0}" -f $f.Name); continue }
    Write-Host ("get     {0}" -f $f.Url)
    $tmp = "$path.part"
    $request = @{ Uri = $f.Url; OutFile = $tmp; UseBasicParsing = $true; MaximumRedirection = 10 }
    if ($Proxy) { $request.Proxy = $Proxy; $request.ProxyUseDefaultCredentials = $true }
    $savedProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes Invoke-WebRequest very slow on Windows PowerShell 5.1
    try {
        Invoke-WebRequest @request
        Move-Item -LiteralPath $tmp -Destination $path -Force
        Write-Host ("ok      {0} ({1:N1} MB)" -f $f.Name, ((Get-Item -LiteralPath $path).Length / 1MB))
    } catch {
        $failed++
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-Warning ("{0}: {1} Download it by hand from the URL above into {2}" -f $f.Name, $_.Exception.Message, $dest)
    } finally {
        $ProgressPreference = $savedProgress
    }
}

Get-ChildItem -LiteralPath $dest -File | Where-Object { $_.Name -ne 'README.txt' } |
    Select-Object Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }, LastWriteTime | Format-Table -AutoSize | Out-Host
if ($failed -gt 0) { exit 2 }
exit 0
