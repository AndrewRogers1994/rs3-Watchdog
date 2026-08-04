<#
.SYNOPSIS
    Bundles Watchdog and its required plugin dependencies into a zip.

.DESCRIPTION
    Stages the same "core" file set as .vscode/deploy.ps1 for Watchdog and each
    entry in plugin.json's requiredDependencies: plugin.json (if present), every
    file under resources/, and every *.lua file outside tests/docs/.git/.vscode/staging.
    Lua files are naively stripped: drop whole-line -- comments (including simple
    --[[ ... ]] blocks) and inline trailing -- comments; -- inside quoted/long
    strings is preserved.

    The zip layout mirrors the live client: one top-level folder per plugin
    (Watchdog/, LibNodeGraph/, …).

.PARAMETER Output
    Path for the output zip. Defaults to Watchdog-<version>.zip beside this script,
    where <version> comes from plugin.json.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File bundle.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File bundle.ps1 -Output dist/Watchdog-custom.zip
#>
param(
    [string]$Output
)

$ErrorActionPreference = 'Stop'

$watchdogDir = $PSScriptRoot
$rs3Root = Split-Path -Parent $watchdogDir
$pluginName = 'Watchdog'
$pruneSegments = @('tests', 'docs', '.git', '.vscode', 'staging')

function Test-Pruned {
    param([string]$RelativePath)
    $segments = $RelativePath -split '[\\/]'
    foreach ($seg in $segments) {
        if ($pruneSegments -contains $seg) { return $true }
    }
    return $false
}

function Get-PluginDeployFiles {
    param([string]$SrcDir)

    $files = New-Object System.Collections.Generic.List[string]
    $prefix = $SrcDir.TrimEnd('\', '/') + '\'

    $pluginJson = Join-Path $SrcDir 'plugin.json'
    if (Test-Path -LiteralPath $pluginJson -PathType Leaf) { $files.Add('plugin.json') }

    $resources = Join-Path $SrcDir 'resources'
    if (Test-Path -LiteralPath $resources -PathType Container) {
        Get-ChildItem -LiteralPath $resources -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($prefix.Length)
            $files.Add($rel)
        }
    }

    Get-ChildItem -LiteralPath $SrcDir -Recurse -File -Filter *.lua | ForEach-Object {
        $rel = $_.FullName.Substring($prefix.Length)
        if (-not (Test-Pruned $rel)) { $files.Add($rel) }
    }

    return $files
}

function Remove-InlineLuaComment {
    param([string]$Line)

    $len = $Line.Length
    $i = 0
    $sb = New-Object System.Text.StringBuilder

    while ($i -lt $len) {
        $c = $Line[$i]

        if ($c -eq "'" -or $c -eq '"') {
            $quote = $c
            [void]$sb.Append($c)
            $i++
            while ($i -lt $len) {
                $ch = $Line[$i]
                [void]$sb.Append($ch)
                if ($ch -eq '\' -and ($i + 1) -lt $len) {
                    $i++
                    [void]$sb.Append($Line[$i])
                } elseif ($ch -eq $quote) {
                    break
                }
                $i++
            }
            $i++
            continue
        }

        if ($c -eq '[' -and ($i + 1) -lt $len) {
            $eq = 0
            $j = $i + 1
            while ($j -lt $len -and $Line[$j] -eq '=') { $eq++; $j++ }
            if ($j -lt $len -and $Line[$j] -eq '[') {
                $open = $Line.Substring($i, $j - $i + 1)
                $close = ']' + ('=' * $eq) + ']'
                $rest = $Line.Substring($j + 1)
                $end = $rest.IndexOf($close)
                if ($end -ge 0) {
                    [void]$sb.Append($open)
                    [void]$sb.Append($rest.Substring(0, $end + $close.Length))
                    $i = $j + 1 + $end + $close.Length
                    continue
                }
            }
        }

        if ($c -eq '-' -and ($i + 1) -lt $len -and $Line[$i + 1] -eq '-') {
            if (($i + 2) -lt $len -and $Line[$i + 2] -eq '[') {
                $eq = 0
                $j = $i + 3
                while ($j -lt $len -and $Line[$j] -eq '=') { $eq++; $j++ }
                if ($j -lt $len -and $Line[$j] -eq '[') {
                    $close = ']' + ('=' * $eq) + ']'
                    $rest = $Line.Substring($j + 1)
                    $end = $rest.IndexOf($close)
                    if ($end -ge 0) {
                        $i = $j + 1 + $end + $close.Length
                        continue
                    }
                }
            }
            break
        }

        [void]$sb.Append($c)
        $i++
    }

    return $sb.ToString().TrimEnd()
}

function Remove-NaiveLuaComments {
    param([string]$Text)

    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $out = New-Object System.Collections.Generic.List[string]
    $inBlock = $false

    foreach ($line in ($normalized -split "`n", -1)) {
        if ($inBlock) {
            if ($line -match '\]\]') { $inBlock = $false }
            continue
        }

        $trimmed = $line.TrimStart()
        if ($trimmed.StartsWith('--')) {
            if ($trimmed.StartsWith('--[[') -and $trimmed -notmatch '\]\]') {
                $inBlock = $true
            }
            continue
        }

        $stripped = Remove-InlineLuaComment $line
        if ($stripped.Length -gt 0) {
            $out.Add($stripped.TrimEnd("`r"))
        }
    }

    if ($out.Count -eq 0) {
        return ""
    }
    return ($out -join "`n") + "`n"
}

function Copy-BundledFile {
    param(
        [string]$Src,
        [string]$Dst,
        [string]$RelativePath
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $Dst) -Force | Out-Null

    if ($RelativePath -like '*.lua') {
        $text = [System.IO.File]::ReadAllText($Src)
        $stripped = Remove-NaiveLuaComments $text
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Dst, $stripped, $utf8)
        return
    }

    Copy-Item -LiteralPath $Src -Destination $Dst -Force
}

function Stage-Plugin {
    param(
        [string]$Name,
        [string]$StageRoot
    )

    $srcDir = Join-Path $rs3Root $Name
    if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) {
        throw "Dependency folder not found: $srcDir"
    }

    $files = Get-PluginDeployFiles $srcDir
    if ($files.Count -eq 0) {
        throw "No deployable files found for '$Name'."
    }

    foreach ($rel in $files) {
        $dst = Join-Path $StageRoot (Join-Path $Name $rel)
        Copy-BundledFile -Src (Join-Path $srcDir $rel) -Dst $dst -RelativePath $rel
    }

    return $files.Count
}

$manifestPath = Join-Path $watchdogDir 'plugin.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Missing plugin.json at $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$plugins = @()
if ($null -ne $manifest.requiredDependencies) {
    $plugins += @($manifest.requiredDependencies)
}
$plugins += $pluginName
$plugins = $plugins | Select-Object -Unique

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("watchdog-bundle-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null

try {
    $totalFiles = 0
    foreach ($name in $plugins) {
        $count = Stage-Plugin -Name $name -StageRoot $stage
        $totalFiles += $count
        Write-Host "  $name  ($count files)"
    }

    if (-not $Output) {
        $version = if ($manifest.version) { $manifest.version } else { 'unknown' }
        $Output = Join-Path $watchdogDir "Watchdog-$version.zip"
    }
    $Output = [System.IO.Path]::GetFullPath($Output)
    $outDir = Split-Path -Parent $Output
    if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Output -PathType Leaf) {
        $answer = Read-Host "Output file already exists:`n  $Output`nOverwrite? [y/N]"
        if ($answer -notmatch '^[Yy]') {
            Write-Host 'Bundle cancelled.' -ForegroundColor Yellow
            exit 1
        }
        Remove-Item -LiteralPath $Output -Force
    }

    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $Output -CompressionLevel Optimal
    Write-Host "Bundled $($plugins.Count) plugins ($totalFiles files) -> $Output" -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

exit 0
