<#
.SYNOPSIS
Reports StorSafe deduplication policy, reclamation/prune and (optionally) virtual tape state.

.DESCRIPTION
Appliances, transport and credential files come from StorSafe.config.json (or -ConfigPath /
$env:STORSAFE_CONFIG). Interactive by default; for Task Scheduler use -All (or -Server) with
-NonInteractive and a CredentialFile per server (see New-StorSafeCredentialFile in StorSafe.psm1).

Exit codes: 0 idle, 1 work active or queued, 2 attention / unknown state / API error, 3 usage or config error.

.EXAMPLE
.\Get-StorSafeActivity.ps1
.EXAMPLE
.\Get-StorSafeActivity.ps1 -All -NonInteractive -IncludeTapeInventory
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string[]]$Server,
    [switch]$All,
    [PSCredential]$Credential,
    [switch]$NonInteractive,
    [switch]$IncludeTapeInventory,
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

# ---------------------------------------------------------------------------
# Setup: config, server selection and credentials. Any failure here is exit 3.
# ---------------------------------------------------------------------------
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

    if (-not $CsvPath) { $CsvPath = Get-StorSafeReportPath -Directory $config.OutputDirectory -Prefix 'StorSafe-Activity' }
} catch {
    Write-StorSafeUsageError $_.Exception.Message
    exit 3
}

# ---------------------------------------------------------------------------
# Status classification, pinned to the values documented in the REST API guide.
# Anything not listed is 'Unknown' and is treated as needing attention.
# ---------------------------------------------------------------------------
function Get-StatusCategory {
    param([AllowNull()][AllowEmptyString()][string]$Status)
    if ([string]::IsNullOrWhiteSpace($Status)) { return 'Unknown' }
    $s = $Status.Trim().ToLowerInvariant()
    # Compound replication states (cascade/parallel), e.g. completedfailed, pendingfailed.
    if ($s -match 'failed') { return 'Attention' }
    switch -Regex ($s) {
        '^(running|syncing|inprogress|active|started|processing|preparing|stopping|deduplicating)$' { return 'Active' }
        '^(queued|pending|waiting|waitingfortapedrive|hold|resume|completedpending|pendingcompleted)$' { return 'Queued' }
        '^(error|cancelled|stopped|suspended|outofsync|offline|incomplete)$' { return 'Attention' }
        '^(completed|idle|insync|online|none|disabled|pure|plain|mixed)$' { return 'Inactive' }
    }
    return 'Unknown'
}

$runTimestamp = Get-StorSafeTimestamp
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param($ServerConfig, [bool]$Reachable, [string]$Check, [string]$Object, [string]$Field,
          [string]$Status, [string]$Category, [string]$Detail = '', [string]$ErrorText = '')
    $results.Add([pscustomobject]@{
        Timestamp = $runTimestamp
        Server    = $ServerConfig.Name
        Host      = $ServerConfig.Host
        Reachable = $Reachable
        Check     = $Check
        Object    = $Object
        Field     = $Field
        Status    = $Status
        Category  = $Category
        Detail    = $Detail
        Error     = $ErrorText
    })
}

function Add-EndpointError {
    param($ServerConfig, [string]$Check, $ErrorRecord)
    $category = Get-StorSafeErrorCategory $ErrorRecord
    $resultCategory = if ($category -eq 'Auth') { 'AuthError' } elseif ($category -eq 'Connection') { 'ConnectionError' } else { 'EndpointError' }
    Add-Result $ServerConfig ($category -ne 'Connection') $Check '' '' '' $resultCategory '' $ErrorRecord.Exception.Message
}

# ---------------------------------------------------------------------------
# Collect
# ---------------------------------------------------------------------------
foreach ($s in $selectedServers) {
    $connection = $null
    Write-Host "Checking $($s.Name) [$($s.Host)]..." -ForegroundColor Cyan

    try {
        $connection = Connect-StorSafe -ServerConfig $s -Credential $credentialByName[$s.Name]
    } catch {
        $category = Get-StorSafeErrorCategory $_
        $resultCategory = if ($category -eq 'Auth') { 'AuthError' } else { 'ConnectionError' }
        Add-Result $s ($category -eq 'Auth') 'Login' '' '' '' $resultCategory '' $_.Exception.Message
        continue
    }

    try {
        # Deduplication policies: data.policies[]
        try {
            $response = Invoke-StorSafeApi -Connection $connection -Path '/dedupepolicy'
            $policies = @(Get-OptionalValue (Get-OptionalValue $response 'data' $null) 'policies' @())
            if ($policies.Count -eq 0) {
                Add-Result $s $true 'Dedupe policies' '' '' 'No policies defined' 'Inactive'
            }
            foreach ($p in $policies) {
                $status = [string](Get-OptionalValue $p 'status' '')
                $category = Get-StatusCategory $status
                # A suspended policy only matters if it has tapes assigned (e.g. an unused Default_Policy on a replica target does not).
                if ((Get-OptionalValue $p 'suspended' $false) -eq $true -and [int](Get-OptionalValue $p 'tapes' 0) -gt 0) { $category = 'Attention' }
                $detail = 'trigger={0}; tapes={1}; lastrun={2}; nextrun={3}; suspended={4}' -f `
                    (Get-OptionalValue $p 'trigger' ''), (Get-OptionalValue $p 'tapes' ''),
                    (ConvertFrom-StorSafeEpoch (Get-OptionalValue $p 'lastrun' 0)),
                    (ConvertFrom-StorSafeEpoch (Get-OptionalValue $p 'nextrun' 0)),
                    (Get-OptionalValue $p 'suspended' $false)
                Add-Result $s $true 'Dedupe policies' ([string](Get-OptionalValue $p 'name' "Policy $(Get-OptionalValue $p 'id' '?')")) 'status' $status $category $detail
            }
        } catch {
            Add-EndpointError $s 'Dedupe policies' $_
        }

        # Reclamation and index prune: data.reclaimstatus / data.prunestatus (idle|running|failed).
        # Both are empty strings on a standby node or a server without a Deduplication Repository.
        try {
            $response = Invoke-StorSafeApi -Connection $connection -Path '/deduplication/reclamation/status'
            $data = Get-OptionalValue $response 'data' $null
            foreach ($field in @('reclaimstatus', 'prunestatus')) {
                $value = [string](Get-OptionalValue $data $field '')
                if ([string]::IsNullOrWhiteSpace($value)) {
                    Add-Result $s $true 'Reclamation' 'Deduplication Repository' $field '' 'Inactive' 'Not applicable (standby node or no repository)'
                } else {
                    Add-Result $s $true 'Reclamation' 'Deduplication Repository' $field $value (Get-StatusCategory $value)
                }
            }
        } catch {
            Add-EndpointError $s 'Reclamation' $_
        }

        # Virtual tape inventory (paged). Only non-idle tape states are written as rows,
        # plus one summary row, to keep the CSV readable on large estates.
        if ($IncludeTapeInventory) {
            try {
                $tapes = @(Get-StorSafePagedCollection -Connection $connection -Path '/virtualtape' -CollectionName 'tapes' -Body @{ location = 'vtl' })
                $counts = @{ Active = 0; Queued = 0; Attention = 0; Unknown = 0 }
                foreach ($t in $tapes) {
                    $label = '{0} [{1}]' -f (Get-OptionalValue $t 'name' ''), (Get-OptionalValue $t 'barcode' '')
                    foreach ($field in @('devicestatus', 'dedupestatus', 'replstatus')) {
                        $value = [string](Get-OptionalValue $t $field '')
                        # Empty dedupe/repl status = not configured for this tape.
                        if ([string]::IsNullOrWhiteSpace($value) -and $field -ne 'devicestatus') { continue }
                        $category = Get-StatusCategory $value
                        if ($category -eq 'Inactive') { continue }
                        $counts[$category]++
                        Add-Result $s $true 'Virtual tapes' $label $field $value $category ('usedmb={0}; sizemb={1}' -f (Get-OptionalValue $t 'usedmb' ''), (Get-OptionalValue $t 'sizemb' ''))
                    }
                }
                Add-Result $s $true 'Virtual tapes' 'Summary' 'count' ([string]$tapes.Count) 'Inactive' `
                    ('tapes={0}; active={1}; queued={2}; attention={3}; unknown={4}' -f $tapes.Count, $counts.Active, $counts.Queued, $counts.Attention, $counts.Unknown)
            } catch {
                Add-EndpointError $s 'Virtual tapes' $_
            }
        }
    } finally {
        Disconnect-StorSafe $connection
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$results | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
if (-not $PSBoundParameters.ContainsKey('CsvPath')) {
    Remove-StorSafeOldReport -Directory $config.OutputDirectory -Prefix 'StorSafe-Activity' -RetentionDays $config.RetentionDays
}

$active    = @($results | Where-Object Category -eq 'Active')
$queued    = @($results | Where-Object Category -eq 'Queued')
$attention = @($results | Where-Object Category -in @('Attention', 'Unknown'))
$errors    = @($results | Where-Object Category -in @('ConnectionError', 'AuthError', 'EndpointError'))

Write-Host ''
Write-Host 'Estate summary' -ForegroundColor White
Write-Host ('Active work : {0}' -f $active.Count) -ForegroundColor $(if ($active.Count) { 'Yellow' } else { 'Green' })
Write-Host ('Queued work : {0}' -f $queued.Count) -ForegroundColor $(if ($queued.Count) { 'Yellow' } else { 'Green' })
Write-Host ('Attention   : {0}' -f $attention.Count) -ForegroundColor $(if ($attention.Count) { 'Red' } else { 'Green' })
Write-Host ('API errors  : {0}' -f $errors.Count) -ForegroundColor $(if ($errors.Count) { 'Red' } else { 'Green' })
Write-Host ("CSV report  : {0}" -f $CsvPath)

if ($active.Count -gt 0) {
    Write-Host ''
    Write-Host 'ACTIVE OPERATIONS' -ForegroundColor Yellow
    $active | Select-Object Server, Check, Object, Field, Status | Format-Table -AutoSize | Out-Host
} else {
    Write-Host ''
    Write-Host 'No active operations reported.' -ForegroundColor Green
}

if ($queued.Count -gt 0) {
    Write-Host 'QUEUED OR WAITING OPERATIONS' -ForegroundColor Yellow
    $queued | Select-Object Server, Check, Object, Field, Status | Format-Table -AutoSize | Out-Host
}

if ($attention.Count -gt 0 -or $errors.Count -gt 0) {
    Write-Host 'ITEMS REQUIRING ATTENTION' -ForegroundColor Red
    @($attention + $errors) | Select-Object Server, Check, Object, Category, Status, Detail, Error | Format-Table -AutoSize -Wrap | Out-Host
}

if ($errors.Count -gt 0 -or $attention.Count -gt 0) { exit 2 }
if ($active.Count -gt 0 -or $queued.Count -gt 0) { exit 1 }
exit 0
