<#
.SYNOPSIS
Writes the dashboards Grafana loads: monitoring\dashboards in the site's colours and brand, into
monitoring\dashboards-live (the folder the installers point Grafana's dashboard provider at).

.DESCRIPTION
The dashboard JSON in monitoring\dashboards is generated with the neutral example theme
(monitoring\theme.example.json). This script copies it to the output folder and, when
monitoring\theme.json exists, swaps in that file's colours, brand line and logo:

  - the example theme's hex colours, wherever they appear (HTML and CSS of the banner and cards),
    become the site theme's;
  - Grafana's named colours in panel thresholds and value mappings become the theme's status
    colours: green = ok, orange = warning, red = critical, blue = info;
  - the brand line in each dashboard's banner becomes "brand", and "logo" (an SVG or PNG for a dark
    background, relative to theme.json) is embedded in front of it.

The banner's version always becomes the one in the install folder's VERSION file.

With -HtmlPanels a dashboard that has a variant in monitoring\dashboards-html (the Business Text
plugin's card sections) is published from there instead; the installers pass it when the plugin is
installed in Grafana. Dashboards in the output folder that are no longer in monitoring\dashboards
are removed. Re-run after editing theme.json; Grafana picks the files up within a minute.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\StorSafeMonitoring\Publish-StorSafeDashboards.ps1 -HtmlPanels
#>
[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [string]$ThemePath,
    [string]$OutDirectory,
    [switch]$HtmlPanels
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Join-Path one name at a time: the script also runs under PowerShell 7 on the Linux host.
$monitoring = Join-Path $Root 'monitoring'
$source = Join-Path $monitoring 'dashboards'
$htmlSource = Join-Path $monitoring 'dashboards-html'
if (-not $OutDirectory) { $OutDirectory = Join-Path $monitoring 'dashboards-live' }
if (-not $ThemePath) { $ThemePath = Join-Path $monitoring 'theme.json' }
$defaults = Get-Content -LiteralPath (Join-Path $monitoring 'theme.example.json') -Raw | ConvertFrom-Json
$siteTheme = Test-Path -LiteralPath $ThemePath

$hexMap = @{}      # example hex (upper case) -> site hex
$namedMap = @{}    # Grafana colour name -> site hex
$brand = $null
$logoHtml = ''
if ($siteTheme) {
    $theme = Get-Content -LiteralPath $ThemePath -Raw | ConvertFrom-Json
    foreach ($p in $defaults.colors.PSObject.Properties) {
        $value = $p.Value
        if ($theme.PSObject.Properties['colors'] -and $theme.colors.PSObject.Properties[$p.Name]) { $value = [string]$theme.colors.($p.Name) }
        if ($value -notmatch '^#[0-9A-Fa-f]{6}$') { throw "theme colour '$($p.Name)' must be #RRGGBB, not '$value' ($ThemePath)" }
        $hexMap[$p.Value.ToUpperInvariant()] = $value.ToUpperInvariant()
    }
    $namedMap = @{ green = $hexMap[$defaults.colors.ok.ToUpperInvariant()]; orange = $hexMap[$defaults.colors.warning.ToUpperInvariant()]
                   red = $hexMap[$defaults.colors.critical.ToUpperInvariant()]; blue = $hexMap[$defaults.colors.info.ToUpperInvariant()] }
    if ($theme.PSObject.Properties['brand'] -and $theme.brand) { $brand = [string]$theme.brand }
    if ($theme.PSObject.Properties['logo'] -and $theme.logo) {
        $logo = [string]$theme.logo
        if (-not [IO.Path]::IsPathRooted($logo)) { $logo = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $ThemePath).ProviderPath) $logo }
        if (-not (Test-Path -LiteralPath $logo -PathType Leaf)) { throw "theme logo not found: $logo" }
        $mime = switch ([IO.Path]::GetExtension($logo).ToLowerInvariant()) {
            '.svg' { 'image/svg+xml' } '.png' { 'image/png' } '.jpg' { 'image/jpeg' } '.jpeg' { 'image/jpeg' }
            default { throw "theme logo must be .svg, .png or .jpg: $logo" }
        }
        $bytes = [IO.File]::ReadAllBytes($logo)
        if ($bytes.Length -gt 512KB) { throw "theme logo is larger than 512 KB: $logo" }
        # Goes inside a JSON string, so the quotes are escaped.
        $logoHtml = '<img src=\"data:{0};base64,{1}\" alt=\"\" style=\"height:40px;max-width:260px;flex:none\">' -f $mime, [Convert]::ToBase64String($bytes)
    }
}

# One pass over each kind of value, so that a site colour equal to another example colour is not
# replaced twice.
$hexPattern = if ($hexMap.Count) { '(?i)(' + (($hexMap.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')' } else { $null }
$hexEval = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $hexMap[$m.Value.ToUpperInvariant()] }
$namedEval = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $m.Groups[1].Value + '"' + $namedMap[$m.Groups[2].Value] + '"' }
$brandJson = $null
if ($brand) {
    # HTML-encoded, then JSON-encoded without the surrounding quotes.
    $brandJson = (ConvertTo-Json ([System.Net.WebUtility]::HtmlEncode($brand))).Trim('"')
}
$brandEval = [System.Text.RegularExpressions.MatchEvaluator] { param($m) '<!--brand-->' + $brandJson + '<!--/brand-->' }
$versionFile = Join-Path $Root 'VERSION'
$versionJson = $null
if (Test-Path -LiteralPath $versionFile) {
    $versionJson = (ConvertTo-Json ('v' + [System.Net.WebUtility]::HtmlEncode((Get-Content -LiteralPath $versionFile -Raw).Trim()))).Trim('"')
}
$versionEval = [System.Text.RegularExpressions.MatchEvaluator] { param($m) '<!--version-->' + $versionJson + '<!--/version-->' }

New-Item -ItemType Directory -Path $OutDirectory -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$published = @()
$html = 0
foreach ($file in @(Get-ChildItem -LiteralPath $source -Filter '*.json' -File | Sort-Object Name)) {
    $path = $file.FullName
    $variant = Join-Path $htmlSource $file.Name
    if ($HtmlPanels -and (Test-Path -LiteralPath $variant)) { $path = $variant; $html++ }
    $text = [IO.File]::ReadAllText($path)
    if ($versionJson) { $text = [regex]::Replace($text, '<!--version-->.*?<!--/version-->', $versionEval) }
    if ($siteTheme) {
        $text = [regex]::Replace($text, $hexPattern, $hexEval)
        $text = [regex]::Replace($text, '("(?:color|fixedColor)"\s*:\s*)"(green|orange|red|blue)"', $namedEval)
        if ($brandJson) { $text = [regex]::Replace($text, '<!--brand-->.*?<!--/brand-->', $brandEval) }
        if ($logoHtml) { $text = $text.Replace('<!--logo-->', '<!--logo-->' + $logoHtml) }
    }
    [IO.File]::WriteAllText((Join-Path $OutDirectory $file.Name), $text, $utf8)
    $published += $file.Name
}
foreach ($stale in @(Get-ChildItem -LiteralPath $OutDirectory -Filter '*.json' -File | Where-Object { $published -notcontains $_.Name })) {
    Remove-Item -LiteralPath $stale.FullName -Force
}

$themeNote = if ($siteTheme) { "theme $ThemePath" } else { 'default theme' }
Write-Output ("Published {0} dashboard(s) to {1} ({2}; {3} with HTML panels)" -f $published.Count, $OutDirectory, $themeNote, $html)
