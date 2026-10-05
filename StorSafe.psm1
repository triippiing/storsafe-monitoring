# StorSafe.psm1 - shared helpers for the FalconStor StorSafe REST API (/obd).
# Compatible with Windows PowerShell 5.1 and PowerShell 7.x.
#
# Exit code convention used by the scripts that import this module:
#   0 = OK / idle, 1 = informational (work active, tapes loaded),
#   2 = attention or API error, 3 = usage / configuration error.

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

function New-StorSafeError {
    # Category: Usage | Config | Auth | Connection | Api
    param([Parameter(Mandatory)][string]$Message, [string]$Category = 'Api', [int]$HttpStatus = 0, $Rc = $null)
    $ex = New-Object System.Exception $Message
    $ex.Data['StorSafeCategory'] = $Category
    $ex.Data['HttpStatus'] = $HttpStatus
    $ex.Data['Rc'] = $Rc
    return $ex
}

function Get-StorSafeErrorCategory {
    param([Parameter(Mandatory)]$ErrorRecordOrException)
    $ex = $ErrorRecordOrException
    if ($ex -is [System.Management.Automation.ErrorRecord]) { $ex = $ex.Exception }
    if ($ex.Data.Contains('StorSafeCategory')) { return [string]$ex.Data['StorSafeCategory'] }
    return 'Api'
}

function Get-HttpStatusFromError {
    param($ErrorRecord)
    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($null -eq $responseProperty -or $null -eq $responseProperty.Value) { return 0 }
    try { return [int]$responseProperty.Value.StatusCode } catch { return 0 }
}

# ---------------------------------------------------------------------------
# Configuration and credentials
# ---------------------------------------------------------------------------

function Get-StorSafeDefaultConfigPath {
    param([string]$ScriptRoot)
    if (-not [string]::IsNullOrWhiteSpace($env:STORSAFE_CONFIG)) { return $env:STORSAFE_CONFIG }
    return (Join-Path $ScriptRoot 'StorSafe.config.json')
}

function Get-OptionalValue {
    param($Object, [string]$Name, $Default)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    if ($property.Value -is [string] -and [string]::IsNullOrWhiteSpace($property.Value)) { return $Default }
    return $property.Value
}

function Import-StorSafeConfig {
    <#
    .SYNOPSIS
    Loads the estate configuration (appliances, transport, output) from JSON.
    Relative paths in the file are resolved against the config file's directory.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (New-StorSafeError "Config file not found: $Path. Copy StorSafe.config.example.json to StorSafe.config.json or set STORSAFE_CONFIG." 'Config')
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        throw (New-StorSafeError "Config file $Path is not valid JSON: $($_.Exception.Message)" 'Config')
    }

    $configDir = Split-Path -Parent (Resolve-Path -LiteralPath $Path).ProviderPath
    $defaults = Get-OptionalValue $raw 'Defaults' $null

    $outputDir = Get-OptionalValue $defaults 'OutputDirectory' 'Reports'
    if (-not [System.IO.Path]::IsPathRooted($outputDir)) { $outputDir = Join-Path $configDir $outputDir }

    # windows_exporter textfile directory; relative paths (default 'metrics') sit next to the config file.
    $textfileDir = Get-OptionalValue $defaults 'TextfileDirectory' 'metrics'
    if (-not [System.IO.Path]::IsPathRooted($textfileDir)) { $textfileDir = Join-Path $configDir $textfileDir }

    $servers = @(Get-OptionalValue $raw 'Servers' @())
    if ($servers.Count -eq 0) { throw (New-StorSafeError "Config file $Path defines no Servers." 'Config') }

    $resolved = foreach ($s in $servers) {
        $name = Get-OptionalValue $s 'Name' $null
        $hostName = Get-OptionalValue $s 'Host' $null
        if (-not $name -or -not $hostName) { throw (New-StorSafeError "Every entry in Servers needs Name and Host ($Path)." 'Config') }

        $credFile = Get-OptionalValue $s 'CredentialFile' $null
        if ($credFile -and -not [System.IO.Path]::IsPathRooted($credFile)) { $credFile = Join-Path $configDir $credFile }

        [pscustomobject]@{
            Name                 = [string]$name
            Host                 = [string]$hostName
            # Login body 'server' field must be the appliance IP; defaults to Host (resolved if it is a DNS name).
            ServerAddress        = [string](Get-OptionalValue $s 'ServerAddress' '')
            Scheme               = [string](Get-OptionalValue $s 'Scheme' (Get-OptionalValue $defaults 'Scheme' 'https'))
            Port                 = [int](Get-OptionalValue $s 'Port' (Get-OptionalValue $defaults 'Port' 0))
            SkipCertificateCheck = [bool](Get-OptionalValue $s 'SkipCertificateCheck' (Get-OptionalValue $defaults 'SkipCertificateCheck' $false))
            TimeoutSec           = [int](Get-OptionalValue $s 'TimeoutSec' (Get-OptionalValue $defaults 'TimeoutSec' 30))
            CredentialFile       = $credFile
        }
    }

    foreach ($r in $resolved) {
        if ($r.Scheme -notin @('http', 'https')) { throw (New-StorSafeError "Server $($r.Name): Scheme must be http or https." 'Config') }
    }

    # Collector state (event log bookmark, cached slow checks) and the raw event log archive.
    $stateDir = Get-OptionalValue $defaults 'StateDirectory' 'state'
    if (-not [System.IO.Path]::IsPathRooted($stateDir)) { $stateDir = Join-Path $configDir $stateDir }
    $eventDir = Get-OptionalValue $defaults 'EventLogDirectory' 'events'
    if (-not [System.IO.Path]::IsPathRooted($eventDir)) { $eventDir = Join-Path $configDir $eventDir }

    [pscustomobject]@{
        Path            = $Path
        OutputDirectory = $outputDir
        TextfileDirectory = $textfileDir
        StateDirectory  = $stateDir
        EventLogDirectory = $eventDir
        CollectEventLog = [bool](Get-OptionalValue $defaults 'CollectEventLog' $true)
        EventLogRetentionDays = [int](Get-OptionalValue $defaults 'EventLogRetentionDays' 90)
        DisabledChecks  = @(Get-OptionalValue $defaults 'DisabledChecks' @())
        RetentionDays   = [int](Get-OptionalValue $defaults 'RetentionDays' 30)
        Servers         = @($resolved)
    }
}

function Select-StorSafeServer {
    <#
    .SYNOPSIS
    Picks servers by -Server names, -All, or (interactive only) a numbered menu.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [string[]]$Server,
        [switch]$All,
        [switch]$NonInteractive
    )

    $servers = @($Config.Servers)
    if ($All) { return $servers }

    if ($Server -and $Server.Count -gt 0) {
        $selected = foreach ($wanted in $Server) {
            $match = @($servers | Where-Object { $_.Name -ieq $wanted -or $_.Host -ieq $wanted })
            if ($match.Count -eq 0) {
                throw (New-StorSafeError "Server '$wanted' is not in $($Config.Path). Known: $(($servers | ForEach-Object Name) -join ', ')" 'Usage')
            }
            $match[0]
        }
        return @($selected | Sort-Object Name -Unique)
    }

    if ($NonInteractive) { throw (New-StorSafeError 'Specify -Server <name[,name]> or -All when running with -NonInteractive.' 'Usage') }

    Write-Host ''
    Write-Host 'Available StorSafe servers' -ForegroundColor White
    for ($i = 0; $i -lt $servers.Count; $i++) {
        Write-Host ("{0}. {1} [{2}]" -f ($i + 1), $servers[$i].Name, $servers[$i].Host)
    }
    Write-Host 'A. All servers'

    $selection = Read-Host 'Select servers (for example: 1,2 or A)'
    if ([string]::IsNullOrWhiteSpace($selection)) { throw (New-StorSafeError 'No server selection was entered.' 'Usage') }
    if ($selection.Trim() -match '^(?i:a|all)$') { return $servers }

    $indexes = foreach ($entry in ($selection -split ',')) {
        $number = 0
        if (-not [int]::TryParse($entry.Trim(), [ref]$number)) {
            throw (New-StorSafeError "Invalid selection '$entry'. Enter A or comma-separated server numbers, for example 1,2." 'Usage')
        }
        if ($number -lt 1 -or $number -gt $servers.Count) {
            throw (New-StorSafeError "Server number $number is outside the valid range 1-$($servers.Count)." 'Usage')
        }
        $number - 1
    }
    return @($indexes | Select-Object -Unique | ForEach-Object { $servers[$_] })
}

function New-StorSafeCredentialFile {
    <#
    .SYNOPSIS
    Saves an API credential with Export-Clixml. On Windows the password is DPAPI-encrypted and
    can only be read back by the same user account on the same machine, so create it as the
    account that runs the scheduled task.
    .EXAMPLE
    Import-Module .\StorSafe.psm1; New-StorSafeCredentialFile -Path .\creds\storsafe-01.xml
    #>
    param([Parameter(Mandatory)][string]$Path, [string]$UserName)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $cred = if ($UserName) { Get-Credential -UserName $UserName -Message 'StorSafe API credential' } else { Get-Credential -Message 'StorSafe API credential' }
    if ($null -eq $cred) { throw (New-StorSafeError 'No credential entered.' 'Usage') }
    $cred | Export-Clixml -LiteralPath $Path
    Write-Host "Saved credential for $($cred.UserName) to $Path"
}

function Get-StorSafeCredential {
    <#
    .SYNOPSIS
    Credential precedence: -Credential parameter, then the server's CredentialFile, then an
    interactive prompt (not allowed with -NonInteractive).
    #>
    param(
        [Parameter(Mandatory)]$ServerConfig,
        [PSCredential]$Credential,
        [switch]$NonInteractive
    )
    if ($null -ne $Credential) { return $Credential }

    # A configured but missing credential file is fatal only for unattended runs; interactively we prompt.
    $credFileMissing = $ServerConfig.CredentialFile -and -not (Test-Path -LiteralPath $ServerConfig.CredentialFile -PathType Leaf)
    if ($credFileMissing -and $NonInteractive) {
        throw (New-StorSafeError "Credential file for $($ServerConfig.Name) not found: $($ServerConfig.CredentialFile). Create it with New-StorSafeCredentialFile." 'Config')
    }
    if ($ServerConfig.CredentialFile -and -not $credFileMissing) {
        try {
            $imported = Import-Clixml -LiteralPath $ServerConfig.CredentialFile
        } catch {
            throw (New-StorSafeError "Cannot read credential file for $($ServerConfig.Name) (it must be created by the same user on the same machine): $($_.Exception.Message)" 'Config')
        }
        if ($imported -isnot [PSCredential]) { throw (New-StorSafeError "Credential file for $($ServerConfig.Name) does not contain a PSCredential." 'Config') }
        return $imported
    }

    if ($NonInteractive) {
        throw (New-StorSafeError "No CredentialFile configured for $($ServerConfig.Name) and -NonInteractive was given." 'Config')
    }
    $prompted = Get-Credential -Message ("Enter API credentials for {0} [{1}]" -f $ServerConfig.Name, $ServerConfig.Host)
    if ($null -eq $prompted) { throw (New-StorSafeError "No credentials supplied for $($ServerConfig.Name)." 'Usage') }
    return $prompted
}

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

$script:IsCore = $PSVersionTable.PSEdition -eq 'Core'

function Enable-LegacyCertificateBypass {
    # Windows PowerShell 5.1 only: Invoke-RestMethod has no -SkipCertificateCheck there.
    if ($script:IsCore) { return }
    if (-not ([System.Management.Automation.PSTypeName]'StorSafeTrustAllCertsPolicy').Type) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class StorSafeTrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object StorSafeTrustAllCertsPolicy
}

if (-not $script:IsCore) {
    # Windows PowerShell 5.1 defaults to TLS 1.0/1.1 on older .NET builds.
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
}

function Resolve-StorSafeServerAddress {
    param([Parameter(Mandatory)]$ServerConfig)
    if ($ServerConfig.ServerAddress) { return $ServerConfig.ServerAddress }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($ServerConfig.Host, [ref]$ip)) { return $ServerConfig.Host }
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($ServerConfig.Host) | Where-Object { $_.AddressFamily -eq 'InterNetwork' }
        if ($addresses) { return @($addresses)[0].IPAddressToString }
    } catch { }
    throw (New-StorSafeError "Cannot resolve $($ServerConfig.Host) to an IPv4 address; set ServerAddress in the config." 'Connection')
}

function Invoke-StorSafeCurlGet {
    # GET with a JSON body. Some endpoints (e.g. /virtualtape) take their filter as a GET body and answer
    # HTTP 415 without one. Windows PowerShell 5.1 (.NET Framework) cannot send a body on GET, so this uses
    # curl.exe, which ships with Windows 10 1803+ / Server 2019+. The body and response go through temp files.
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Body)
    $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $curl) { $curl = Get-Command curl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $curl) { throw (New-StorSafeError "GET $Path needs a request body, which Windows PowerShell 5.1 cannot send and curl.exe was not found. Run the script with PowerShell 7 (pwsh.exe) instead." 'Api') }

    $uri = $Connection.BaseUri + $Path
    $cookie = $Connection.WebSession.Cookies.GetCookies([uri]$uri)['session_id']
    $bodyFile = [System.IO.Path]::GetTempFileName(); $outFile = [System.IO.Path]::GetTempFileName(); $errFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($bodyFile, $Body, (New-Object System.Text.UTF8Encoding($false)))
        $arguments = @('-s', '-S', '-X', 'GET', '--max-time', [string]([Math]::Max(60, $Connection.Server.TimeoutSec)),
            '-H', 'Content-Type: application/json', '-H', 'Accept: application/json',
            '--data-binary', "@$bodyFile", '-o', $outFile, '--stderr', $errFile, '-w', '%{http_code}')
        if ($cookie) { $arguments += @('-b', ('session_id=' + $cookie.Value)) }
        if ($Connection.Server.SkipCertificateCheck) { $arguments += '-k' }
        $arguments += $uri
        # stderr goes to a file: in Windows PowerShell 5.1, redirected native stderr becomes a terminating error under Stop.
        $code = (& $curl.Source @arguments | Out-String).Trim()
        $status = 0
        if (-not [int]::TryParse(($code -split "`n")[-1].Trim(), [ref]$status) -or $status -eq 0) {
            throw (New-StorSafeError ("GET $Path failed (curl exit $LASTEXITCODE): " + [System.IO.File]::ReadAllText($errFile).Trim()) 'Connection')
        }
        $text = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8)
        if ($status -ge 400) {
            $category = if ($status -eq 401 -or $status -eq 403) { 'Auth' } else { 'Api' }
            throw (New-StorSafeError "GET $Path failed (HTTP $status): $text" $category $status)
        }
        return ($text | ConvertFrom-Json)
    } finally {
        Remove-Item -LiteralPath $bodyFile, $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-StorSafeHttp {
    # Single HTTP call with consistent error classification. No retry or rc checks here.
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [string]$Body
    )
    if ($Method -eq 'Get' -and $PSBoundParameters.ContainsKey('Body') -and (-not $script:IsCore -or $env:STORSAFE_FORCE_CURL)) {
        return Invoke-StorSafeCurlGet -Connection $Connection -Path $Path -Body $Body
    }
    $params = @{
        Method      = $Method
        Uri         = $Connection.BaseUri + $Path
        WebSession  = $Connection.WebSession
        Headers     = @{ Accept = 'application/json' }
        TimeoutSec  = $Connection.Server.TimeoutSec
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $params.ContentType = 'application/json'
        $params.Body = $Body
    }
    if ($script:IsCore -and $Connection.Server.SkipCertificateCheck) { $params.SkipCertificateCheck = $true }

    try {
        return Invoke-RestMethod @params
    } catch {
        $status = Get-HttpStatusFromError $_
        $category = 'Api'
        if ($status -eq 401 -or $status -eq 403) { $category = 'Auth' }
        elseif ($status -eq 0) { $category = 'Connection' }   # DNS, refused, TLS, timeout
        throw (New-StorSafeError ("{0} {1} failed{2}: {3}" -f $Method, $Path, $(if ($status) { " (HTTP $status)" } else { '' }), $_.Exception.Message) $category $status)
    }
}

function Test-TransientError {
    param($Exception)
    $category = Get-StorSafeErrorCategory $Exception
    $status = [int]$Exception.Data['HttpStatus']
    return ($category -eq 'Connection' -or $status -in @(408, 500, 502, 503, 504))
}

function Assert-StorSafeRc {
    param($Response, [string]$What)
    if ($null -eq $Response) { throw (New-StorSafeError "$What returned an empty response." 'Api') }
    $rcProperty = $Response.PSObject.Properties['rc']
    if ($null -eq $rcProperty) { throw (New-StorSafeError "$What response has no rc field." 'Api') }
    if ([int]$rcProperty.Value -ne 0) {
        throw (New-StorSafeError "$What returned rc=$($rcProperty.Value). Look up with GET /obd/server/rcs/$($rcProperty.Value)." 'Api' 0 $rcProperty.Value)
    }
}

function Connect-StorSafe {
    param(
        [Parameter(Mandatory)]$ServerConfig,
        [Parameter(Mandatory)][PSCredential]$Credential
    )

    if ($ServerConfig.SkipCertificateCheck) { Enable-LegacyCertificateBypass }

    $baseUri = if ($ServerConfig.Port -gt 0) { "{0}://{1}:{2}/obd" -f $ServerConfig.Scheme, $ServerConfig.Host, $ServerConfig.Port }
               else { "{0}://{1}/obd" -f $ServerConfig.Scheme, $ServerConfig.Host }

    $connection = [pscustomobject]@{
        Server     = $ServerConfig
        BaseUri    = $baseUri
        WebSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        Credential = $Credential
        Address    = Resolve-StorSafeServerAddress $ServerConfig
    }
    Open-StorSafeSession $connection
    return $connection
}

function Open-StorSafeSession {
    param([Parameter(Mandatory)]$Connection)

    $Connection.WebSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $body = @{
        username = $Connection.Credential.UserName
        password = $Connection.Credential.GetNetworkCredential().Password
        server   = $Connection.Address
    } | ConvertTo-Json -Compress

    $response = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $response = Invoke-StorSafeHttp -Connection $Connection -Method Post -Path '/auth/login' -Body $body
            break
        } catch {
            if ($attempt -eq 2 -or -not (Test-TransientError $_.Exception)) { throw }
            Start-Sleep -Seconds 3
        }
    }

    # Never echo the login response: it carries the session id.
    if ($null -eq $response -or $null -eq $response.PSObject.Properties['rc']) {
        throw (New-StorSafeError 'Login response did not contain an rc field.' 'Auth')
    }
    if ([int]$response.rc -ne 0) {
        throw (New-StorSafeError "StorSafe rejected the login for $($Connection.Credential.UserName) (rc=$($response.rc))." 'Auth' 0 $response.rc)
    }
    $idProperty = $response.PSObject.Properties['id']
    if ($null -eq $idProperty) { $idProperty = $response.PSObject.Properties['session_id'] }
    if ($null -eq $idProperty -or [string]::IsNullOrWhiteSpace([string]$idProperty.Value)) {
        throw (New-StorSafeError 'Login returned rc=0 but no session id.' 'Auth')
    }

    # Some PowerShell/appliance combinations do not retain Set-Cookie automatically.
    $uri = [uri]$Connection.BaseUri
    if ($null -eq $Connection.WebSession.Cookies.GetCookies($uri)['session_id']) {
        $Connection.WebSession.Cookies.Add((New-Object System.Net.Cookie('session_id', [string]$idProperty.Value, '/', $uri.Host)))
    }
}

function Invoke-StorSafeApi {
    <#
    .SYNOPSIS
    API call with rc checking, one retry on transient failures, and one re-login on 401
    (sessions expire after ~10 minutes idle). Path is relative to /obd, e.g. '/dedupepolicy'.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Get', 'Post', 'Put', 'Delete')][string]$Method = 'Get',
        $Body
    )
    $call = @{ Connection = $Connection; Method = $Method; Path = $Path }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $call.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }
    }

    $reloggedIn = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $response = Invoke-StorSafeHttp @call
            Assert-StorSafeRc -Response $response -What "$Method $Path"
            return $response
        } catch {
            $ex = $_.Exception
            if ((Get-StorSafeErrorCategory $ex) -eq 'Auth' -and [int]$ex.Data['HttpStatus'] -eq 401 -and -not $reloggedIn) {
                $reloggedIn = $true
                Open-StorSafeSession $Connection
                continue
            }
            if ($attempt -lt 3 -and (Test-TransientError $ex)) { Start-Sleep -Seconds (2 * $attempt); continue }
            throw
        }
    }
}

function Invoke-StorSafeDownload {
    <#
    .SYNOPSIS
    Calls an endpoint that returns a file rather than JSON (e.g. PUT /server/event with Accept: application/csv)
    and returns the body as text. Handles gzip-compressed bodies and ISO-8859-1 content. Re-logs in once on 401.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Get', 'Post', 'Put')][string]$Method = 'Get',
        $Body,
        [string]$Accept = 'application/csv'
    )
    $params = @{
        Method          = $Method
        Uri             = $Connection.BaseUri + $Path
        WebSession      = $Connection.WebSession
        Headers         = @{ Accept = $Accept }
        TimeoutSec      = [Math]::Max(120, $Connection.Server.TimeoutSec)
        UseBasicParsing = $true
        ErrorAction     = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $params.ContentType = 'application/json'
        $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }
    }
    if ($script:IsCore -and $Connection.Server.SkipCertificateCheck) { $params.SkipCertificateCheck = $true }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $params.WebSession = $Connection.WebSession
            $response = Invoke-WebRequest @params
            break
        } catch {
            $status = Get-HttpStatusFromError $_
            if ($status -eq 401 -and $attempt -eq 1) { Open-StorSafeSession $Connection; continue }
            $category = if ($status -eq 401 -or $status -eq 403) { 'Auth' } elseif ($status -eq 0) { 'Connection' } else { 'Api' }
            throw (New-StorSafeError ("{0} {1} failed{2}: {3}" -f $Method, $Path, $(if ($status) { " (HTTP $status)" } else { '' }), $_.Exception.Message) $category $status)
        }
    }

    $content = $response.Content
    if ($content -is [string]) {
        $bytes = $null
        $text = $content
    } else {
        $bytes = [byte[]]$content
        $text = $null
    }
    if ($null -eq $text) {
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0x1F -and $bytes[1] -eq 0x8B) {
            $in = New-Object System.IO.MemoryStream(, $bytes)
            $gz = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
            $out = New-Object System.IO.MemoryStream
            $gz.CopyTo($out); $gz.Dispose()
            $bytes = $out.ToArray()
        }
        $text = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($bytes)
    }
    # A JSON body here means the API returned an rc error instead of the file.
    if ($text -match '^\s*\{\s*"rc"') {
        $json = $text | ConvertFrom-Json
        Assert-StorSafeRc -Response $json -What "$Method $Path"
    }
    return $text
}

function Get-StorSafePagedCollection {
    <#
    .SYNOPSIS
    Reads an offset/limit endpoint until 'total' items are collected, e.g.
    Get-StorSafePagedCollection -Connection $c -Path '/virtualtape' -CollectionName 'tapes'
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CollectionName,
        [int]$PageSize = 1000,
        $Body
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $offset = 0
    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    while ($true) {
        $call = @{ Connection = $Connection; Path = ("{0}{1}offset={2}&limit={3}" -f $Path, $separator, $offset, $PageSize) }
        if ($null -ne $Body) { $call.Body = $Body }
        $response = Invoke-StorSafeApi @call
        $data = Get-OptionalValue $response 'data' $null
        $page = @(Get-OptionalValue $data $CollectionName @())
        foreach ($item in $page) { $items.Add($item) }
        $total = [int](Get-OptionalValue $data 'total' 0)
        $offset += $PageSize
        if ($page.Count -eq 0 -or $page.Count -lt $PageSize -or ($total -gt 0 -and $items.Count -ge $total)) { break }
    }
    return $items.ToArray()
}

function Disconnect-StorSafe {
    param($Connection)
    if ($null -eq $Connection) { return }
    try {
        Invoke-StorSafeHttp -Connection $Connection -Method Post -Path '/auth/logout' -Body '{}' | Out-Null
    } catch {
        Write-Verbose "Logout warning for $($Connection.BaseUri): $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Get-StorSafeTimestamp {
    # One UTC ISO-8601 timestamp per run, culture independent.
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-StorSafeEpoch {
    param($Epoch)
    if ($null -eq $Epoch -or [long]$Epoch -le 0) { return '' }
    return [DateTimeOffset]::FromUnixTimeSeconds([long]$Epoch).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-StorSafeReportPath {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Prefix)
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    return (Join-Path $Directory ("{0}-{1}.csv" -f $Prefix, (Get-Date -Format 'yyyyMMdd-HHmmss')))
}

function Remove-StorSafeOldReport {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Prefix, [int]$RetentionDays)
    if ($RetentionDays -le 0 -or -not (Test-Path -LiteralPath $Directory)) { return }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $Directory -Filter "$Prefix-*.csv" -File |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-StorSafeUsageError {
    # Writes to stderr without throwing, so callers can 'exit 3' reliably.
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("ERROR: $Message")
}

Export-ModuleMember -Function @(
    'New-StorSafeError', 'Get-StorSafeErrorCategory',
    'Get-StorSafeDefaultConfigPath', 'Import-StorSafeConfig', 'Select-StorSafeServer',
    'New-StorSafeCredentialFile', 'Get-StorSafeCredential',
    'Connect-StorSafe', 'Disconnect-StorSafe', 'Invoke-StorSafeApi', 'Invoke-StorSafeDownload', 'Get-StorSafePagedCollection',
    'Get-StorSafeTimestamp', 'ConvertFrom-StorSafeEpoch', 'Get-StorSafeReportPath', 'Remove-StorSafeOldReport',
    'Write-StorSafeUsageError', 'Get-OptionalValue'
)
