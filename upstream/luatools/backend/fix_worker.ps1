param(
  [Parameter(Mandatory=$true)][ValidateSet("Apply","Unfix")][string]$Mode,
  [Parameter(Mandatory=$true)][string]$AppId,
  [Parameter(Mandatory=$true)][string]$PluginRoot,
  [string]$DownloadUrl = "",
  [string]$InstallPath = "",
  [string]$FixType = "",
  [string]$GameName = "",
  [string]$FixDate = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$backend = Join-Path $PluginRoot "backend"
$temp = Join-Path $backend "temp_dl"
$fixStatusPath = Join-Path $temp ("fix_status_{0}.json" -f $AppId)
$unfixStatusPath = Join-Path $temp ("unfix_status_{0}.json" -f $AppId)
$zipPath = Join-Path $temp ("fix_{0}.zip" -f $AppId)

function Write-State {
  param([string]$Path, [hashtable]$State)
  New-Item -ItemType Directory -Path $temp -Force | Out-Null
  $payload = @{} + $State
  $payload.updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  $payload | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Test-Cancelled {
  param([string]$Path)
  try {
    if (Test-Path -LiteralPath $Path) {
      $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
      return $state.status -eq "cancelled"
    }
  } catch {}
  return $false
}

function Get-SafeTargetPath {
  param([string]$BasePath, [string]$RelativePath)
  $baseFull = [System.IO.Path]::GetFullPath($BasePath)
  $targetFull = [System.IO.Path]::GetFullPath((Join-Path $baseFull $RelativePath))
  $baseWithSlash = $baseFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if ($targetFull -ne $baseFull -and -not $targetFull.StartsWith($baseWithSlash, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $null
  }
  return $targetFull
}

function Get-ArchiveEntries {
  param([System.IO.Compression.ZipArchive]$Archive)
  $entries = @($Archive.Entries | Where-Object { $_.FullName -and -not $_.FullName.EndsWith("/") })
  $top = @{}
  foreach ($entry in $entries) {
    $parts = $entry.FullName -split "[/\\]"
    if ($parts[0]) { $top[$parts[0]] = $true }
  }
  $stripPrefix = ""
  if ($top.Count -eq 1 -and $top.ContainsKey($AppId)) {
    $stripPrefix = "$AppId/"
  }
  return @($entries | ForEach-Object {
    $relative = $_.FullName
    if ($stripPrefix -and $relative.StartsWith($stripPrefix)) {
      $relative = $relative.Substring($stripPrefix.Length)
    }
    [pscustomobject]@{ Entry = $_; Relative = $relative }
  } | Where-Object { $_.Relative })
}

function Invoke-Apply {
  if (-not $DownloadUrl -or -not $InstallPath) {
    Write-State $fixStatusPath @{ status = "failed"; success = $false; error = "Missing download URL or install path" }
    return
  }
  if (-not (Test-Path -LiteralPath $InstallPath)) {
    Write-State $fixStatusPath @{ status = "failed"; success = $false; error = "Install path does not exist" }
    return
  }

  try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    Write-State $fixStatusPath @{ status = "downloading"; bytesRead = 0; totalBytes = 0 }

    $request = [System.Net.HttpWebRequest]::Create($DownloadUrl)
    $request.UserAgent = "discord(dot)gg/luatools"
    $request.AllowAutoRedirect = $true
    $response = $request.GetResponse()
    $total = [int64]$response.ContentLength
    if ($total -lt 0) { $total = 0 }
    $stream = $response.GetResponseStream()
    $output = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $buffer = New-Object byte[] 65536
    $readTotal = [int64]0
    try {
      while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        if (Test-Cancelled $fixStatusPath) { throw "cancelled" }
        $output.Write($buffer, 0, $read)
        $readTotal += $read
        Write-State $fixStatusPath @{ status = "downloading"; bytesRead = $readTotal; totalBytes = $total }
      }
    } finally {
      $output.Close()
      $stream.Close()
      $response.Close()
    }

    if (Test-Cancelled $fixStatusPath) { throw "cancelled" }
    Write-State $fixStatusPath @{ status = "extracting"; bytesRead = $readTotal; totalBytes = $total }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    $extracted = New-Object System.Collections.Generic.List[string]
    try {
      foreach ($item in Get-ArchiveEntries $archive) {
        if (Test-Cancelled $fixStatusPath) { throw "cancelled" }
        $relative = ($item.Relative -replace "\\", "/").TrimStart("/")
        if (-not $relative) { continue }
        $target = Get-SafeTargetPath -BasePath $InstallPath -RelativePath $relative
        if (-not $target) { continue }
        $targetDir = Split-Path -Parent $target
        if ($targetDir) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($item.Entry, $target)
        $extracted.Add($relative)
      }
    } finally {
      $archive.Dispose()
    }

    if ($FixType.ToLowerInvariant() -eq "online fix (unsteam)") {
      $iniRel = @($extracted | Where-Object { $_.ToLowerInvariant().EndsWith("unsteam.ini") } | Select-Object -First 1)
      if ($iniRel) {
        $iniPath = Join-Path $InstallPath ($iniRel -replace "/", "\")
        if (Test-Path -LiteralPath $iniPath) {
          $ini = Get-Content -LiteralPath $iniPath -Raw -Encoding UTF8
          $ini.Replace("<appid>", $AppId) | Set-Content -LiteralPath $iniPath -Encoding UTF8
        }
      }
    }

    $logPath = Join-Path $InstallPath ("luatools-fix-log-{0}.log" -f $AppId)
    $existing = ""
    if (Test-Path -LiteralPath $logPath) {
      $existing = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
    }
    $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $log = New-Object System.Text.StringBuilder
    if ($existing) {
      [void]$log.Append($existing.TrimEnd())
      [void]$log.Append("`n`n---`n`n")
    }
    [void]$log.Append("[FIX]`n")
    [void]$log.Append("Date: $stamp`n")
    [void]$log.Append("Game: " + ($(if ($GameName) { $GameName } else { "Unknown Game ($AppId)" })) + "`n")
    [void]$log.Append("Fix Type: $FixType`n")
    [void]$log.Append("Download URL: $DownloadUrl`n")
    [void]$log.Append("Files:`n")
    foreach ($file in $extracted) { [void]$log.Append("$file`n") }
    [void]$log.Append("[/FIX]`n")
    $log.ToString() | Set-Content -LiteralPath $logPath -Encoding UTF8

    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Write-State $fixStatusPath @{ status = "done"; success = $true; bytesRead = $readTotal; totalBytes = $total; filesCount = $extracted.Count }
  } catch {
    if ($_.Exception.Message -eq "cancelled") {
      Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
      Write-State $fixStatusPath @{ status = "cancelled"; success = $false; error = "Cancelled by user" }
    } else {
      Write-State $fixStatusPath @{ status = "failed"; success = $false; error = $_.Exception.Message }
    }
  }
}

function Invoke-Unfix {
  if (-not $InstallPath) {
    Write-State $unfixStatusPath @{ status = "failed"; success = $false; error = "Install path does not exist" }
    return
  }
  $logPath = Join-Path $InstallPath ("luatools-fix-log-{0}.log" -f $AppId)
  if (-not (Test-Path -LiteralPath $logPath)) {
    Write-State $unfixStatusPath @{ status = "failed"; success = $false; error = "No fix log found. Cannot un-fix." }
    return
  }

  try {
    Write-State $unfixStatusPath @{ status = "removing"; progress = "Reading log file..." }
    $content = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
    $files = New-Object System.Collections.Generic.HashSet[string]
    $remaining = New-Object System.Collections.Generic.List[string]

    if ($content -match '\[FIX\]') {
      foreach ($raw in ($content -split '\[FIX\]')) {
        if (-not $raw.Trim()) { continue }
        $date = ""
        $blockFiles = @()
        $inFiles = $false
        foreach ($line in ($raw -split "`r?`n")) {
          $trimmed = $line.Trim()
          if ($trimmed -eq "[/FIX]" -or $trimmed -eq "---") { break }
          if ($trimmed -like "Date:*") { $date = $trimmed.Substring(5).Trim() }
          elseif ($trimmed -eq "Files:") { $inFiles = $true }
          elseif ($inFiles -and $trimmed) { $blockFiles += $trimmed }
        }
        $removeThis = (-not $FixDate) -or ($date -eq $FixDate)
        if ($removeThis) {
          foreach ($file in $blockFiles) { [void]$files.Add($file) }
        } else {
          $remaining.Add("[FIX]$raw")
        }
      }
    } else {
      $inFiles = $false
      foreach ($line in ($content -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "Files:") { $inFiles = $true; continue }
        if ($inFiles -and $trimmed) { [void]$files.Add($trimmed) }
      }
    }

    Write-State $unfixStatusPath @{ status = "removing"; progress = ("Removing {0} files..." -f $files.Count) }
    $deleted = 0
    foreach ($file in $files) {
      $target = Get-SafeTargetPath -BasePath $InstallPath -RelativePath ($file -replace "/", "\")
      if ($target -and (Test-Path -LiteralPath $target)) {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        $deleted += 1
      }
    }

    if ($remaining.Count -gt 0) {
      ($remaining -join "`n`n---`n`n") | Set-Content -LiteralPath $logPath -Encoding UTF8
    } else {
      Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    }

    Write-State $unfixStatusPath @{ status = "done"; success = $true; filesRemoved = $deleted }
  } catch {
    Write-State $unfixStatusPath @{ status = "failed"; success = $false; error = $_.Exception.Message }
  }
}

if ($Mode -eq "Apply") {
  Invoke-Apply
} else {
  Invoke-Unfix
}
