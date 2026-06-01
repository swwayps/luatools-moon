param(
  [Parameter(Mandatory=$true)][string]$Action,
  [Parameter(Mandatory=$true)][string]$PluginRoot,
  [Parameter(Mandatory=$true)][string]$SteamPath,
  [string]$AppId = "",
  [string]$OutputPath = ""
)

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

function Write-Json {
  param([object]$Value)
  $json = $Value | ConvertTo-Json -Depth 12 -Compress
  if ($OutputPath) {
    $outDir = Split-Path -Parent $OutputPath
    if ($outDir) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $json | Set-Content -LiteralPath $OutputPath -Encoding UTF8
  } else {
    $json
  }
}

function Read-Text {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return "" }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 } catch { return "" }
}

function Ensure-AppListCache {
  $path = Join-Path $PluginRoot "backend\temp_dl\all-appids.json"
  if (Test-Path -LiteralPath $path) { return $path }

  try {
    $dir = Split-Path -Parent $path
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Invoke-WebRequest -Uri "https://applist.morrenus.xyz/" -OutFile $path -MaximumRedirection 10 -TimeoutSec 300 -Headers @{ "User-Agent" = "discord(dot)gg/luatools" }
    return $path
  } catch {
    try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch {}
    return ""
  }
}

function Get-VdfValue {
  param([string]$Text, [string]$Key)
  $match = [regex]::Match($Text, '"' + [regex]::Escape($Key) + '"\s+"([^"]*)"')
  if ($match.Success) { return $match.Groups[1].Value -replace "\\\\", "\" }
  return ""
}

function Get-SteamLibraries {
  $libraries = New-Object System.Collections.Generic.List[string]
  if ($SteamPath -and (Test-Path -LiteralPath $SteamPath)) {
    $libraries.Add($SteamPath)
  }

  $libraryVdf = Join-Path $SteamPath "config\libraryfolders.vdf"
  $text = Read-Text $libraryVdf
  foreach ($match in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
    $path = $match.Groups[1].Value -replace "\\\\", "\"
    if ($path -and (Test-Path -LiteralPath $path) -and -not $libraries.Contains($path)) {
      $libraries.Add($path)
    }
  }

  return $libraries
}

function Get-AppManifestInfo {
  param([string]$ManifestPath)
  $text = Read-Text $ManifestPath
  return @{
    name = Get-VdfValue $text "name"
    installDir = Get-VdfValue $text "installdir"
  }
}

function Get-GameInstallPath {
  $appidText = [string]$AppId
  if (-not ($appidText -match '^\d+$')) {
    Write-Json @{ success = $false; error = "Invalid appid" }
    return
  }

  foreach ($lib in Get-SteamLibraries) {
    $manifest = Join-Path $lib ("steamapps\appmanifest_{0}.acf" -f $appidText)
    if (-not (Test-Path -LiteralPath $manifest)) { continue }

    $info = Get-AppManifestInfo $manifest
    if (-not $info.installDir) {
      Write-Json @{ success = $false; error = "Install directory not found" }
      return
    }

    $installPath = Join-Path $lib ("steamapps\common\{0}" -f $info.installDir)
    if (-not (Test-Path -LiteralPath $installPath)) {
      Write-Json @{ success = $false; error = "Game directory not found" }
      return
    }

    Write-Json @{
      success = $true
      installPath = $installPath
      installDir = $info.installDir
      libraryPath = $lib
      path = $installPath
    }
    return
  }

  Write-Json @{ success = $false; error = "menu.error.notInstalled" }
}

function Get-LoadedAppNames {
  $names = @{}
  $loadedPath = Join-Path $PluginRoot "backend\loadedappids.txt"
  if (Test-Path -LiteralPath $loadedPath) {
    foreach ($line in Get-Content -LiteralPath $loadedPath) {
      if ($line -match '^(\d+):(.*)$') {
        $names[$matches[1]] = $matches[2].Trim()
      }
    }
  }
  return $names
}

function Get-InstalledLuaScripts {
  if (-not $SteamPath) {
    Write-Json @{ success = $false; error = "Could not find Steam installation path" }
    return
  }

  $targetDir = Join-Path $SteamPath "config\stplug-in"
  if (-not (Test-Path -LiteralPath $targetDir)) {
    Write-Json @{ success = $true; scripts = @() }
    return
  }

  $names = Get-LoadedAppNames
  $appListPath = Ensure-AppListCache
  $appListText = if ($appListPath) { Read-Text $appListPath } else { "" }
  $scripts = @()
  foreach ($file in Get-ChildItem -LiteralPath $targetDir -File) {
    if ($file.Name -notmatch '^(\d+)\.lua(\.disabled)?$') { continue }
    $id = $matches[1]
    $isDisabled = [bool]$matches[2]
    $gameName = $names[$id]
    if (-not $gameName -and $appListText) {
      $nameMatch = [regex]::Match($appListText, '"appid"\s*:\s*' + [regex]::Escape($id) + '\s*,\s*"name"\s*:\s*"((?:\\"|[^"])*)"')
      if ($nameMatch.Success) {
        $gameName = $nameMatch.Groups[1].Value -replace '\\"', '"'
      }
    }
    if (-not $gameName) { $gameName = "Unknown Game ($id)" }
    $scripts += @{
      appid = [int]$id
      gameName = $gameName
      filename = $file.Name
      isDisabled = $isDisabled
      fileSize = $file.Length
      modifiedDate = $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
      path = $file.FullName
    }
  }

  $scripts = @($scripts | Sort-Object appid)
  Write-Json @{ success = $true; scripts = $scripts }
}

function Parse-FixLog {
  param(
    [string]$LogPath,
    [int]$AppIdValue,
    [string]$GameName,
    [string]$InstallPath
  )

  $content = Read-Text $LogPath
  $blocks = @()
  if ($content -match '\[FIX\]') {
    foreach ($raw in ($content -split '\[FIX\]')) {
      if (-not $raw.Trim()) { continue }
      $blocks += $raw
    }
  } else {
    $blocks += $content
  }

  $items = @()
  foreach ($block in $blocks) {
    $item = @{
      appid = $AppIdValue
      gameName = $GameName
      installPath = $InstallPath
      date = ""
      fixType = ""
      downloadUrl = ""
      filesCount = 0
      files = @()
    }

    $inFiles = $false
    foreach ($line in ($block -split "`r?`n")) {
      $trimmed = $line.Trim()
      if ($trimmed -eq "[/FIX]" -or $trimmed -eq "---") { break }
      if ($trimmed -like "Date:*") { $item.date = $trimmed.Substring(5).Trim(); continue }
      if ($trimmed -like "Game:*") {
        $loggedName = $trimmed.Substring(5).Trim()
        if ($loggedName) { $item.gameName = $loggedName }
        continue
      }
      if ($trimmed -like "Fix Type:*") { $item.fixType = $trimmed.Substring(9).Trim(); continue }
      if ($trimmed -like "Download URL:*") { $item.downloadUrl = $trimmed.Substring(13).Trim(); continue }
      if ($trimmed -eq "Files:") { $inFiles = $true; continue }
      if ($inFiles -and $trimmed) { $item.files += $trimmed }
    }

    $item.filesCount = @($item.files).Count
    if ($item.date) { $items += $item }
  }

  return $items
}

function Get-InstalledFixes {
  if (-not $SteamPath) {
    Write-Json @{ success = $false; error = "Could not find Steam installation path" }
    return
  }

  $fixes = @()
  foreach ($lib in Get-SteamLibraries) {
    $steamApps = Join-Path $lib "steamapps"
    if (-not (Test-Path -LiteralPath $steamApps)) { continue }
    foreach ($manifest in Get-ChildItem -LiteralPath $steamApps -File -Filter "appmanifest_*.acf") {
      if ($manifest.Name -notmatch '^appmanifest_(\d+)\.acf$') { continue }
      $appidValue = [int]$matches[1]
      $info = Get-AppManifestInfo $manifest.FullName
      if (-not $info.installDir) { continue }
      $installPath = Join-Path $lib ("steamapps\common\{0}" -f $info.installDir)
      if (-not (Test-Path -LiteralPath $installPath)) { continue }
      $logPath = Join-Path $installPath ("luatools-fix-log-{0}.log" -f $appidValue)
      if (-not (Test-Path -LiteralPath $logPath)) { continue }
      $gameName = $info.name
      if (-not $gameName) { $gameName = "Unknown Game ($appidValue)" }
      $fixes += Parse-FixLog -LogPath $logPath -AppIdValue $appidValue -GameName $gameName -InstallPath $installPath
    }
  }

  Write-Json @{ success = $true; fixes = @($fixes) }
}

switch ($Action) {
  "GetGameInstallPath" { Get-GameInstallPath; break }
  "GetInstalledLuaScripts" { Get-InstalledLuaScripts; break }
  "GetInstalledFixes" { Get-InstalledFixes; break }
  default { Write-Json @{ success = $false; error = "Unknown action" } }
}
