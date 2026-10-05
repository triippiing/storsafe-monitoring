<#
.SYNOPSIS
Lists virtual tapes currently loaded in StorSafe virtual tape library drives.

.DESCRIPTION
Appliances, transport and credential files come from StorSafe.config.json (or -ConfigPath /
$env:STORSAFE_CONFIG). Interactive by default; for Task Scheduler use -All (or -Server) with
-NonInteractive and a CredentialFile per server (see New-StorSafeCredentialFile in StorSafe.psm1).

Exit codes: 0 no tapes loaded, 1 tapes loaded, 2 API error or schema mismatch, 3 usage or config error.

.EXAMPLE
.\Get-StorSafeLoadedTapes.ps1 -Server STORSAFE-01
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string[]]$Server,
    [switch]$All,
    [PSCredential]$Credential,
    [switch]$NonInteractive,
    [string]$CsvPath,

    # Optional overrides of the config file transport settings.
    [ValidateSet('http', 'https')][string]$Scheme,
    [int]$Port = -1,
    [switch]$SkipCertificateCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'StorSafe.psm1') -Force -DisableNameChecking
} catch {
    [Console]::Error.WriteLine("ERROR: Cannot load StorSafe.psm1 from ${PSScriptRoot}: $($_.Exception.Message)")
    exit 3
}

try {
    if (-not $ConfigPath) { $ConfigPath = Get-StorSafeDefaultConfigPath -ScriptRoot $PSScriptRoot }
    $config = Import-StorSafeConfig -Path $ConfigPath

    foreach ($s in $config.Servers) {
        if ($Scheme) { $s.Scheme = $Scheme }
        if ($Port -ge 0) { $s.Port = $Port }
        if ($SkipCertificateCheck) { $s.SkipCertificateCheck = $true }
    }

    $selectedServers = @(Select-StorSafeServer -Config $config -Server $Server -All:$All -NonInteractive:$NonInteractive)

    $credentialByName = @{}
    foreach ($s in $selectedServers) {
        $credentialByName[$s.Name] = Get-StorSafeCredential -ServerConfig $s -Credential $Credential -NonInteractive:$NonInteractive
    }

    if (-not $CsvPath) { $CsvPath = Get-StorSafeReportPath -Directory $config.OutputDirectory -Prefix 'StorSafe-Loaded-Tapes' }
} catch {
    Write-StorSafeUsageError $_.Exception.Message
    exit 3
}

$runTimestamp = Get-StorSafeTimestamp
$loadedTapes = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[object]]::new()

function Add-ErrorRow {
    param($ServerConfig, [string]$Library, [string]$Stage, [string]$Message)
    $errors.Add([pscustomobject]@{
        Timestamp = $runTimestamp; Server = $ServerConfig.Name; Host = $ServerConfig.Host
        VirtualTapeLibrary = $Library; Stage = $Stage; Error = $Message
    })
}

foreach ($s in $selectedServers) {
    $connection = $null
    Write-Host "Checking $($s.Name) [$($s.Host)]..." -ForegroundColor Cyan

    try {
        $connection = Connect-StorSafe -ServerConfig $s -Credential $credentialByName[$s.Name]

        # GET /virtuallibrary -> data[] : id, name, drives, loadeddrives, tapes, ...
        $libraryResponse = Invoke-StorSafeApi -Connection $connection -Path '/virtuallibrary'
        $libraries = @(Get-OptionalValue $libraryResponse 'data' @())

        foreach ($library in $libraries) {
            $libraryId = Get-OptionalValue $library 'id' $null
            $libraryName = [string](Get-OptionalValue $library 'name' "Library ID $libraryId")
            if ($null -eq $libraryId) { continue }

            try {
                # GET /virtuallibrary/drive/<libId> -> data.drives[] : id, name, serialno, status (empty|loaded), loadedtape{id,name,barcode}
                $driveResponse = Invoke-StorSafeApi -Connection $connection -Path ("/virtuallibrary/drive/{0}" -f $libraryId)
                $drives = @(Get-OptionalValue (Get-OptionalValue $driveResponse 'data' $null) 'drives' @())

                $loadedHere = 0
                foreach ($drive in $drives) {
                    $status = [string](Get-OptionalValue $drive 'status' '')
                    if ($status -notmatch '^(?i:loaded)$') { continue }
                    $loadedHere++

                    $loadedTape = Get-OptionalValue $drive 'loadedtape' $null
                    $loadedTapes.Add([pscustomobject]@{
                        Timestamp          = $runTimestamp
                        Server             = $s.Name
                        Host               = $s.Host
                        VirtualTapeLibrary = $libraryName
                        LibraryId          = $libraryId
                        DriveName          = Get-OptionalValue $drive 'name' ''
                        DriveId            = Get-OptionalValue $drive 'id' ''
                        DriveSerial        = Get-OptionalValue $drive 'serialno' ''
                        DriveStatus        = $status
                        TapeName           = Get-OptionalValue $loadedTape 'name' ''
                        TapeBarcode        = Get-OptionalValue $loadedTape 'barcode' ''
                        TapeId             = Get-OptionalValue $loadedTape 'id' ''
                    })
                }

                # Cross-check against the library summary so a response-format change cannot silently report zero.
                $expected = Get-OptionalValue $library 'loadeddrives' $null
                if ($null -ne $expected -and [int]$expected -ne $loadedHere) {
                    Add-ErrorRow $s $libraryName 'Cross-check' ("Library reports loadeddrives={0} but {1} loaded drive(s) were parsed (drive count {2})." -f $expected, $loadedHere, $drives.Count)
                }
            } catch {
                Add-ErrorRow $s $libraryName 'Enumerate library drives' $_.Exception.Message
            }
        }
    } catch {
        Add-ErrorRow $s '' 'Login or enumerate libraries' $_.Exception.Message
    } finally {
        Disconnect-StorSafe $connection
    }
}

$loadedTapes | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
if ($loadedTapes.Count -eq 0) {
    # Keep a header-only CSV so downstream readers always find a file.
    'Timestamp,Server,Host,VirtualTapeLibrary,LibraryId,DriveName,DriveId,DriveSerial,DriveStatus,TapeName,TapeBarcode,TapeId' |
        Set-Content -LiteralPath $CsvPath -Encoding UTF8
}
if (-not $PSBoundParameters.ContainsKey('CsvPath')) {
    Remove-StorSafeOldReport -Directory $config.OutputDirectory -Prefix 'StorSafe-Loaded-Tapes' -RetentionDays $config.RetentionDays
}

Write-Host ''
Write-Host 'Loaded virtual tapes' -ForegroundColor White
if ($loadedTapes.Count -eq 0) {
    Write-Host 'No virtual tape drives reported a status of loaded.' -ForegroundColor Green
} else {
    $loadedTapes | Select-Object Server, VirtualTapeLibrary, DriveName, DriveStatus, TapeName, TapeBarcode | Format-Table -AutoSize | Out-Host
}

Write-Host ''
Write-Host ("Loaded tapes : {0}" -f $loadedTapes.Count)
Write-Host ("API errors   : {0}" -f $errors.Count) -ForegroundColor $(if ($errors.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host ("CSV report   : {0}" -f $CsvPath)

if ($errors.Count -gt 0) {
    Write-Host ''
    Write-Host 'Errors' -ForegroundColor Red
    $errors | Format-Table Server, VirtualTapeLibrary, Stage, Error -AutoSize -Wrap | Out-Host
    exit 2
}
if ($loadedTapes.Count -gt 0) { exit 1 }
exit 0
