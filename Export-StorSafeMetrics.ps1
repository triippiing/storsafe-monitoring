<#
.SYNOPSIS
Collects StorSafe health, capacity, deduplication, replication, tape, hardware, configuration and event log
data and writes it in Prometheus text format for the windows_exporter textfile collector.

.DESCRIPTION
Read-only. Apart from login/logout, every call is a GET, except one PUT /server/event, which only downloads
the event log as CSV (it changes nothing on the appliance).

Run it from Task Scheduler every 5 minutes with -All -NonInteractive (CredentialFile per server in
StorSafe.config.json). The .prom file is written to a temp name and renamed so that windows_exporter
never reads a half-written file.

Checks run on three cadences:
  - every run: health, queues, activity, run history, event log;
  - every 15 minutes: the full virtual tape inventory;
  - every 60 minutes: configuration and inventory that rarely changes (server info, patches, network, ...).
Results of the slower checks are cached in the state folder and re-emitted on the runs in between.

Settings (all optional, under Defaults in StorSafe.config.json):
  StateDirectory         'state'   collector state: event log bookmark, check cache
  CollectEventLog        true      download new event log entries every run
  EventLogDirectory      'events'  daily raw CSV archive of the event log, per appliance
  EventLogRetentionDays  90        archive files older than this are deleted
  DisabledChecks         []        check names to skip, e.g. ["tapecaching","users"]

Output directory precedence: -TextfileDirectory, then Defaults.TextfileDirectory in the config
(relative paths resolve against the config file's folder), then the 'metrics' folder next to the config.

Parallel mode: with more than two appliances the collector runs one child process per appliance, -MaxParallel at a
time (default: one per four appliances, at most 8), each writing metrics\storsafe-<server>.prom; storsafe.prom then
only carries the collector's own summary. -MaxParallel 1 forces the single-process mode.

Exit codes: 0 all checks succeeded, 2 a server or check failed (metrics still written), 3 usage/config error.

.EXAMPLE
.\Export-StorSafeMetrics.ps1 -All -NonInteractive
.EXAMPLE
.\Export-StorSafeMetrics.ps1 -Server STORSAFE-01 -TextfileDirectory .\out   # interactive test run
.EXAMPLE
.\Export-StorSafeMetrics.ps1 -All -NonInteractive -Refresh   # ignore the cache and run every check now
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string[]]$Server,
    [switch]$All,
    [PSCredential]$Credential,
    [switch]$NonInteractive,
    [string]$TextfileDirectory,
    [string]$FileName = 'storsafe.prom',
    [switch]$Refresh,
    [int]$MaxParallel = 0,

    [ValidateSet('http', 'https')][string]$Scheme,
    [int]$Port = -1,
    [switch]$SkipCertificateCheck
)

Set-StrictMode -Version Latest
$script:PackageVersion = try { (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -ErrorAction Stop | Select-Object -First 1).Trim() } catch { 'unknown' }
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

    if (-not $TextfileDirectory) { $TextfileDirectory = $config.TextfileDirectory }
    foreach ($dir in @($TextfileDirectory, $config.StateDirectory)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
} catch {
    Write-StorSafeUsageError $_.Exception.Message
    exit 3
}

# ---------------------------------------------------------------------------
# Metric builder: keeps HELP/TYPE once per metric family, in first-seen order.
# While a cached check runs, $script:capture records its samples so they can be replayed later.
# ---------------------------------------------------------------------------
$families = [ordered]@{}
$script:capture = $null

function ConvertTo-LabelValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim().Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n')
}

function Add-Sample {
    param([string]$Name, [string]$Help, [string]$Type, [string]$Line)
    if (-not $families.Contains($Name)) {
        $families[$Name] = [pscustomobject]@{ Help = $Help; Type = $Type; Samples = [System.Collections.Generic.List[string]]::new() }
    }
    $families[$Name].Samples.Add($Line)
}

function Add-Metric {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Help,
        [Parameter(Mandatory)][AllowNull()]$Value,
        [System.Collections.IDictionary]$Labels = @{},
        [string]$Type = 'gauge'
    )
    if ($null -eq $Value -or [string]$Value -eq '') { return }
    $number = 0.0
    if ($Value -is [bool]) { $number = [double][int]$Value }
    elseif (-not [double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return }

    $labelText = ''
    if ($Labels.Count -gt 0) {
        $pairs = foreach ($key in $Labels.Keys) { '{0}="{1}"' -f $key, (ConvertTo-LabelValue $Labels[$key]) }
        $labelText = '{' + ($pairs -join ',') + '}'
    }
    $line = '{0}{1} {2}' -f $Name, $labelText, $number.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    Add-Sample $Name $Help $Type $line
    if ($null -ne $script:capture) { $script:capture.Add([pscustomobject]@{ n = $Name; h = $Help; t = $Type; s = $line }) }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-DataField {
    # Some endpoints return fields under 'data', others at the top level (e.g. storagethreshold, tapecaching).
    param($Response, [string]$Name, $Default = $null)
    $data = Get-OptionalValue $Response 'data' $null
    $value = Get-OptionalValue $data $Name $null
    if ($null -eq $value) { $value = Get-OptionalValue $Response $Name $Default }
    return $value
}

function Get-DataArray {
    # Endpoints that return a list either as data[] or data.<collection>[].
    param($Response, [string]$Collection)
    # Read the property directly: returning it through a function would unroll a one-element array.
    $dataProperty = $Response.PSObject.Properties['data']
    if ($null -eq $dataProperty -or $null -eq $dataProperty.Value) { return @() }
    $data = $dataProperty.Value
    if ($data -is [System.Array]) { return $data }
    $collectionProperty = $data.PSObject.Properties[$Collection]
    if ($null -eq $collectionProperty -or $null -eq $collectionProperty.Value) { return @() }
    return @($collectionProperty.Value)
}

function Get-Prop {
    # Dotted path lookup that tolerates missing properties: Get-Prop $obj 'failoverstatus.status'.
    # Arrays are unrolled, so wrap the call in @() when a list is expected.
    param($Object, [string]$Path, $Default = $null)
    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) { return $Default }
        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) { return $Default }
        $current = $property.Value
    }
    if ($null -eq $current) { return $Default }
    return $current
}

function Get-CleanState {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim().ToLowerInvariant()
}

function ConvertTo-Flag {
    # true/false in any of the forms the API uses (bool, "true", 1) -> 1/0; anything else -> $null.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return [int]$Value }
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -in @('true', '1', 'yes', 'enabled', 'on')) { return 1 }
    if ($text -in @('false', '0', 'no', 'disabled', 'off')) { return 0 }
    return $null
}

function ConvertFrom-RatioText {
    # "1.9 : 1" -> 1.9, "> 10000:1" -> 10000, "N/A" -> $null
    param($Text)
    if ($null -eq $Text) { return $null }
    if (([string]$Text) -match '([0-9]+(?:\.[0-9]+)?)\s*:\s*1') { return [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture) }
    return $null
}

function Add-Count {
    param([hashtable]$Table, $Key, [double]$Amount = 1)
    if ($Table.ContainsKey($Key)) { $Table[$Key] += $Amount } else { $Table[$Key] = $Amount }
}

function New-Label {
    # New-Label $l 'policy' $name 'status' $status -> [ordered]@{ server = ...; policy = ...; status = ... }
    $labels = [ordered]@{ server = $args[0].server }
    for ($i = 1; $i -lt $args.Count; $i += 2) { $labels[[string]$args[$i]] = $args[$i + 1] }
    return $labels
}

function Get-SafeFileName {
    param([string]$Name)
    return ($Name -replace '[^A-Za-z0-9._-]', '_')
}

function Read-JsonState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { Write-Warning "Ignoring unreadable state file ${Path}: $($_.Exception.Message)"; return $null }
}

function Write-JsonState {
    param([string]$Path, $Object)
    $temp = "$Path.$PID.tmp"
    [System.IO.File]::WriteAllText($temp, ($Object | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-UnixNow { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# Lookups shared between checks within one appliance run ($x is a per-server hashtable).
function Get-Policies {
    param($c, [hashtable]$x)
    if (-not $x.ContainsKey('Policies')) { $x.Policies = @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/dedupepolicy') 'policies') }
    return $x.Policies
}

function Get-LibraryNames {
    param($c, [hashtable]$x)
    if (-not $x.ContainsKey('Libraries')) { $x.Libraries = @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/virtuallibrary') 'libraries') }
    $names = @{}
    foreach ($v in $x.Libraries) { $names[[string](Get-OptionalValue $v 'id' '')] = [string](Get-OptionalValue $v 'name' '') }
    return $names
}

function Get-ApplianceTime {
    # Appliance local wall-clock time (the event log range is expressed in it).
    param($c, [hashtable]$x)
    if (-not $x.ContainsKey('SystemTime')) {
        $r = Invoke-StorSafeApi -Connection $c -Path '/server/properties/time'
        $x.SystemTime = [string](Get-DataField $r 'systemtime' '')
        $x.EpochTime = [double](Get-DataField $r 'epochetime' 0)
    }
    return [datetime]::ParseExact($x.SystemTime.Trim(), 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-RunHistory {
    param($c, $PolicyId, [long]$From)
    $runs = [System.Collections.Generic.List[object]]::new()
    $offset = 0
    while ($true) {
        $r = Invoke-StorSafeApi -Connection $c -Path ('/dedupepolicy/runhistory/{0}?fromts={1}&offset={2}&limit=1000' -f $PolicyId, $From, $offset)
        $page = @(Get-DataArray $r 'jobs')
        foreach ($run in $page) { $runs.Add($run) }
        if ($page.Count -lt 1000) { break }
        $offset += 1000
    }
    return $runs.ToArray()
}

function Get-ActiveStatus {
    # Per-policy scan/replication activity, fetched once per run.
    param($c, [hashtable]$x, $PolicyId)
    if (-not $x.ContainsKey('ActiveStatus')) { $x.ActiveStatus = @{} }
    $key = [string]$PolicyId
    if (-not $x.ActiveStatus.ContainsKey($key)) {
        $x.ActiveStatus[$key] = Get-OptionalValue (Invoke-StorSafeApi -Connection $c -Path ('/dedupepolicy/activestatus/{0}' -f $PolicyId)) 'data' $null
    }
    return $x.ActiveStatus[$key]
}

function Get-DriveNames {
    # Drive serial number -> drive name, for library drives and standalone drives. Job records only carry serials.
    param($c, [hashtable]$x)
    if ($x.ContainsKey('DriveNames')) { return $x.DriveNames }
    $names = @{}
    try {
        if (-not $x.ContainsKey('Libraries')) { $x.Libraries = @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/virtuallibrary') 'libraries') }
        foreach ($lib in $x.Libraries) {
            $id = Get-OptionalValue $lib 'id' $null
            if ($null -eq $id) { continue }
            foreach ($d in @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path ('/virtuallibrary/drive/{0}' -f $id)) 'drives')) {
                $sn = [string](Get-OptionalValue $d 'serialno' ''); if ($sn) { $names[$sn] = [string](Get-OptionalValue $d 'name' '') }
            }
        }
        foreach ($d in @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/virtualdrive') 'drives')) {
            $sn = [string](Get-OptionalValue $d 'serialno' ''); if ($sn) { $names[$sn] = [string](Get-OptionalValue $d 'name' '') }
        }
    } catch { Write-Verbose "drive names: $($_.Exception.Message)" }
    $x.DriveNames = $names
    return $names
}

function Resolve-DriveName {
    param([hashtable]$Names, $Serial)
    $sn = [string]$Serial
    if (-not $sn) { return '' }
    if ($Names.ContainsKey($sn) -and $Names[$sn]) { return $Names[$sn] }
    return $sn
}

function Update-FirstSeen {
    # The API has no start time for queued jobs, so the collector remembers when it first saw each job key.
    # Keys that are no longer present are dropped. Returns key -> Unix time.
    param([string]$Path, [string[]]$Keys)
    $now = Get-UnixNow
    $old = @{}
    $saved = Read-JsonState $Path
    if ($null -ne $saved) { foreach ($p in $saved.PSObject.Properties) { $old[$p.Name] = [long]$p.Value } }
    $current = [ordered]@{}
    foreach ($k in $Keys) {
        if (-not $k -or $current.Contains($k)) { continue }
        $current[$k] = if ($old.ContainsKey($k)) { $old[$k] } else { $now }
    }
    Write-JsonState $Path $current
    return $current
}

# Per-job detail calls are capped so a huge queue cannot blow the collection interval; jobs beyond the cap get list data only.
$maxJobDetails = 100

# ---------------------------------------------------------------------------
# Event log: PUT /server/event returns CSV. The column layout is not documented, so columns are
# found by header name, falling back to the values' shape.
# ---------------------------------------------------------------------------
function Split-CsvLine {
    param([string]$Line, [int]$Count = 64)
    $headers = 1..$Count | ForEach-Object { "c$_" }
    $row = ConvertFrom-Csv -InputObject $Line -Header $headers
    $values = foreach ($h in $headers) { $v = $row.$h; if ($null -eq $v) { break }; [string]$v }
    return @($values)
}

function Get-EventSeverity {
    param([string]$Value)
    $v = $Value.Trim().ToLowerInvariant()
    if ($v -eq '') { return 'unknown' }
    switch -Regex ($v) {
        '^(c|crit)'  { return 'critical' }
        '^(e|err)'   { return 'error' }
        '^(w|warn)'  { return 'warning' }
        '^(i|info)'  { return 'informational' }
    }
    return $v
}

function Get-EventLayout {
    # Returns @{ HasHeader; Headers; Severity; Date; Time; Id; Message } with column indexes (-1 if absent).
    param([string[]]$Lines)
    $first = @(Split-CsvLine $Lines[0])
    $layout = @{ HasHeader = $false; Headers = $first; Severity = -1; Date = -1; Time = -1; Id = -1; Message = -1 }
    # A header row has short names and no numeric fields (data rows carry dates, times and event IDs).
    if (@($first | Where-Object { $_ -match '\d' -or $_.Length -gt 40 }).Count -eq 0) {
        for ($i = 0; $i -lt $first.Count; $i++) {
            $h = $first[$i].Trim().ToLowerInvariant()
            if ($layout.Severity -lt 0 -and $h -match '^(event )?(type|severity|level)$') { $layout.Severity = $i; $layout.HasHeader = $true }
            elseif ($layout.Date -lt 0 -and $h -match 'date') { $layout.Date = $i; $layout.HasHeader = $true }
            elseif ($layout.Time -lt 0 -and $h -match 'time') { $layout.Time = $i; $layout.HasHeader = $true }
            elseif ($layout.Id -lt 0 -and $h -match '^(event )?(id|code|number)$') { $layout.Id = $i; $layout.HasHeader = $true }
            elseif ($layout.Message -lt 0 -and $h -match 'message|description|text|^event$') { $layout.Message = $i; $layout.HasHeader = $true }
        }
    }
    if (-not $layout.HasHeader) {
        # No recognisable header: guess from the values of the first rows.
        $sample = @($Lines | Select-Object -First 20 | ForEach-Object { , @(Split-CsvLine $_) })
        $columns = ($sample | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
        $layout.Headers = @(1..$columns | ForEach-Object { "Column$_" })
        for ($i = 0; $i -lt $columns; $i++) {
            $values = @($sample | ForEach-Object { if ($_.Count -gt $i) { $_[$i] } })
            if ($layout.Severity -lt 0 -and @($values | Where-Object { $_ -match '^(?i)(i|w|e|c|info\w*|warn\w*|err\w*|crit\w*)$' }).Count -eq $values.Count) { $layout.Severity = $i; continue }
            if ($layout.Date -lt 0 -and @($values | Where-Object { $_ -match '^\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}' }).Count -eq $values.Count) { $layout.Date = $i; continue }
            if ($layout.Time -lt 0 -and @($values | Where-Object { $_ -match '^\d{1,2}:\d{2}' }).Count -eq $values.Count) { $layout.Time = $i; continue }
            if ($layout.Id -lt 0 -and @($values | Where-Object { $_ -match '^\d+$' }).Count -eq $values.Count) { $layout.Id = $i; continue }
        }
        $longest = -1; $best = -1
        for ($i = 0; $i -lt $columns; $i++) {
            if ($i -in @($layout.Severity, $layout.Date, $layout.Time, $layout.Id)) { continue }
            $avg = ($sample | ForEach-Object { if ($_.Count -gt $i) { $_[$i].Length } else { 0 } } | Measure-Object -Average).Average
            if ($avg -gt $longest) { $longest = $avg; $best = $i }
        }
        $layout.Message = $best
    }
    return $layout
}

function ConvertTo-EventEpoch {
    # Appliance local date/time text -> Unix time, assuming the appliance and this host share a time zone.
    param([string]$Text)
    $t = ($Text -replace '\s+', ' ').Trim()
    if (-not $t) { return 0 }
    $formats = @('MM/dd/yyyy HH:mm:ss', 'M/d/yyyy HH:mm:ss', 'M/d/yyyy H:mm:ss', 'yyyy-MM-dd HH:mm:ss', 'yyyy/MM/dd HH:mm:ss', 'dd/MM/yyyy HH:mm:ss', 'MM/dd/yyyy', 'yyyy-MM-dd')
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact($t, [string[]]$formats, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
        return [long]([DateTimeOffset]$parsed).ToUnixTimeSeconds()
    }
    return 0
}

function Get-TextHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').Substring(0, 16) }
    finally { $sha.Dispose() }
}

function Invoke-EventLogCheck {
    param($c, $l, [hashtable]$x)
    $serverFile = Get-SafeFileName $l.server
    $statePath = Join-Path $config.StateDirectory ("events-{0}.json" -f $serverFile)
    $state = Read-JsonState $statePath
    $counts = @{}; $recent = @(); $lastHashes = @{}; $lastEnd = ''
    if ($null -ne $state) {
        $lastEnd = [string](Get-OptionalValue $state 'LastEnd' '')
        $countsObj = Get-OptionalValue $state 'Counts' $null
        if ($null -ne $countsObj) { foreach ($p in $countsObj.PSObject.Properties) { $counts[$p.Name] = [double]$p.Value } }
        $recent = @(Get-OptionalValue $state 'Recent' @())
        foreach ($h in @(Get-OptionalValue $state 'LastHashes' @())) { $lastHashes[[string]$h] = $true }
    }

    $now = Get-ApplianceTime $c $x
    $end = $now.ToString('yyyyMMddHHmmss')
    # First run: the last 24 hours. Later runs: from the previous end (inclusive); duplicates are dropped by hash.
    $start = if ($lastEnd -match '^\d{14}$') { $lastEnd } else { $now.AddHours(-24).ToString('yyyyMMddHHmmss') }
    $text = Invoke-StorSafeDownload -Connection $c -Path '/server/event' -Method Put -Body @{ range = "$start-$end" }

    $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' -and $_ -notmatch '^sep=' })
    $newRows = [System.Collections.Generic.List[object]]::new()
    $hashes = [System.Collections.Generic.List[string]]::new()
    $layout = $null
    if ($lines.Count -gt 0) {
        $layout = Get-EventLayout $lines
        $dataLines = if ($layout.HasHeader) { @($lines | Select-Object -Skip 1) } else { $lines }
        foreach ($line in $dataLines) {
            $hash = Get-TextHash $line
            $hashes.Add($hash)
            if ($lastHashes.ContainsKey($hash)) { continue }
            $newRows.Add([pscustomobject]@{ Line = $line; Fields = @(Split-CsvLine $line) })
        }
    }

    # Raw archive: one CSV per appliance per day (collector's date), header written once.
    if ($newRows.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $config.EventLogDirectory -PathType Container)) { New-Item -ItemType Directory -Path $config.EventLogDirectory -Force | Out-Null }
        $archive = Join-Path $config.EventLogDirectory ("StorSafe-Events-{0}-{1}.csv" -f $serverFile, (Get-Date -Format 'yyyyMMdd'))
        $out = [System.Collections.Generic.List[string]]::new()
        if (-not (Test-Path -LiteralPath $archive) -and $layout.HasHeader) { $out.Add($lines[0]) }
        foreach ($row in $newRows) { $out.Add($row.Line) }
        [System.IO.File]::AppendAllText($archive, (($out -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        $cutoff = (Get-Date).AddDays(-$config.EventLogRetentionDays)
        Get-ChildItem -LiteralPath $config.EventLogDirectory -Filter ("StorSafe-Events-{0}-*.csv" -f $serverFile) -File |
            Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $newBySeverity = @{}
    foreach ($row in $newRows) {
        $f = $row.Fields
        $sev = if ($layout.Severity -ge 0 -and $f.Count -gt $layout.Severity) { Get-EventSeverity $f[$layout.Severity] } else { 'unknown' }
        Add-Count $counts $sev
        Add-Count $newBySeverity $sev
        if ($sev -ne 'informational') {
            $when = @(@($layout.Date, $layout.Time) | Where-Object { $_ -ge 0 -and $f.Count -gt $_ } | ForEach-Object { $f[$_] }) -join ' '
            $id = if ($layout.Id -ge 0 -and $f.Count -gt $layout.Id) { $f[$layout.Id] } else { '' }
            $msg = if ($layout.Message -ge 0 -and $f.Count -gt $layout.Message) { $f[$layout.Message] } else { $row.Line }
            if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
            $recent += [pscustomobject]@{ time = $when; epoch = (ConvertTo-EventEpoch $when); severity = $sev; id = $id; message = $msg }
        }
    }
    $recent = @($recent | Select-Object -Last 20)

    foreach ($sev in @('critical', 'error', 'warning', 'informational')) { if (-not $counts.ContainsKey($sev)) { $counts[$sev] = 0 } }
    foreach ($sev in $counts.Keys) {
        Add-Metric 'storsafe_events_total' 'Event log entries seen by the collector, by severity (counter since the state file was created).' $counts[$sev] (New-Label $l 'severity' $sev) 'counter'
        $n = if ($newBySeverity.ContainsKey($sev)) { $newBySeverity[$sev] } else { 0 }
        Add-Metric 'storsafe_events_new' 'Event log entries new in this collector run, by severity.' $n (New-Label $l 'severity' $sev)
    }
    $i = 0
    foreach ($e in $recent) {
        $i++
        # Value is the event time as Unix time (parsed from the appliance's local date/time), or the sequence number if unparseable.
        $value = Get-OptionalValue $e 'epoch' $null
        if ($null -eq $value -or [double]$value -le 0) { $value = $i }
        Add-Metric 'storsafe_event_recent' 'Most recent warning/error/critical events (value is the event time as Unix time; a small value is a sequence number when the time could not be parsed).' $value (New-Label $l 'severity' $e.severity 'time' $e.time 'id' $e.id 'message' $e.message)
    }
    Add-Metric 'storsafe_eventlog_columns_detected' 'Event log CSV columns recognised (1 = header found by name, 0 = guessed from values).' ([int]($null -ne $layout -and $layout.HasHeader)) (New-Label $l)

    Write-JsonState $statePath ([ordered]@{ LastEnd = $end; Counts = $counts; Recent = $recent; LastHashes = @($hashes | Select-Object -Last 5000)
        Columns = $(if ($null -ne $layout) { $layout.Headers } else { @() }) })
}

# ---------------------------------------------------------------------------
# Checks. Each is independent; a failure is recorded in storsafe_check_success and does not stop the others.
# Each scriptblock gets ($c = connection, $l = base labels, $x = per-appliance lookup cache).
# ---------------------------------------------------------------------------
$checks = [ordered]@{
    # ---- Health and capacity (every run) ----
    'version' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/server/properties/version'
        $info = [ordered]@{ server = $l.server
            product = Get-DataField $r 'product' ''; version = Get-DataField $r 'version' ''
            build = Get-DataField $r 'build' ''; apiversion = Get-DataField $r 'apiversion' '' }
        Add-Metric 'storsafe_info' 'Appliance product and version (value is always 1).' 1 $info
    }
    'time' = {
        param($c, $l, $x)
        Get-ApplianceTime $c $x | Out-Null
        Add-Metric 'storsafe_time_seconds' 'Appliance clock (Unix time).' $x.EpochTime (New-Label $l)
        Add-Metric 'storsafe_time_offset_seconds' 'Appliance clock minus the collector host clock, in seconds.' ($x.EpochTime - (Get-UnixNow)) (New-Label $l)
    }
    'failover' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/server/failover/status'
        $status = Get-CleanState (Get-DataField $r 'status' '')
        Add-Metric 'storsafe_failover_status' 'Failover status (1 for the current status label).' 1 ([ordered]@{ server = $l.server; status = $status })
        Add-Metric 'storsafe_failover_healthy' 'Failover is normal or not configured (1) or in another state (0).' ([int]($status -in @('normal', 'notconfigured'))) ([ordered]@{ server = $l.server })
    }
    'storagepool' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/physicalresource/storagepool'
        foreach ($p in (Get-DataArray $r 'storagepools')) {
            $pl = [ordered]@{ server = $l.server; pool = Get-OptionalValue $p 'name' ''; resourcetype = Get-OptionalValue $p 'resourcetype' '' }
            Add-Metric 'storsafe_storagepool_size_bytes' 'Storage pool size in bytes.' (Get-OptionalValue $p 'size' $null) $pl
            Add-Metric 'storsafe_storagepool_used_bytes' 'Storage pool used size in bytes.' (Get-OptionalValue $p 'used' $null) $pl
        }
    }
    'physicaldevice' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/physicalresource/physicaldevice'
        foreach ($d in (Get-DataArray $r 'physicaldevices')) {
            if ((Get-OptionalValue $d 'type' '') -ne 'disk') { continue }
            if ((Get-OptionalValue $d 'isforeign' $false) -eq $true) { continue }   # owned by the failover partner
            $dl = [ordered]@{ server = $l.server; acsl = Get-OptionalValue $d 'acsl' ''; name = Get-OptionalValue $d 'name' ''
                category = Get-OptionalValue $d 'category' ''; reservation = Get-OptionalValue $d 'reservation' '' }
            Add-Metric 'storsafe_physicaldevice_size_bytes' 'Physical disk (LUN) size in bytes.' (Get-OptionalValue $d 'size' $null) $dl
            Add-Metric 'storsafe_physicaldevice_used_bytes' 'Physical disk (LUN) used size in bytes.' (Get-OptionalValue $d 'used' $null) $dl
            Add-Metric 'storsafe_physicaldevice_online' 'Physical disk (LUN) is online (1) or not (0).' ([int]((Get-CleanState (Get-OptionalValue $d 'status' '')) -eq 'online')) $dl
        }
    }
    'adapters' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/physicalresource/physicaladapter'
        foreach ($a in (Get-DataArray $r 'physicaladapters')) {
            $al = New-Label $l 'adapter' (Get-OptionalValue $a 'id' '') 'vendor' (Get-OptionalValue $a 'vendor' '') 'type' (Get-OptionalValue $a 'type' '') 'mode' (Get-OptionalValue $a 'mode' '') 'wwpn' (Get-OptionalValue $a 'wwpn' '')
            Add-Metric 'storsafe_adapter_paths' 'Paths through the physical adapter (FC/SCSI); a drop means lost storage paths.' (Get-OptionalValue $a 'paths' $null) $al
        }
    }
    'storagethreshold' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/server/storagethreshold'
        Add-Metric 'storsafe_storage_threshold_percent' 'Configured system storage usage alert threshold (percent).' (Get-DataField $r 'threshold' $null) ([ordered]@{ server = $l.server })
    }
    'deduperepository' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/deduplication'
        $d = Get-OptionalValue $r 'data' $null
        Add-Metric 'storsafe_dedupe_repository_enabled' 'Deduplication Repository exists on this appliance (1) or not (0).' (ConvertTo-Flag (Get-Prop $d 'enabled' $false)) (New-Label $l)
        if ((ConvertTo-Flag (Get-Prop $d 'enabled' $false)) -ne 1) { return }
        Add-Metric 'storsafe_dedupe_repository_info' 'Deduplication Repository configuration (value is always 1).' 1 (New-Label $l 'cluster' (Get-Prop $d 'name' '') 'type' (Get-Prop $d 'type' '') 'mode' (Get-Prop $d 'mode' '') 'nodetype' (Get-Prop $d 'nodetype' '') 'encryption' (Get-Prop $d 'encryption' ''))
        Add-Metric 'storsafe_dedupe_repository_failover_enabled' 'Standby node failover enabled for the repository.' (ConvertTo-Flag (Get-Prop $d 'failoverenabled' $null)) (New-Label $l)
        $fs = Get-Prop $d 'failoverstatus' $null
        if ($null -ne $fs) {
            $st = Get-CleanState (Get-Prop $fs 'status' ''); if (-not $st) { $st = 'unknown' }
            Add-Metric 'storsafe_dedupe_repository_failover_status' 'Repository failover status (1 for the current status label).' 1 (New-Label $l 'status' $st)
            $orig = [string](Get-Prop $fs 'originalname' ''); $cur = [string](Get-Prop $fs 'currentname' '')
            Add-Metric 'storsafe_dedupe_repository_taken_over' 'Standby node has taken over a failed node (original name differs from current name).' ([int]($orig -ne '' -and $cur -ne '' -and $orig -ne $cur)) (New-Label $l)
        }
        foreach ($node in @(Get-Prop $d 'nodes' @())) {
            $nodeName = [string](Get-Prop $node 'name' '')
            foreach ($role in @(@('datadisks', 'data'), @('indexes', 'index'), @('folders', 'folder'))) {
                foreach ($disk in @(Get-Prop $node $role[0] @())) {
                    $dl = New-Label $l 'node' $nodeName 'role' $role[1] 'name' (Get-Prop $disk 'name' '')
                    Add-Metric 'storsafe_dedupe_repository_disk_size_bytes' 'Deduplication Repository device size in bytes (data, index or folder).' (Get-Prop $disk 'size' $null) $dl
                    $id = Get-Prop $disk 'id' $null
                    if ($null -ne $id) {
                        try {
                            $s = Invoke-StorSafeApi -Connection $c -Path ('/logicalresource/status/{0}' -f $id)
                            $status = Get-CleanState (Get-DataField $s 'status' '')
                            Add-Metric 'storsafe_dedupe_repository_disk_online' 'Deduplication Repository device is online (1) or incomplete/offline (0).' ([int]($status -eq 'online')) $dl
                        } catch { Write-Verbose "$($l.server): status of repository device ${id}: $($_.Exception.Message)" }
                    }
                }
            }
        }
        Add-Metric 'storsafe_dedupe_repository_associated_servers' 'Servers associated with this deduplication cluster.' @(Get-Prop $d 'associatedservers' @()).Count (New-Label $l)
        if ((Get-Prop $d 'type' '') -eq 'objectstorage') {
            $o = Invoke-StorSafeApi -Connection $c -Path '/deduplication/objectstorage'
            Add-Metric 'storsafe_dedupe_repository_objectstorage_used_bytes' 'Object storage used by the repository per node, in bytes.' ([double](Get-DataField $o 'usedgb' 0) * 1GB) (New-Label $l 'account' (Get-DataField $o 'label' ''))
            Add-Metric 'storsafe_dedupe_repository_objectstorage_size_bytes' 'Object storage size configured for the repository, in bytes.' ([double](Get-Prop $d 'objectstoragegb' 0) * 1GB) (New-Label $l)
        }
    }

    # ---- Deduplication ----
    'reclamation' = {
        # The API only reports idle/running/failed, so the collector tracks transitions to give each run a start,
        # end and duration. Times are accurate to one collector interval.
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/deduplication/reclamation/status'
        $statePath = Join-Path $config.StateDirectory ("maintenance-{0}.json" -f (Get-SafeFileName $l.server))
        $saved = Read-JsonState $statePath
        $state = [ordered]@{}
        $now = Get-UnixNow
        foreach ($process in @('reclaim', 'prune')) {
            $status = Get-CleanState (Get-DataField $r ("{0}status" -f $process) '')
            if (-not $status) { $status = 'notapplicable' }   # standby node or no repository
            $pl = New-Label $l 'process' $process
            Add-Metric 'storsafe_dedupe_maintenance_status' 'Space reclamation / index prune status (1 for the current status label).' 1 ([ordered]@{ server = $l.server; process = $process; status = $status })

            $prev = Get-OptionalValue $saved $process $null
            $entry = [ordered]@{ status = $status; runningSince = [long](Get-OptionalValue $prev 'runningSince' 0)
                lastStart = [long](Get-OptionalValue $prev 'lastStart' 0); lastEnd = [long](Get-OptionalValue $prev 'lastEnd' 0)
                lastResult = [string](Get-OptionalValue $prev 'lastResult' '') }
            $prevStatus = [string](Get-OptionalValue $prev 'status' '')
            if ($status -eq 'running' -and $prevStatus -ne 'running') {
                $entry.runningSince = $now
            } elseif ($status -ne 'running' -and $prevStatus -eq 'running') {
                $entry.lastStart = $entry.runningSince; $entry.lastEnd = $now; $entry.lastResult = $status
                $entry.runningSince = 0
            }
            $state[$process] = $entry

            Add-Metric 'storsafe_dedupe_maintenance_running_since_timestamp_seconds' 'When the collector first saw the current reclamation/prune run (Unix time, 0 if not running).' $entry.runningSince $pl
            if ($entry.lastEnd -gt 0) {
                Add-Metric 'storsafe_dedupe_maintenance_last_run_start_timestamp_seconds' 'Start of the last completed reclamation/prune run seen by the collector (Unix time).' $entry.lastStart $pl
                Add-Metric 'storsafe_dedupe_maintenance_last_run_end_timestamp_seconds' 'End of the last completed reclamation/prune run seen by the collector (Unix time).' $entry.lastEnd $pl
                Add-Metric 'storsafe_dedupe_maintenance_last_run_duration_seconds' 'Duration of the last reclamation/prune run, to one collector interval.' ($entry.lastEnd - $entry.lastStart) $pl
                Add-Metric 'storsafe_dedupe_maintenance_last_run_result' 'Status the last reclamation/prune run ended in (1 for the result label).' 1 (New-Label $l 'process' $process 'result' $entry.lastResult)
            }
        }
        Write-JsonState $statePath $state
    }
    'dedupepolicy' = {
        param($c, $l, $x)
        foreach ($p in (Get-Policies $c $x)) {
            $pl = [ordered]@{ server = $l.server; policy = Get-OptionalValue $p 'name' ''; trigger = Get-OptionalValue $p 'trigger' '' }
            $sl = [ordered]@{ server = $l.server; policy = $pl.policy; status = Get-CleanState (Get-OptionalValue $p 'status' '') }
            Add-Metric 'storsafe_dedupe_policy_status' 'Deduplication policy status (1 for the current status label).' 1 $sl
            Add-Metric 'storsafe_dedupe_policy_suspended' 'Deduplication policy suspended (1) or not (0).' ([int]((Get-OptionalValue $p 'suspended' $false) -eq $true)) $pl
            Add-Metric 'storsafe_dedupe_policy_tapes' 'Number of tapes in the deduplication policy.' (Get-OptionalValue $p 'tapes' $null) $pl
            Add-Metric 'storsafe_dedupe_policy_last_run_timestamp_seconds' 'Last policy run (Unix time, 0 if not applicable).' (Get-OptionalValue $p 'lastrun' $null) $pl
            Add-Metric 'storsafe_dedupe_policy_next_run_timestamp_seconds' 'Next scheduled policy run (Unix time, 0 if not applicable).' (Get-OptionalValue $p 'nextrun' $null) $pl
            Add-Metric 'storsafe_dedupe_policy_info' 'Deduplication policy replication setup (value is always 1).' 1 (New-Label $l 'policy' $pl.policy 'cluster' (Get-OptionalValue $p 'cluster' '') 'replicationmode' (Get-OptionalValue $p 'replicationmode' 'none'))
            foreach ($t in @(Get-OptionalValue $p 'targetservers' @())) {
                Add-Metric 'storsafe_dedupe_policy_replication_suspended' 'Replication from the policy to the target server is suspended (1) or not (0).' (ConvertTo-Flag (Get-OptionalValue $t 'suspended' $false)) (New-Label $l 'policy' $pl.policy 'target' (Get-OptionalValue $t 'name' ''))
            }
        }
    }
    'dedupehistory' = {
        # Run history per policy: the latest run, the latest completed run's ratio and sizes, and 24-hour totals.
        # Prometheus keeps these over time, which gives the ratio trend.
        param($c, $l, $x)
        $now = Get-UnixNow
        foreach ($p in (Get-Policies $c $x)) {
            $id = Get-OptionalValue $p 'id' $null
            if ($null -eq $id) { continue }
            $policy = Get-OptionalValue $p 'name' ''
            $runs = @(Get-RunHistory $c $id ($now - 86400))
            $day = $runs
            if ($runs.Count -eq 0) { $runs = @(Get-RunHistory $c $id ($now - 30 * 86400)) }   # quiet policy: still find its last run

            $byStatus = @{ completed = 0; failed = 0; canceled = 0 }
            $scanned = 0.0; $unique = 0.0; $replData = 0.0; $replUnique = 0.0; $tapes = 0.0; $duration = 0.0
            foreach ($run in $day) {
                $st = Get-CleanState (Get-OptionalValue $run 'status' 'unknown')
                Add-Count $byStatus $st
                if ($st -eq 'completed') {
                    $scanned += [double](Get-OptionalValue $run 'dedupedata' 0); $unique += [double](Get-OptionalValue $run 'uniquedata' 0)
                    $replData += [double](Get-OptionalValue $run 'repldata' 0); $replUnique += [double](Get-OptionalValue $run 'replunique' 0)
                    $tapes += [double](Get-OptionalValue $run 'tapes' 0); $duration += [double](Get-OptionalValue $run 'dedupeduration' 0)
                }
            }
            foreach ($st in $byStatus.Keys) {
                Add-Metric 'storsafe_dedupe_runs_24h' 'Deduplication policy runs in the last 24 hours, by status.' $byStatus[$st] (New-Label $l 'policy' $policy 'status' $st)
            }
            $pl = New-Label $l 'policy' $policy
            Add-Metric 'storsafe_dedupe_24h_scanned_bytes' 'Data scanned by completed runs in the last 24 hours, in bytes.' ($scanned * 1MB) $pl
            Add-Metric 'storsafe_dedupe_24h_unique_bytes' 'Unique data written to the repository by completed runs in the last 24 hours, in bytes.' ($unique * 1MB) $pl
            if ($unique -gt 0) { Add-Metric 'storsafe_dedupe_24h_ratio' 'Deduplication ratio of completed runs in the last 24 hours (scanned / unique, N:1).' ($scanned / $unique) $pl }
            Add-Metric 'storsafe_dedupe_24h_replicated_bytes' 'Data replicated by completed runs in the last 24 hours, in bytes.' ($replData * 1MB) $pl
            Add-Metric 'storsafe_dedupe_24h_replicated_unique_bytes' 'Unique data sent to the replica by completed runs in the last 24 hours, in bytes.' ($replUnique * 1MB) $pl
            Add-Metric 'storsafe_dedupe_24h_tapes' 'Tapes processed by completed runs in the last 24 hours.' $tapes $pl
            Add-Metric 'storsafe_dedupe_24h_duration_seconds' 'Total deduplication time of completed runs in the last 24 hours.' $duration $pl

            $latest = $runs | Sort-Object { [long](Get-OptionalValue $_ 'timestamp' 0) } | Select-Object -Last 1
            if ($null -ne $latest) {
                Add-Metric 'storsafe_dedupe_run_last_timestamp_seconds' 'Start of the most recent policy run (Unix time).' (Get-OptionalValue $latest 'timestamp' $null) $pl
                Add-Metric 'storsafe_dedupe_run_last_status' 'Status of the most recent policy run (1 for the current status label).' 1 (New-Label $l 'policy' $policy 'status' (Get-CleanState (Get-OptionalValue $latest 'status' 'unknown')) 'trigger' (Get-OptionalValue $latest 'trigger' ''))
            }
            $done = $runs | Where-Object { (Get-CleanState (Get-OptionalValue $_ 'status' '')) -eq 'completed' } | Sort-Object { [long](Get-OptionalValue $_ 'timestamp' 0) } | Select-Object -Last 1
            if ($null -ne $done) {
                $s = [double](Get-OptionalValue $done 'dedupedata' 0); $u = [double](Get-OptionalValue $done 'uniquedata' 0)
                $ratio = if ($u -gt 0) { $s / $u } else { ConvertFrom-RatioText (Get-OptionalValue $done 'deduperatio' $null) }
                Add-Metric 'storsafe_dedupe_completed_run_timestamp_seconds' 'Start of the most recent completed policy run (Unix time).' (Get-OptionalValue $done 'timestamp' $null) $pl
                Add-Metric 'storsafe_dedupe_completed_run_ratio' 'Deduplication ratio of the most recent completed run (N:1).' $ratio $pl
                Add-Metric 'storsafe_dedupe_completed_run_scanned_bytes' 'Data scanned by the most recent completed run, in bytes.' ($s * 1MB) $pl
                Add-Metric 'storsafe_dedupe_completed_run_unique_bytes' 'Unique data from the most recent completed run, in bytes.' ($u * 1MB) $pl
                Add-Metric 'storsafe_dedupe_completed_run_tapes' 'Tapes in the most recent completed run.' (Get-OptionalValue $done 'tapes' $null) $pl
                Add-Metric 'storsafe_dedupe_completed_run_duration_seconds' 'Deduplication duration of the most recent completed run.' (Get-OptionalValue $done 'dedupeduration' $null) $pl
                Add-Metric 'storsafe_dedupe_completed_run_replicated_bytes' 'Data replicated by the most recent completed run, in bytes.' ([double](Get-OptionalValue $done 'repldata' 0) * 1MB) $pl
                Add-Metric 'storsafe_dedupe_completed_run_replicated_unique_bytes' 'Unique data sent to the replica by the most recent completed run, in bytes.' ([double](Get-OptionalValue $done 'replunique' 0) * 1MB) $pl
                Add-Metric 'storsafe_dedupe_completed_run_replication_ratio' 'Deduplication ratio on the replica after the most recent completed run (N:1).' (ConvertFrom-RatioText (Get-OptionalValue $done 'repldeduperatio' $null)) $pl
                Add-Metric 'storsafe_dedupe_completed_run_replication_duration_seconds' 'Replication duration of the most recent completed run.' (Get-OptionalValue $done 'replduration' $null) $pl
            }
        }
    }
    'dedupeactivity' = {
        param($c, $l, $x)
        foreach ($p in (Get-Policies $c $x)) {
            $id = Get-OptionalValue $p 'id' $null
            if ($null -eq $id) { continue }
            $policy = Get-OptionalValue $p 'name' ''
            $d = Get-ActiveStatus $c $x $id
            $scanStates = @{}; $scanTput = 0.0; $scanLeft = 0.0
            foreach ($s in @(Get-Prop $d 'scan' @())) {
                $st = Get-CleanState (Get-OptionalValue $s 'status' 'unknown')
                Add-Count $scanStates $st
                $scanTput += [double](Get-OptionalValue $s 'throughput' 0)
                $scanLeft += [Math]::Max(0, [double](Get-OptionalValue $s 'datasize' 0) - [double](Get-OptionalValue $s 'scanned' 0))
            }
            $replPhases = @{}; $replTput = 0.0; $replLeft = 0.0; $replEta = 0.0
            foreach ($t in @(Get-Prop $d 'replication' @())) {
                Add-Count $replPhases (Get-CleanState (Get-OptionalValue $t 'phase' 'unknown'))
                $replTput += [double](Get-OptionalValue $t 'throughput' 0)
                $replLeft += [Math]::Max(0, [double](Get-OptionalValue $t 'replicated' 0) - [double](Get-OptionalValue $t 'transmitted' 0))
                $replEta = [Math]::Max($replEta, [double](Get-OptionalValue $t 'remainingtime' 0))
            }
            $pl = New-Label $l 'policy' $policy
            Add-Metric 'storsafe_dedupe_active_scans_total' 'Tapes the policy is scanning or has queued for scanning.' ($scanStates.Values | Measure-Object -Sum).Sum $pl
            foreach ($st in $scanStates.Keys) { Add-Metric 'storsafe_dedupe_active_scans' 'Tapes in the policy scan list, by scan status.' $scanStates[$st] (New-Label $l 'policy' $policy 'status' $st) }
            Add-Metric 'storsafe_dedupe_active_scan_throughput_bytes_per_second' 'Combined scan throughput of the policy, in bytes/s.' ($scanTput * 1MB) $pl
            Add-Metric 'storsafe_dedupe_active_scan_remaining_bytes' 'Data still to scan for tapes in the policy scan list, in bytes.' ($scanLeft * 1MB) $pl
            Add-Metric 'storsafe_dedupe_active_replications_total' 'Tapes the policy is replicating.' ($replPhases.Values | Measure-Object -Sum).Sum $pl
            foreach ($ph in $replPhases.Keys) { Add-Metric 'storsafe_dedupe_active_replications' 'Tapes being replicated, by phase (index or unique).' $replPhases[$ph] (New-Label $l 'policy' $policy 'phase' $ph) }
            Add-Metric 'storsafe_dedupe_active_replication_throughput_bytes_per_second' 'Combined replication throughput of the policy, in bytes/s.' ($replTput * 1MB) $pl
            Add-Metric 'storsafe_dedupe_active_replication_remaining_bytes' 'Data still to replicate for tapes being replicated, in bytes.' ($replLeft * 1MB) $pl
            Add-Metric 'storsafe_dedupe_active_replication_remaining_seconds' 'Longest remaining replication time reported for a tape in the policy.' $replEta $pl
        }
    }
    'dedupequeue' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/vtl/activities/dedupequeue'
        $jobs = @(Get-DataArray $r 'jobs')
        $x.DedupeQueue = $jobs
        $byState = @{}; $undeduped = 0.0; $throughput = 0.0
        foreach ($j in $jobs) {
            $state = Get-CleanState (Get-OptionalValue $j 'state' 'unknown')
            Add-Count $byState $state
            # The guide spells this field both 'undeduped' and 'undedupe'.
            $undeduped += [double](Get-OptionalValue $j 'undedupeddatamb' (Get-OptionalValue $j 'undedupedatamb' 0))
            $throughput += [double](Get-OptionalValue $j 'throughputmbps' 0)
        }
        Add-Metric 'storsafe_dedupe_queue_jobs_total' 'Tapes in the deduplication job queue.' $jobs.Count ([ordered]@{ server = $l.server })
        foreach ($state in $byState.Keys) {
            Add-Metric 'storsafe_dedupe_queue_jobs' 'Tapes in the deduplication job queue by state.' $byState[$state] ([ordered]@{ server = $l.server; state = $state })
        }
        Add-Metric 'storsafe_dedupe_queue_undeduped_bytes' 'Data waiting to be deduplicated across queued jobs, in bytes.' ($undeduped * 1MB) ([ordered]@{ server = $l.server })
        Add-Metric 'storsafe_dedupe_queue_throughput_bytes_per_second' 'Sum of current deduplication job throughput, in bytes/s.' ($throughput * 1MB) ([ordered]@{ server = $l.server })
    }
    'dedupejobs' = {
        # One row per tape in the deduplication queue, with drive, progress and the replication leg per target.
        param($c, $l, $x)
        $jobs = if ($x.ContainsKey('DedupeQueue')) { @($x.DedupeQueue) } else { @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/vtl/activities/dedupequeue') 'jobs') }
        $drives = Get-DriveNames $c $x
        $keys = @($jobs | ForEach-Object { [string](Get-OptionalValue $_ 'id' (Get-OptionalValue $_ 'barcode' '')) })
        $firstSeen = Update-FirstSeen (Join-Path $config.StateDirectory ("jobs-dedupe-{0}.json" -f (Get-SafeFileName $l.server))) $keys

        # Scan and replication activity per policy, keyed by tape id / barcode.
        $scanById = @{}; $replByBarcode = @{}
        foreach ($p in (Get-Policies $c $x)) {
            $policyId = Get-OptionalValue $p 'id' $null
            if ($null -eq $policyId) { continue }
            try { $d = Get-ActiveStatus $c $x $policyId } catch { Write-Verbose "$($l.server): activestatus ${policyId}: $($_.Exception.Message)"; continue }
            foreach ($sc in @(Get-Prop $d 'scan' @())) { $scanById[[string](Get-OptionalValue $sc 'id' '')] = $sc }
            foreach ($t in @(Get-Prop $d 'replication' @())) { $replByBarcode[[string](Get-OptionalValue $t 'barcode' '')] = $t }
        }
        $x.ReplicationActive = $replByBarcode

        $detailCalls = 0
        foreach ($j in $jobs) {
            $id = [string](Get-OptionalValue $j 'id' ''); $barcode = [string](Get-OptionalValue $j 'barcode' '')
            $key = if ($id) { $id } else { $barcode }
            $policy = [string](Get-OptionalValue $j 'policy' '')
            $state = Get-CleanState (Get-OptionalValue $j 'state' 'unknown')
            $detail = $null
            if ($id -and $detailCalls -lt $maxJobDetails) {
                $detailCalls++
                try { $detail = Get-OptionalValue (Invoke-StorSafeApi -Connection $c -Path ('/vtl/activities/dedupequeue/{0}' -f $id)) 'data' $null }
                catch { Write-Verbose "$($l.server): dedupe job ${id}: $($_.Exception.Message)" }
            }
            $scan = if ($scanById.ContainsKey($id)) { $scanById[$id] } else { $null }
            $jl = New-Label $l 'policy' $policy 'barcode' $barcode
            Add-Metric 'storsafe_dedupe_job_info' 'Tape in the deduplication queue (value is always 1).' 1 (New-Label $l 'policy' $policy 'barcode' $barcode 'tape' (Get-OptionalValue $j 'name' '') 'state' $state `
                'trigger' (Get-OptionalValue $detail 'trigger' '') 'drive' (Resolve-DriveName $drives (Get-OptionalValue $scan 'drivesn' (Get-OptionalValue $detail 'sourcedrive' ''))) `
                'destination_drive' (Resolve-DriveName $drives (Get-OptionalValue $detail 'destinationdrive' '')) 'replicationmode' (Get-OptionalValue $detail 'replicationmode' '') 'parser' (Get-OptionalValue $scan 'parser' ''))
            Add-Metric 'storsafe_dedupe_job_progress_percent' 'Deduplication job progress.' (Get-OptionalValue $j 'progress' (Get-OptionalValue $scan 'progress' $null)) $jl
            Add-Metric 'storsafe_dedupe_job_throughput_bytes_per_second' 'Deduplication job throughput, in bytes/s.' ([double](Get-OptionalValue $j 'throughputmbps' (Get-OptionalValue $scan 'throughput' 0)) * 1MB) $jl
            Add-Metric 'storsafe_dedupe_job_undeduped_bytes' 'Data on the tape still to deduplicate, in bytes.' ([double](Get-OptionalValue $j 'undedupeddatamb' (Get-OptionalValue $j 'undedupedatamb' 0)) * 1MB) $jl
            Add-Metric 'storsafe_dedupe_job_first_seen_timestamp_seconds' 'When the collector first saw this job (Unix time); the API has no job start time.' $firstSeen[$key] $jl
            if ($null -ne $scan) {
                Add-Metric 'storsafe_dedupe_job_data_bytes' 'Data on the tape being scanned, in bytes.' ([double](Get-OptionalValue $scan 'datasize' 0) * 1MB) $jl
                Add-Metric 'storsafe_dedupe_job_scanned_bytes' 'Data scanned so far, in bytes.' ([double](Get-OptionalValue $scan 'scanned' 0) * 1MB) $jl
            }
            foreach ($t in @(Get-OptionalValue $detail 'targetservers' @())) {
                $target = [string](Get-OptionalValue $t 'name' '')
                $repl = if ($replByBarcode.ContainsKey($barcode)) { $replByBarcode[$barcode] } else { $null }
                $rl = New-Label $l 'queue' 'dedupe' 'barcode' $barcode 'target' $target
                Add-Metric 'storsafe_replication_job_info' 'Replication job (value is always 1). queue=dedupe: replication leg of a deduplication job; classic: non-deduplicated tape; unique: incoming unique-data replication on the target.' 1 `
                    (New-Label $l 'queue' 'dedupe' 'direction' 'outgoing' 'policy' $policy 'barcode' $barcode 'tape' (Get-OptionalValue $j 'name' '') 'source' $l.server 'target' $target 'targetip' (Get-OptionalValue $t 'ipaddress' '') `
                        'state' (Get-CleanState (Get-OptionalValue $t 'replicationstatus' $state)) 'phase' (Get-CleanState (Get-OptionalValue $repl 'phase' '')) 'mode' (Get-OptionalValue $detail 'replicationmode' ''))
                Add-Metric 'storsafe_replication_job_progress_percent' 'Replication job progress.' (Get-OptionalValue $t 'progress' (Get-OptionalValue $repl 'progress' $null)) $rl
                Add-Metric 'storsafe_replication_job_throughput_bytes_per_second' 'Replication job throughput, in bytes/s.' ([double](Get-OptionalValue $t 'throughputmbps' (Get-OptionalValue $repl 'throughput' 0)) * 1MB) $rl
                Add-Metric 'storsafe_replication_job_first_seen_timestamp_seconds' 'When the collector first saw this job (Unix time).' $firstSeen[$key] $rl
                if ($null -ne $repl) {
                    Add-Metric 'storsafe_replication_job_total_bytes' 'Data to replicate for the tape, in bytes.' ([double](Get-OptionalValue $repl 'replicated' 0) * 1MB) $rl
                    Add-Metric 'storsafe_replication_job_transmitted_bytes' 'Data replicated so far, in bytes.' ([double](Get-OptionalValue $repl 'transmitted' 0) * 1MB) $rl
                    Add-Metric 'storsafe_replication_job_remaining_seconds' 'Estimated time to complete the replication.' (Get-OptionalValue $repl 'remainingtime' $null) $rl
                }
            }
        }
        Add-Metric 'storsafe_dedupe_jobs_detailed' 'Dedupe jobs for which per-job detail was fetched this run (capped).' $detailCalls (New-Label $l)
    }

    # ---- Replication ----
    'replicationqueue' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/vtl/activities/replicationqueue'
        $jobs = @(Get-DataArray $r 'jobs')
        $x.ClassicQueue = $jobs
        $byState = @{}
        foreach ($j in $jobs) { Add-Count $byState (Get-CleanState (Get-OptionalValue $j 'state' 'unknown')) }
        Add-Metric 'storsafe_replication_queue_jobs_total' 'Replication jobs in the queue (queue=classic for non-deduplicated tapes, unique for deduplicated data).' $jobs.Count ([ordered]@{ server = $l.server; queue = 'classic' })
        foreach ($state in $byState.Keys) {
            Add-Metric 'storsafe_replication_queue_jobs' 'Replication jobs by state.' $byState[$state] ([ordered]@{ server = $l.server; queue = 'classic'; state = $state })
        }
    }
    'uniquereplicationqueue' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/vtl/activities/uniquereplicationqueue'
        $jobs = @(Get-DataArray $r 'jobs')
        $x.UniqueQueue = $jobs
        $byState = @{}; $oldest = 0
        foreach ($j in $jobs) {
            Add-Count $byState (Get-CleanState (Get-OptionalValue $j 'status' 'unknown'))
            $start = [long](Get-OptionalValue $j 'starttime' 0)
            if ($start -gt 0 -and ($oldest -eq 0 -or $start -lt $oldest)) { $oldest = $start }
        }
        Add-Metric 'storsafe_replication_queue_jobs_total' 'Replication jobs in the queue (queue=classic for non-deduplicated tapes, unique for deduplicated data).' $jobs.Count ([ordered]@{ server = $l.server; queue = 'unique' })
        foreach ($state in $byState.Keys) {
            Add-Metric 'storsafe_replication_queue_jobs' 'Replication jobs by state.' $byState[$state] ([ordered]@{ server = $l.server; queue = 'unique'; state = $state })
        }
        Add-Metric 'storsafe_unique_replication_oldest_job_start_timestamp_seconds' 'Start time of the oldest unique-data replication job in the queue (0 if empty).' $oldest ([ordered]@{ server = $l.server })
    }
    'replicationsetting' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/vtl/activities/replicationqueue/setting'
        $status = Get-CleanState (Get-DataField $r 'status' '')
        Add-Metric 'storsafe_replication_suspended' 'Global non-deduplicated replication is suspended (1) or normal (0).' ([int]($status -eq 'suspended')) ([ordered]@{ server = $l.server })
    }
    'replicationjobs' = {
        # Classic replication queue (outgoing, with target and retry details) and the unique-data queue
        # (incoming replicas, with a real start time). Dedupe-leg replication rows come from 'dedupejobs'.
        param($c, $l, $x)
        $classic = if ($x.ContainsKey('ClassicQueue')) { @($x.ClassicQueue) } else { @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/vtl/activities/replicationqueue') 'jobs') }
        $unique = if ($x.ContainsKey('UniqueQueue')) { @($x.UniqueQueue) } else { @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/vtl/activities/uniquereplicationqueue') 'jobs') }
        $keys = @($classic | ForEach-Object { 'classic:' + [string](Get-OptionalValue $_ 'id' (Get-OptionalValue $_ 'barcode' '')) }) +
                @($unique | ForEach-Object { 'unique:' + [string](Get-OptionalValue $_ 'sourcebarcode' '') + ':' + [string](Get-OptionalValue $_ 'replicabarcode' '') })
        $firstSeen = Update-FirstSeen (Join-Path $config.StateDirectory ("jobs-replication-{0}.json" -f (Get-SafeFileName $l.server))) $keys
        $replActive = if ($x.ContainsKey('ReplicationActive')) { $x.ReplicationActive } else { @{} }

        $detailCalls = 0
        foreach ($j in $classic) {
            $id = [string](Get-OptionalValue $j 'id' ''); $barcode = [string](Get-OptionalValue $j 'barcode' '')
            $key = 'classic:' + $(if ($id) { $id } else { $barcode })
            $state = Get-CleanState (Get-OptionalValue $j 'state' 'unknown')
            $queue = if ((Get-CleanState (Get-OptionalValue $j 'type' '')) -eq 'typededupe') { 'classic-dedupe' } else { 'classic' }
            $detail = $null
            if ($id -and $detailCalls -lt $maxJobDetails) {
                $detailCalls++
                try { $detail = Get-OptionalValue (Invoke-StorSafeApi -Connection $c -Path ('/vtl/activities/replicationqueue/{0}' -f $id)) 'data' $null }
                catch { Write-Verbose "$($l.server): replication job ${id}: $($_.Exception.Message)" }
            }
            $repl = if ($replActive.ContainsKey($barcode)) { $replActive[$barcode] } else { $null }
            $targets = @(Get-OptionalValue $detail 'targetservers' @())
            if ($targets.Count -eq 0) { $targets = @($null) }
            foreach ($t in $targets) {
                $target = [string](Get-OptionalValue $t 'name' '')
                $rl = New-Label $l 'queue' $queue 'barcode' $barcode 'target' $target
                Add-Metric 'storsafe_replication_job_info' 'Replication job (value is always 1). queue=dedupe: replication leg of a deduplication job; classic: non-deduplicated tape; unique: incoming unique-data replication on the target.' 1 `
                    (New-Label $l 'queue' $queue 'direction' 'outgoing' 'policy' '' 'barcode' $barcode 'tape' (Get-OptionalValue $j 'name' '') 'source' $l.server 'target' $target 'targetip' (Get-OptionalValue $t 'ipaddress' '') `
                        'state' $state 'phase' (Get-CleanState (Get-OptionalValue $repl 'phase' '')) 'mode' ((Get-CleanState (Get-OptionalValue $j 'mode' '')) -replace '^mode', ''))
                Add-Metric 'storsafe_replication_job_first_seen_timestamp_seconds' 'When the collector first saw this job (Unix time).' $firstSeen[$key] $rl
                Add-Metric 'storsafe_replication_job_next_retry_timestamp_seconds' 'Next retry of a waiting replication job (Unix time, 0 if none).' (Get-OptionalValue $detail 'nextretrytime' $null) $rl
                Add-Metric 'storsafe_replication_job_retries_left' 'Retries left for the replication job.' (Get-OptionalValue $detail 'leftretrycount' $null) $rl
                if ($null -ne $repl) {
                    Add-Metric 'storsafe_replication_job_progress_percent' 'Replication job progress.' (Get-OptionalValue $repl 'progress' $null) $rl
                    Add-Metric 'storsafe_replication_job_throughput_bytes_per_second' 'Replication job throughput, in bytes/s.' ([double](Get-OptionalValue $repl 'throughput' 0) * 1MB) $rl
                    Add-Metric 'storsafe_replication_job_remaining_seconds' 'Estimated time to complete the replication.' (Get-OptionalValue $repl 'remainingtime' $null) $rl
                }
            }
        }
        foreach ($u in $unique) {
            $source = [string](Get-OptionalValue $u 'sourceserver' ''); $sb = [string](Get-OptionalValue $u 'sourcebarcode' ''); $rb = [string](Get-OptionalValue $u 'replicabarcode' '')
            $key = 'unique:' + $sb + ':' + $rb
            $rl = New-Label $l 'queue' 'unique' 'barcode' $sb 'target' $l.server
            Add-Metric 'storsafe_replication_job_info' 'Replication job (value is always 1). queue=dedupe: replication leg of a deduplication job; classic: non-deduplicated tape; unique: incoming unique-data replication on the target.' 1 `
                (New-Label $l 'queue' 'unique' 'direction' 'incoming' 'policy' (Get-OptionalValue $u 'policy' '') 'barcode' $sb 'tape' (Get-OptionalValue $u 'lvittape' '') 'source' $source 'target' $l.server 'targetip' '' `
                    'state' (Get-CleanState (Get-OptionalValue $u 'status' 'unknown')) 'phase' 'unique' 'mode' '')
            Add-Metric 'storsafe_replication_job_start_timestamp_seconds' 'Start of the unique-data replication job as reported by the appliance (Unix time).' (Get-OptionalValue $u 'starttime' $null) $rl
            Add-Metric 'storsafe_replication_job_first_seen_timestamp_seconds' 'When the collector first saw this job (Unix time).' $firstSeen[$key] $rl
        }
        Add-Metric 'storsafe_replication_jobs_detailed' 'Classic replication jobs for which per-job detail was fetched this run (capped).' $detailCalls (New-Label $l)
    }

    # ---- Virtual tape library ----
    'virtuallibrary' = {
        param($c, $l, $x)
        $x.Libraries = @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/virtuallibrary') 'libraries')
        foreach ($v in $x.Libraries) {
            $vl = [ordered]@{ server = $l.server; library = Get-OptionalValue $v 'name' '' }
            Add-Metric 'storsafe_vtl_slots' 'Virtual library slots.' (Get-OptionalValue $v 'slots' $null) $vl
            Add-Metric 'storsafe_vtl_tapes' 'Virtual tapes in the library.' (Get-OptionalValue $v 'tapes' $null) $vl
            Add-Metric 'storsafe_vtl_drives' 'Virtual tape drives in the library.' (Get-OptionalValue $v 'drives' $null) $vl
            Add-Metric 'storsafe_vtl_loaded_drives' 'Virtual tape drives with a tape loaded.' (Get-OptionalValue $v 'loadeddrives' $null) $vl
        }
    }
    'virtualdrive' = {
        param($c, $l, $x)
        $drives = @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/virtualdrive') 'drives')
        Add-Metric 'storsafe_standalone_drives' 'Standalone virtual tape drives.' $drives.Count (New-Label $l)
        foreach ($d in $drives) {
            $dl = New-Label $l 'drive' (Get-OptionalValue $d 'name' '') 'barcode' (Get-Prop $d 'loadedtape.barcode' '')
            Add-Metric 'storsafe_standalone_drive_loaded' 'Standalone virtual tape drive has a tape loaded (1) or is empty (0).' ([int]((Get-CleanState (Get-OptionalValue $d 'status' '')) -eq 'loaded')) $dl
        }
    }
    'tapecaching' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/tle/tapecaching'
        $tl = [ordered]@{ server = $l.server }
        foreach ($pair in @(@('totaldiskmb', 'storsafe_virtualized_disk_size_bytes', 'Total virtualized disk space in bytes.'),
                            @('useddiskmb', 'storsafe_virtualized_disk_used_bytes', 'Used virtualized disk space in bytes.'),
                            @('unmigratedcachemb', 'storsafe_tapecaching_unmigrated_bytes', 'Tape caching data not yet migrated to physical tape, in bytes.'),
                            @('reclaimablecachemb', 'storsafe_tapecaching_reclaimable_bytes', 'Tape caching data that can be reclaimed, in bytes.'))) {
            $mb = Get-DataField $r $pair[0] $null
            if ($null -ne $mb) { Add-Metric $pair[1] $pair[2] ([double]$mb * 1MB) $tl }
        }
    }
    'tapeinventory' = {
        # Full virtual tape list (paged), aggregated. Runs every 15 minutes.
        param($c, $l, $x)
        $libNames = Get-LibraryNames $c $x
        $tapes = @(Get-StorSafePagedCollection -Connection $c -Path '/virtualtape' -CollectionName 'tapes' -Body @{ location = 'vtl' })
        $now = Get-UnixNow
        $byLoc = @{}; $sizeLoc = @{}; $usedLoc = @{}; $emptyLoc = @{}
        $byLib = @{}; $sizeLib = @{}; $usedLib = @{}; $emptyLib = @{}
        $status = @{}; $flags = @{}
        $replica = @{}; $oldest = @{}; $newest = @{}; $stale = @{}
        foreach ($t in $tapes) {
            $loc = Get-CleanState (Get-Prop $t 'location.type' 'unknown'); if (-not $loc) { $loc = 'unknown' }
            $size = [double](Get-OptionalValue $t 'sizemb' 0) * 1MB; $used = [double](Get-OptionalValue $t 'usedmb' 0) * 1MB
            Add-Count $byLoc $loc; Add-Count $sizeLoc $loc $size; Add-Count $usedLoc $loc $used
            if ($used -eq 0) { Add-Count $emptyLoc $loc }
            if ($loc -in @('lib', 'libslot', 'libdrive')) {
                $libId = [string](Get-OptionalValue $t 'parentlibvid' (Get-Prop $t 'location.libstdid' ''))
                $lib = if ($libNames.ContainsKey($libId)) { $libNames[$libId] } else { "id $libId" }
                Add-Count $byLib $lib; Add-Count $sizeLib $lib $size; Add-Count $usedLib $lib $used
                if ($used -eq 0) { Add-Count $emptyLib $lib }
            }
            foreach ($field in @('devicestatus', 'dedupestatus', 'replstatus', 'vitstatus', 'encryptionstatus')) {
                $v = Get-CleanState (Get-OptionalValue $t $field ''); if (-not $v) { $v = 'none' }
                Add-Count $status "$field|$v"
            }
            foreach ($flag in @('worm', 'writeprotection', 'tapecaching', 'unmigratedcaching', 'directlink', 'migrate', 'isstub', 'replicationenabled')) {
                if ((ConvertTo-Flag (Get-OptionalValue $t $flag $false)) -eq 1) { Add-Count $flags $flag }
            }
            if ($loc -eq 'replica') {
                $src = [string](Get-OptionalValue $t 'source' 'unknown')
                Add-Count $replica $src
                $ts = [long](Get-OptionalValue $t 'replicated' 0)
                foreach ($age in @(@('24h', 86400), @('48h', 172800), @('7d', 604800))) {
                    if (-not $stale.ContainsKey("$src|$($age[0])")) { $stale["$src|$($age[0])"] = 0 }
                    if ($ts -gt 0 -and ($now - $ts) -gt $age[1]) { $stale["$src|$($age[0])"]++ }
                }
                if ($ts -le 0) { Add-Count $stale "$src|never" }
                elseif (-not $oldest.ContainsKey($src) -or $ts -lt $oldest[$src]) { $oldest[$src] = $ts }
                if ($ts -gt 0 -and (-not $newest.ContainsKey($src) -or $ts -gt $newest[$src])) { $newest[$src] = $ts }
            }
        }
        Add-Metric 'storsafe_tapes_total' 'Virtual tapes on the appliance (all locations).' $tapes.Count (New-Label $l)
        foreach ($k in $byLoc.Keys) {
            $ll = New-Label $l 'location' $k
            Add-Metric 'storsafe_tapes' 'Virtual tapes by location (libslot, libdrive, vault, replica, ...).' $byLoc[$k] $ll
            Add-Metric 'storsafe_tapes_size_bytes' 'Allocated size of virtual tapes by location, in bytes.' $sizeLoc[$k] $ll
            Add-Metric 'storsafe_tapes_used_bytes' 'Used size of virtual tapes by location, in bytes.' $usedLoc[$k] $ll
            Add-Metric 'storsafe_tapes_empty' 'Virtual tapes with no data written, by location.' $(if ($emptyLoc.ContainsKey($k)) { $emptyLoc[$k] } else { 0 }) $ll
        }
        foreach ($k in $byLib.Keys) {
            $ll = New-Label $l 'library' $k
            Add-Metric 'storsafe_vtl_tape_size_bytes' 'Allocated size of the virtual tapes in the library, in bytes.' $sizeLib[$k] $ll
            Add-Metric 'storsafe_vtl_tape_used_bytes' 'Used size of the virtual tapes in the library, in bytes.' $usedLib[$k] $ll
            Add-Metric 'storsafe_vtl_tapes_empty' 'Virtual tapes in the library with no data written (scratch).' $(if ($emptyLib.ContainsKey($k)) { $emptyLib[$k] } else { 0 }) $ll
        }
        foreach ($k in $status.Keys) {
            $parts = $k.Split('|')
            Add-Metric 'storsafe_tapes_by_status' 'Virtual tapes by status field (devicestatus, dedupestatus, replstatus, vitstatus, encryptionstatus) and value.' $status[$k] (New-Label $l 'field' $parts[0] 'status' $parts[1])
        }
        foreach ($flag in @('worm', 'writeprotection', 'tapecaching', 'unmigratedcaching', 'directlink', 'migrate', 'isstub', 'replicationenabled')) {
            Add-Metric 'storsafe_tapes_with_property' 'Virtual tapes with the property set (worm, writeprotection, replicationenabled, ...).' $(if ($flags.ContainsKey($flag)) { $flags[$flag] } else { 0 }) (New-Label $l 'property' $flag)
        }
        foreach ($src in $replica.Keys) {
            $sl = New-Label $l 'source' $src
            Add-Metric 'storsafe_replica_tapes' 'Replica tapes held on this appliance, by source server.' $replica[$src] $sl
            if ($oldest.ContainsKey($src)) { Add-Metric 'storsafe_replica_oldest_replicated_timestamp_seconds' 'Oldest last-replication time among replica tapes from the source (Unix time).' $oldest[$src] $sl }
            if ($newest.ContainsKey($src)) { Add-Metric 'storsafe_replica_newest_replicated_timestamp_seconds' 'Newest last-replication time among replica tapes from the source (Unix time).' $newest[$src] $sl }
        }
        foreach ($k in $stale.Keys) {
            $parts = $k.Split('|')
            Add-Metric 'storsafe_replica_tapes_not_replicated_within' 'Replica tapes whose last replication is older than the age (age=never: never replicated).' $stale[$k] (New-Label $l 'source' $parts[0] 'age' $parts[1])
        }
    }
    'tapecachingreclaim' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/tle/reclaim/tapes'
        $d = Get-OptionalValue $r 'data' $null
        $count = @(Get-Prop $d 'vault' @()).Count
        foreach ($lib in @(Get-Prop $d 'libs' @())) { $count += @(Get-Prop $lib 'tapes' @()).Count }
        Add-Metric 'storsafe_tapecaching_reclaim_eligible_tapes' 'Migrated tapes whose cached disk space can be reclaimed.' $count (New-Label $l)
    }

    # ---- Physical tape and import/export ----
    'physicallibrary' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/physicallibrary/status'
        $d = Get-OptionalValue $r 'data' $null
        $libraries = @(Get-Prop $d 'ptlstat' @()) + @(Get-Prop $d 'acslsptlstat' @())
        Add-Metric 'storsafe_physical_libraries' 'Physical tape libraries attached to the appliance.' $libraries.Count (New-Label $l)
        foreach ($lib in $libraries) {
            $id = Get-OptionalValue $lib 'id' ''
            $name = "id $id"; $driveNames = @{}
            try {
                $detail = Invoke-StorSafeApi -Connection $c -Path ('/physicallibrary/{0}' -f $id)
                $name = [string](Get-DataField $detail 'name' $name)
                foreach ($dr in @(Get-Prop (Get-OptionalValue $detail 'data' $null) 'standardstat.ptdstat' @())) { $driveNames[[string](Get-OptionalValue $dr 'id' '')] = [string](Get-OptionalValue $dr 'name' '') }
            } catch { Write-Verbose "$($l.server): physical library ${id} details: $($_.Exception.Message)" }
            $ll = New-Label $l 'library' $name 'serialno' (Get-OptionalValue $lib 'serialno' '')
            Add-Metric 'storsafe_physical_library_status' 'Physical tape library status (1 for the current status label).' 1 (New-Label $l 'library' $name 'status' (Get-CleanState (Get-OptionalValue $lib 'status' 'unknown')))
            Add-Metric 'storsafe_physical_library_disabled' 'Physical tape library disabled for maintenance.' (ConvertTo-Flag (Get-OptionalValue $lib 'disabled' $false)) $ll
            Add-Metric 'storsafe_physical_library_tapes' 'Tapes in the physical library.' (Get-OptionalValue $lib 'tapes' $null) $ll
            Add-Metric 'storsafe_physical_library_loaded_tapes' 'Tapes loaded in physical library drives.' (Get-OptionalValue $lib 'loadedtapes' $null) $ll
            Add-Metric 'storsafe_physical_library_slots' 'Slots in the physical library.' (Get-OptionalValue $lib 'slots' $null) $ll
            foreach ($dr in @(Get-OptionalValue $lib 'ptdstat' @())) {
                $driveId = [string](Get-OptionalValue $dr 'id' '')
                $driveName = if ($driveNames.ContainsKey($driveId) -and $driveNames[$driveId]) { $driveNames[$driveId] } else { "id $driveId" }
                Add-Metric 'storsafe_physical_drive_status' 'Physical tape drive status (1 for the current status label).' 1 (New-Label $l 'library' $name 'drive' $driveName 'status' (Get-CleanState (Get-OptionalValue $dr 'status' 'unknown')) 'barcode' (Get-OptionalValue $dr 'barcode' ''))
                Add-Metric 'storsafe_physical_drive_disabled' 'Physical tape drive disabled.' (ConvertTo-Flag (Get-OptionalValue $dr 'disabled' $false)) (New-Label $l 'library' $name 'drive' $driveName)
            }
        }
        foreach ($dr in @(Get-Prop $d 'saptdstat' @())) {
            Add-Metric 'storsafe_physical_drive_status' 'Physical tape drive status (1 for the current status label).' 1 (New-Label $l 'library' 'standalone' 'drive' ("id {0}" -f (Get-OptionalValue $dr 'id' '')) 'status' (Get-CleanState (Get-OptionalValue $dr 'status' 'unknown')) 'barcode' (Get-OptionalValue $dr 'barcode' ''))
        }
    }
    'iejob' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/activity/iejob'
        $jobs = @(Get-DataArray $r 'jobs')
        $byStatus = @{}; $byType = @{}; $transferred = 0.0; $oldest = 0
        foreach ($j in $jobs) {
            $st = Get-CleanState (Get-OptionalValue $j 'status' 'unknown')
            Add-Count $byStatus $st
            Add-Count $byType ("{0}|{1}" -f (Get-OptionalValue $j 'jobtype' 'unknown'), $st)
            if ($st -eq 'running') {
                $transferred += [double](Get-OptionalValue $j 'transferedmb' (Get-OptionalValue $j 'transferdmb' 0))
                $start = [long](Get-OptionalValue $j 'starttime' 0)
                if ($start -gt 0 -and ($oldest -eq 0 -or $start -lt $oldest)) { $oldest = $start }
            }
        }
        Add-Metric 'storsafe_iejob_total' 'Tape import/export and object storage jobs in the queue.' $jobs.Count (New-Label $l)
        foreach ($k in $byStatus.Keys) { Add-Metric 'storsafe_iejob_jobs' 'Import/export jobs by status.' $byStatus[$k] (New-Label $l 'status' $k) }
        foreach ($k in $byType.Keys) { $p = $k.Split('|'); Add-Metric 'storsafe_iejob_jobs_by_type' 'Import/export jobs by job type and status.' $byType[$k] (New-Label $l 'jobtype' $p[0] 'status' $p[1]) }
        Add-Metric 'storsafe_iejob_running_transferred_bytes' 'Data transferred so far by running import/export jobs, in bytes.' ($transferred * 1MB) (New-Label $l)
        Add-Metric 'storsafe_iejob_oldest_running_start_timestamp_seconds' 'Start of the oldest running import/export job (0 if none).' $oldest (New-Label $l)
    }

    # ---- Event log (every run) ----
    'eventlog' = {
        param($c, $l, $x)
        Invoke-EventLogCheck $c $l $x
    }

    # ---- Configuration and inventory (cached, see $checkIntervalMinutes) ----
    'serverinfo' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/server/properties/info'
        $d = Get-OptionalValue $r 'data' $null
        $hostName = ''
        try { $hostName = [string](Get-DataField (Invoke-StorSafeApi -Connection $c -Path '/server/properties/host') 'hostname' '') } catch { Write-Verbose $_.Exception.Message }
        $kernel = [string](Get-Prop $d 'kernelversion' ''); if ($kernel.Length -gt 80) { $kernel = $kernel.Substring(0, 80) }
        Add-Metric 'storsafe_server_info' 'Appliance platform details (value is always 1).' 1 (New-Label $l 'hostname' $hostName 'role' (Get-Prop $d 'role' '') 'make' (Get-Prop $d 'make' '') 'model' (Get-Prop $d 'model' '') 'osversion' (Get-Prop $d 'osversion' '') 'kernel' $kernel 'virtual' (Get-Prop $d 'isvirtualappliance' '') 'cloud' (Get-Prop $d 'cloud' '') 'location' (Get-Prop $d 'location' '') 'description' (Get-Prop $d 'description' ''))
        Add-Metric 'storsafe_server_memory_bytes' 'Appliance memory in bytes.' (Get-Prop $d 'memory' $null) (New-Label $l)
        Add-Metric 'storsafe_server_swap_bytes' 'Appliance swap size in bytes.' (Get-Prop $d 'swap' $null) (New-Label $l)
        Add-Metric 'storsafe_server_cpus' 'Appliance CPU count (logical processors listed by the API).' @(Get-Prop $d 'processor' @()).Count (New-Label $l)
        Add-Metric 'storsafe_server_storsight_running' 'FalconStor StorSight (FMS) installed and running (1), installed and stopped (0).' $(if ((ConvertTo-Flag (Get-Prop $d 'fmsinstalled' $false)) -eq 1) { ConvertTo-Flag (Get-Prop $d 'fmsrunning' $false) } else { $null }) (New-Label $l)
    }
    'patches' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/patches'
        $list = @(Get-DataField $r 'patches' @())
        Add-Metric 'storsafe_patches_installed' 'Patches applied to the appliance.' $list.Count (New-Label $l)
        foreach ($p in $list) {
            $desc = (([string](Get-OptionalValue $p 'desc' '')) -split "`n")[0].Trim(); if ($desc.Length -gt 120) { $desc = $desc.Substring(0, 120) }
            Add-Metric 'storsafe_patch_info' 'Applied patch (value is always 1).' 1 (New-Label $l 'patch' (Get-OptionalValue $p 'name' '') 'description' $desc)
        }
    }
    'serveroptions' = {
        param($c, $l, $x)
        $d = Get-OptionalValue (Invoke-StorSafeApi -Connection $c -Path '/server/options') 'data' $null
        foreach ($p in @($d.PSObject.Properties)) {
            $flag = ConvertTo-Flag $p.Value
            if ($null -ne $flag) { Add-Metric 'storsafe_server_option_enabled' 'Server-level option enabled (configrepo, failover, fctarget, iscsitarget, emailalerts, ndmp, ost, nas, ...).' $flag (New-Label $l 'option' $p.Name) }
        }
    }
    'encryption' = {
        param($c, $l, $x)
        $d = Get-OptionalValue (Invoke-StorSafeApi -Connection $c -Path '/encryption') 'data' $null
        foreach ($p in @($d.PSObject.Properties)) {
            $flag = ConvertTo-Flag $p.Value
            if ($null -ne $flag) { Add-Metric 'storsafe_encryption_option' 'Encryption support and state (supportencrypt, tapeencryptenabled, dedupencryptenabled, encryptionactive).' $flag (New-Label $l 'option' $p.Name) }
        }
    }
    'failoverconfig' = {
        param($c, $l, $x)
        $d = Get-OptionalValue (Invoke-StorSafeApi -Connection $c -Path '/server/failover') 'data' $null
        Add-Metric 'storsafe_failover_config_info' 'Failover configuration (value is always 1).' 1 (New-Label $l 'type' (Get-Prop $d 'type' 'none') 'partner' (Get-Prop $d 'partnername' '') 'partnerip' (Get-Prop $d 'partnerip' '') 'powercontrol' (Get-Prop $d 'powercontrol.type' ''))
        Add-Metric 'storsafe_failover_selfcheck_interval_seconds' 'Failover self-health check interval (-1 when not applicable).' (Get-Prop $d 'selfcheckinterval' $null) (New-Label $l)
        Add-Metric 'storsafe_failover_heartbeat_interval_seconds' 'Failover partner heartbeat interval (-1 when not applicable).' (Get-Prop $d 'heartbeatinterval' $null) (New-Label $l)
        Add-Metric 'storsafe_failover_autorecovery_enabled' 'Automatic failback enabled.' (ConvertTo-Flag (Get-Prop $d 'autorecovery.enabled' $null)) (New-Label $l)
    }
    'network' = {
        param($c, $l, $x)
        $d = Get-OptionalValue (Invoke-StorSafeApi -Connection $c -Path '/server/properties/network') 'data' $null
        foreach ($nic in @(Get-Prop $d 'nics' @())) {
            $name = Get-OptionalValue $nic 'name' ''
            # The guide spells the address list both 'ifcfg' and 'ifgcfg'.
            $addresses = @(Get-OptionalValue $nic 'ifcfg' (Get-OptionalValue $nic 'ifgcfg' @()))
            $ips = ($addresses | ForEach-Object { Get-OptionalValue $_ 'ipaddress' '' } | Where-Object { $_ }) -join ' '
            Add-Metric 'storsafe_nic_speed_mbps' 'Network interface link speed in Mb/s.' (Get-OptionalValue $nic 'speed' $null) (New-Label $l 'nic' $name 'ipaddress' $ips)
            Add-Metric 'storsafe_nic_mtu' 'Network interface MTU.' (Get-OptionalValue $nic 'mtu' $null) (New-Label $l 'nic' $name)
            Add-Metric 'storsafe_nic_dhcp' 'Network interface uses DHCP.' (ConvertTo-Flag (Get-OptionalValue $nic 'dhcp' $null)) (New-Label $l 'nic' $name)
        }
        Add-Metric 'storsafe_network_info' 'Network settings (value is always 1).' 1 (New-Label $l 'domain' (Get-Prop $d 'domain' '') 'gateway' (Get-Prop $d 'gateway' '') 'dns' ((@(Get-Prop $d 'dns' @())) -join ' '))
        foreach ($svc in @('ssh', 'sftp')) { Add-Metric 'storsafe_network_service_enabled' 'SSH / SFTP access enabled on the appliance.' (ConvertTo-Flag (Get-Prop $d $svc $null)) (New-Label $l 'service' $svc) }
    }
    'bonding' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/network/bonding'
        foreach ($g in @(Get-DataField $r 'groups' @())) {
            $gl = New-Label $l 'group' (Get-OptionalValue $g 'group' '') 'mode' (Get-OptionalValue $g 'mode' '') 'ipaddress' (Get-OptionalValue $g 'ipaddress' '')
            Add-Metric 'storsafe_bond_members' 'Network interfaces in the bonded group.' @(Get-OptionalValue $g 'nics' @()).Count $gl
        }
    }
    'ntp' = {
        param($c, $l, $x)
        $servers = @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/server/properties/ntp') 'ntp')
        Add-Metric 'storsafe_ntp_servers' 'NTP servers configured on the appliance.' $servers.Count (New-Label $l 'servers' ($servers -join ' '))
    }
    'dedupereplication' = {
        param($c, $l, $x)
        $d = Get-OptionalValue (Invoke-StorSafeApi -Connection $c -Path '/dedupereplication') 'data' $null
        foreach ($dir in @(@('targets', 'outgoing'), @('sources', 'incoming'))) {
            $list = @(Get-Prop $d $dir[0] @())
            Add-Metric 'storsafe_dedupe_replication_partners' 'Deduplication replication partners (outgoing = targets, incoming = sources).' $list.Count (New-Label $l 'direction' $dir[1])
            foreach ($p in $list) {
                $ip = Get-OptionalValue $p 'ipaddress' ((@(Get-Prop $p 'tcpoptions.servers' @()) | ForEach-Object { Get-OptionalValue $_ 'ipaddress' '' }) -join ' ')
                $pl = New-Label $l 'direction' $dir[1] 'partner' (Get-OptionalValue $p 'name' '') 'ipaddress' $ip 'protocol' (Get-CleanState (Get-OptionalValue $p 'protocol' '')) 'encryption' (Get-Prop $p 'tcpoptions.encryption' '')
                Add-Metric 'storsafe_dedupe_replication_partner_info' 'Deduplication replication partner (value is always 1).' 1 $pl
                Add-Metric 'storsafe_dedupe_replication_connections' 'TCP connections configured for incoming replication from the partner.' (Get-Prop $p 'tcpoptions.connections' $null) (New-Label $l 'direction' $dir[1] 'partner' (Get-OptionalValue $p 'name' ''))
                Add-Metric 'storsafe_dedupe_replication_timeout_seconds' 'Replication connection timeout for the partner.' (Get-Prop $p 'tcpoptions.timeout' $null) (New-Label $l 'direction' $dir[1] 'partner' (Get-OptionalValue $p 'name' ''))
            }
        }
    }
    'lvitsource' = {
        param($c, $l, $x)
        $list = @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/virtualtape/lvitsource') 'sources')
        foreach ($s in $list) { Add-Metric 'storsafe_replica_source_info' 'Server that replicates deduplicated tapes to this appliance (value is always 1).' 1 (New-Label $l 'source' (Get-OptionalValue $s 'name' '') 'ipaddress' (Get-OptionalValue $s 'ipaddress' '')) }
    }
    'reclamationpolicy' = {
        param($c, $l, $x)
        $d = Get-OptionalValue (Invoke-StorSafeApi -Connection $c -Path '/deduplication/reclamation') 'data' $null
        Add-Metric 'storsafe_reclamation_policy_enabled' 'Space reclamation trigger enabled (usage = disk-usage based, schedule = scheduled).' (ConvertTo-Flag (Get-Prop $d 'usage.enabled' $null)) (New-Label $l 'trigger' 'usage')
        Add-Metric 'storsafe_reclamation_policy_enabled' 'Space reclamation trigger enabled (usage = disk-usage based, schedule = scheduled).' (ConvertTo-Flag (Get-Prop $d 'schedule.enabled' $null)) (New-Label $l 'trigger' 'schedule')
        Add-Metric 'storsafe_reclamation_usage_check_interval_seconds' 'Disk-usage reclamation check interval.' $(if ($null -ne (Get-Prop $d 'usage.interval' $null)) { [double](Get-Prop $d 'usage.interval' 0) * 60 }) (New-Label $l)
        $days = (@(Get-Prop $d 'schedule.weekdays' @()) | ForEach-Object { @('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat')[[int]$_] }) -join ','
        Add-Metric 'storsafe_reclamation_schedule_info' 'Scheduled reclamation days and start time (value is always 1).' 1 (New-Label $l 'weekdays' $days 'starttime' (Get-Prop $d 'schedule.starttime' ''))
    }
    'dedupecleanup' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/deduplication/cleanup'
        Add-Metric 'storsafe_dedupe_cleanup_needed' 'Unused deduplication repositories need cleaning up (1) or not (0).' (ConvertTo-Flag (Get-DataField $r 'cleandisk' $null)) (New-Label $l)
    }
    'tleproperties' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/tle/properties'
        Add-Metric 'storsafe_vtl_compression_enabled' 'VTL software compression enabled.' (ConvertTo-Flag (Get-DataField $r 'compression' $null)) (New-Label $l)
        Add-Metric 'storsafe_vtl_retain_tape_enabled' 'VTL retain-tape property enabled.' (ConvertTo-Flag (Get-DataField $r 'retaintape' $null)) (New-Label $l)
        Add-Metric 'storsafe_tapecaching_reclamation_threshold_percent' 'Disk usage that triggers tape caching space reclamation.' (Get-DataField $r 'reclamationthreshold' $null) (New-Label $l)
        Add-Metric 'storsafe_tapecaching_migration_threshold_percent' 'Disk usage that triggers migration to physical tape.' (Get-DataField $r 'migrationthreshold' $null) (New-Label $l)
    }
    'iejobproperties' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/activity/iejob/properties'
        Add-Metric 'storsafe_iejob_retry_enabled' 'Import/export job retry enabled.' (ConvertTo-Flag (Get-DataField $r 'retry' $null)) (New-Label $l)
        Add-Metric 'storsafe_iejob_retry_count' 'Import/export job retries.' (Get-DataField $r 'retrycount' $null) (New-Label $l)
        Add-Metric 'storsafe_iejob_retry_interval_seconds' 'Wait between import/export job retries.' $(if ($null -ne (Get-DataField $r 'retryinterval' $null)) { [double](Get-DataField $r 'retryinterval' 0) * 60 }) (New-Label $l)
    }
    'activitydatabase' = {
        param($c, $l, $x)
        $r = Invoke-StorSafeApi -Connection $c -Path '/server/activitydatabase'
        Add-Metric 'storsafe_activity_db_max_bytes' 'Maximum size of the activity database file, in bytes.' $(if ($null -ne (Get-DataField $r 'maxsize' $null)) { [double](Get-DataField $r 'maxsize' 0) * 1MB }) (New-Label $l)
        Add-Metric 'storsafe_activity_db_max_days' 'Days of activity kept in the activity database.' (Get-DataField $r 'maxdays' $null) (New-Label $l)
    }
    'clients' = {
        param($c, $l, $x)
        $clients = @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/client') 'clients')
        Add-Metric 'storsafe_clients' 'SAN clients defined on the appliance, by protocol.' @($clients | Where-Object { (ConvertTo-Flag (Get-OptionalValue $_ 'fcenabled' $false)) -eq 1 }).Count (New-Label $l 'protocol' 'fc')
        Add-Metric 'storsafe_clients' 'SAN clients defined on the appliance, by protocol.' @($clients | Where-Object { (ConvertTo-Flag (Get-OptionalValue $_ 'iscsienabled' $false)) -eq 1 }).Count (New-Label $l 'protocol' 'iscsi')
        Add-Metric 'storsafe_clients_total' 'SAN clients defined on the appliance.' $clients.Count (New-Label $l)
    }
    'fcinitiators' = {
        param($c, $l, $x)
        $list = @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/physicalresource/physicaladapter/fcclientinitiators') 'initiators')
        $by = @{}
        foreach ($i in $list) { $a = Get-CleanState (Get-OptionalValue $i 'assigned' ''); if (-not $a) { $a = 'unassigned' }; Add-Count $by $a }
        foreach ($k in @('client', 'adapter', 'unassigned')) { Add-Metric 'storsafe_fc_initiators' 'FC initiator WWPNs seen by the appliance, by assignment (client, adapter, unassigned).' $(if ($by.ContainsKey($k)) { $by[$k] } else { 0 }) (New-Label $l 'assigned' $k) }
    }
    'iscsi' = {
        param($c, $l, $x)
        $targets = @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/client/iscsitarget') 'iscsitargets')
        Add-Metric 'storsafe_iscsi_targets' 'iSCSI targets defined on the appliance.' $targets.Count (New-Label $l)
        $inits = @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/client/iscsiclientinitiators') 'initiators')
        Add-Metric 'storsafe_iscsi_initiators' 'iSCSI initiators seen by the appliance, by assignment.' @($inits | Where-Object { (ConvertTo-Flag (Get-OptionalValue $_ 'assigned' $false)) -eq 1 }).Count (New-Label $l 'assigned' 'true')
        Add-Metric 'storsafe_iscsi_initiators' 'iSCSI initiators seen by the appliance, by assignment.' @($inits | Where-Object { (ConvertTo-Flag (Get-OptionalValue $_ 'assigned' $false)) -ne 1 }).Count (New-Label $l 'assigned' 'false')
    }
    'hostedbackup' = {
        param($c, $l, $x)
        $devices = @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/client/hostedbackup') 'devices')
        $by = @{}
        foreach ($d in $devices) { Add-Count $by (Get-CleanState (Get-OptionalValue $d 'type' 'unknown')) }
        foreach ($k in $by.Keys) { Add-Metric 'storsafe_hosted_backup_devices' 'Devices assigned for hosted backup, by type (lib, drive, sadrive, sirdrive).' $by[$k] (New-Label $l 'type' $k) }
        Add-Metric 'storsafe_hosted_backup_devices_total' 'Devices assigned for hosted backup.' $devices.Count (New-Label $l)
    }
    'users' = {
        param($c, $l, $x)
        $users = @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/user/account') 'users')
        $names = @{ A = 'administrator'; S = 'standard'; R = 'readonly'; I = 'iscsi' }
        $by = @{}
        foreach ($u in $users) { $t = [string](Get-OptionalValue $u 'type' '?'); Add-Count $by $(if ($names.ContainsKey($t)) { $names[$t] } else { $t }) }
        foreach ($k in $by.Keys) { Add-Metric 'storsafe_user_accounts' 'Appliance user accounts by type (names are not exported).' $by[$k] (New-Label $l 'type' $k) }
    }
    'objectstorage' = {
        param($c, $l, $x)
        $accounts = @(Get-DataArray (Invoke-StorSafeApi -Connection $c -Path '/objectstorage') 'accounts')
        $by = @{}
        foreach ($a in $accounts) { Add-Count $by (Get-CleanState (Get-OptionalValue $a 'provider' 'unknown')) }
        Add-Metric 'storsafe_objectstorage_accounts_total' 'Object storage accounts configured.' $accounts.Count (New-Label $l)
        foreach ($k in $by.Keys) { Add-Metric 'storsafe_objectstorage_accounts' 'Object storage accounts by provider.' $by[$k] (New-Label $l 'provider' $k) }
    }
    'syslogalert' = {
        param($c, $l, $x)
        $d = Get-OptionalValue (Invoke-StorSafeApi -Connection $c -Path '/server/syslogalert') 'data' $null
        Add-Metric 'storsafe_syslog_alert_enabled' 'System log pattern monitoring (email alerts) enabled.' (ConvertTo-Flag (Get-Prop $d 'enabled' $null)) (New-Label $l)
        Add-Metric 'storsafe_syslog_alert_patterns' 'System log alert patterns configured.' @(Get-Prop $d 'incidents' @()).Count (New-Label $l)
        Add-Metric 'storsafe_syslog_alert_check_interval_seconds' 'System log check interval.' $(if ($null -ne (Get-Prop $d 'frequency' $null)) { [double](Get-Prop $d 'frequency' 0) * 60 }) (New-Label $l)
    }
    'autosave' = {
        param($c, $l, $x)
        $d = Get-OptionalValue (Invoke-StorSafeApi -Connection $c -Path '/server/properties/autosavetoftp') 'data' $null
        Add-Metric 'storsafe_config_autosave_enabled' 'Automatic save of the appliance configuration to FTP enabled.' (ConvertTo-Flag (Get-Prop $d 'enabled' $null)) (New-Label $l 'interval' (Get-Prop $d 'interval' '') 'ftpserver' (Get-Prop $d 'ftpserver' ''))
        Add-Metric 'storsafe_config_autosave_copies' 'Configuration copies kept on FTP.' (Get-Prop $d 'copies' $null) (New-Label $l)
    }
}

# Minutes between runs of the slower checks; anything not listed runs every time.
$checkIntervalMinutes = @{
    tapeinventory = 15; tapecachingreclaim = 15
    serverinfo = 60; patches = 60; serveroptions = 60; encryption = 60; failoverconfig = 60; network = 60; bonding = 60; ntp = 60
    dedupereplication = 60; lvitsource = 60; reclamationpolicy = 60; dedupecleanup = 60; tleproperties = 60; iejobproperties = 60
    activitydatabase = 60; clients = 60; fcinitiators = 60; iscsi = 60; hostedbackup = 60; users = 60; objectstorage = 60
    syslogalert = 60; autosave = 60
}
$disabledChecks = @($config.DisabledChecks | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
if (-not $config.CollectEventLog) { $disabledChecks += 'eventlog' }
foreach ($name in $disabledChecks) { if (-not $checks.Contains($name)) { Write-Warning "DisabledChecks: unknown check '$name' (known: $($checks.Keys -join ', '))" } }

# ---------------------------------------------------------------------------
# Write helper: UTF-8 without BOM, LF line endings, atomic rename.
# ---------------------------------------------------------------------------
function Write-MetricsFile {
    param([string]$Path)
    $lines = [System.Collections.Generic.List[string]]::new()
    $seriesSeen = @{}
    foreach ($name in $families.Keys) {
        $f = $families[$name]
        $lines.Add("# HELP $name $($f.Help)")
        $lines.Add("# TYPE $name $($f.Type)")
        foreach ($sample in $f.Samples) {
            # windows_exporter rejects the whole file if a series appears twice, so keep the first of any duplicate.
            $series = $sample.Substring(0, $sample.LastIndexOf(' '))
            if ($seriesSeen.ContainsKey($series)) { continue }
            $seriesSeen[$series] = $true
            $lines.Add($sample)
        }
    }
    $temp = "$Path.$PID.tmp"
    [System.IO.File]::WriteAllText($temp, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $Path -Force
    return $seriesSeen.Count
}

function Get-ServerMetricsFileName { param([string]$Name) return ("storsafe-{0}.prom" -f (Get-SafeFileName $Name)) }

# ---------------------------------------------------------------------------
# Parallel mode: one child process per appliance, each writing its own .prom file.
# windows_exporter reads every *.prom in the directory, so the files add up to one scrape.
# ---------------------------------------------------------------------------
$isChild = [bool]$env:STORSAFE_COLLECTOR_CHILD
if ($MaxParallel -le 0) { $MaxParallel = if ($selectedServers.Count -le 2) { 1 } else { [Math]::Min(8, [Math]::Ceiling($selectedServers.Count / 4.0)) } }
if ($Credential) { $MaxParallel = 1 }   # an explicit credential cannot be handed to child processes

if ($MaxParallel -gt 1 -and $selectedServers.Count -gt 1 -and -not $isChild) {
    $exe = (Get-Process -Id $PID).Path
    $commonArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
        '-ConfigPath', $ConfigPath, '-NonInteractive', '-TextfileDirectory', $TextfileDirectory, '-MaxParallel', '1')
    if ($Scheme) { $commonArgs += @('-Scheme', $Scheme) }
    if ($Port -ge 0) { $commonArgs += @('-Port', [string]$Port) }
    if ($SkipCertificateCheck) { $commonArgs += '-SkipCertificateCheck' }
    if ($Refresh) { $commonArgs += '-Refresh' }
    $env:STORSAFE_COLLECTOR_CHILD = '1'

    $started = Get-UnixNow
    $pending = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $selectedServers) { $pending.Enqueue($s) }
    $running = @{}; $exitCodes = [ordered]@{}
    try {
        while ($pending.Count -gt 0 -or $running.Count -gt 0) {
            while ($pending.Count -gt 0 -and $running.Count -lt $MaxParallel) {
                $s = $pending.Dequeue()
                $argList = ($commonArgs + @('-Server', $s.Name, '-FileName', (Get-ServerMetricsFileName $s.Name))) |
                    ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
                $running[$s.Name] = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -PassThru
            }
            Start-Sleep -Milliseconds 500
            foreach ($name in @($running.Keys)) {
                if ($running[$name].HasExited) { $exitCodes[$name] = $running[$name].ExitCode; $running.Remove($name) }
            }
        }
    } finally {
        foreach ($proc in $running.Values) { try { $proc.Kill() } catch { } }
    }

    # Summary file: the collector's own metrics, plus per-appliance exit codes. Stale per-server files are removed.
    foreach ($name in $exitCodes.Keys) {
        Add-Metric 'storsafe_collector_server_exit_code' 'Exit code of the per-appliance collector process (0 OK, 2 a check failed, 3 config error).' $exitCodes[$name] ([ordered]@{ server = $name })
    }
    Add-Metric 'storsafe_collector_parallel_processes' 'Appliance collector processes run at a time.' $MaxParallel @{}
    Add-Metric 'storsafe_collector_last_run_timestamp_seconds' 'Unix time the collector last completed.' (Get-UnixNow) @{}
    Add-Metric 'storsafe_collector_run_duration_seconds' 'Wall-clock time of the whole collector run.' ((Get-UnixNow) - $started) @{}
    Add-Metric 'storsafe_collector_info' 'Installed StorSafe monitoring package version (value is always 1).' 1 ([ordered]@{ version = $script:PackageVersion })
    $keep = @($selectedServers | ForEach-Object { Get-ServerMetricsFileName $_.Name }) + @($FileName)
    Get-ChildItem -LiteralPath $TextfileDirectory -Filter 'storsafe-*.prom' -File | Where-Object { $keep -notcontains $_.Name } | Remove-Item -Force -ErrorAction SilentlyContinue
    $count = Write-MetricsFile (Join-Path $TextfileDirectory $FileName)
    $failed = @($exitCodes.Values | Where-Object { $_ -ne 0 }).Count
    Write-Host ("Ran {0} appliance collector(s), {1} at a time, in {2}s; {3} failed. Summary: {4}" -f $exitCodes.Count, $MaxParallel, ((Get-UnixNow) - $started), $failed, (Join-Path $TextfileDirectory $FileName))
    if ($failed -gt 0) { exit 2 }
    exit 0
}

# ---------------------------------------------------------------------------
# Collect
# ---------------------------------------------------------------------------
$anyFailure = $false
foreach ($s in $selectedServers) {
    $labels = [ordered]@{ server = $s.Name }
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $connection = $null
    try {
        $connection = Connect-StorSafe -ServerConfig $s -Credential $credentialByName[$s.Name]
        Add-Metric 'storsafe_up' 'API login succeeded (1) or failed (0).' 1 $labels
    } catch {
        $anyFailure = $true
        Add-Metric 'storsafe_up' 'API login succeeded (1) or failed (0).' 0 $labels
        Write-Warning "$($s.Name): $($_.Exception.Message)"
        continue
    }

    $cachePath = Join-Path $config.StateDirectory ("checkcache-{0}.json" -f (Get-SafeFileName $s.Name))
    $cache = @{}
    if (-not $Refresh) {
        $saved = Read-JsonState $cachePath
        if ($null -ne $saved) { foreach ($p in $saved.PSObject.Properties) { $cache[$p.Name] = $p.Value } }
    }
    $lookups = @{}

    try {
        foreach ($name in $checks.Keys) {
            if ($disabledChecks -contains $name) { continue }
            $now = Get-UnixNow
            $interval = if ($checkIntervalMinutes.ContainsKey($name)) { $checkIntervalMinutes[$name] } else { 0 }
            $ok = 1
            $lastSuccess = $now

            if ($interval -gt 0 -and $cache.ContainsKey($name) -and ($now - [long]$cache[$name].ts) -lt ($interval * 60 - 30)) {
                # Replay the cached samples from the last successful run.
                foreach ($sample in @($cache[$name].samples)) { Add-Sample $sample.n $sample.h $sample.t $sample.s }
                $lastSuccess = [long]$cache[$name].ts
            } else {
                if ($interval -gt 0) { $script:capture = [System.Collections.Generic.List[object]]::new() }
                try {
                    & $checks[$name] $connection $labels $lookups
                    if ($interval -gt 0) { $cache[$name] = [pscustomobject]@{ ts = $now; samples = $script:capture.ToArray() } }
                } catch {
                    $ok = 0
                    $anyFailure = $true
                    if ($cache.ContainsKey($name)) { $cache.Remove($name) }
                    Write-Warning "$($s.Name) [$name]: $($_.Exception.Message)"
                } finally {
                    $script:capture = $null
                }
            }
            Add-Metric 'storsafe_check_success' 'Collector check succeeded (1) or failed (0).' $ok ([ordered]@{ server = $s.Name; check = $name })
            if ($ok -eq 1) { Add-Metric 'storsafe_check_last_success_timestamp_seconds' 'When the check last succeeded (older than now for cached checks).' $lastSuccess ([ordered]@{ server = $s.Name; check = $name }) }
        }
    } finally {
        Disconnect-StorSafe $connection
        try { Write-JsonState $cachePath $cache } catch { Write-Warning "$($s.Name): cannot save check cache: $($_.Exception.Message)" }
        $timer.Stop()
        Add-Metric 'storsafe_collect_duration_seconds' 'Time spent collecting from the appliance.' $timer.Elapsed.TotalSeconds $labels
    }
}
# Unlabelled summary metrics belong to the top-level process only; in parallel mode the parent writes them.
if (-not $isChild) {
    Add-Metric 'storsafe_collector_last_run_timestamp_seconds' 'Unix time the collector last completed.' (Get-UnixNow) @{}
    Add-Metric 'storsafe_collector_info' 'Installed StorSafe monitoring package version (value is always 1).' 1 ([ordered]@{ version = $script:PackageVersion })
    # A per-server file from an earlier parallel run would duplicate this file's series, so drop it.
    foreach ($s in $selectedServers) {
        $stale = Join-Path $TextfileDirectory (Get-ServerMetricsFileName $s.Name)
        if ($stale -ne (Join-Path $TextfileDirectory $FileName) -and (Test-Path -LiteralPath $stale)) { Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue }
    }
}

$target = Join-Path $TextfileDirectory $FileName
$count = Write-MetricsFile $target
Write-Host ("Wrote {0} samples for {1} server(s) to {2}" -f $count, $selectedServers.Count, $target)
if ($anyFailure) { exit 2 }
exit 0
