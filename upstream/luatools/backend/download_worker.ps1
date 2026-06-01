param(
  [Parameter(Mandatory=$true)][string]$AppId,
  [Parameter(Mandatory=$true)][string]$Url,
  [Parameter(Mandatory=$true)][string]$ApiName,
  [Parameter(Mandatory=$true)][string]$PluginRoot,
  [Parameter(Mandatory=$true)][string]$SteamPath
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$backend = Join-Path $PluginRoot "backend"
$temp = Join-Path $backend "temp_dl"
$statusPath = Join-Path $temp ("status_{0}.json" -f $AppId)
$zipPath = Join-Path $temp ("{0}.zip" -f $AppId)
$extractPath = Join-Path $temp ("extract_{0}" -f $AppId)
$targetDir = Join-Path $SteamPath "config\stplug-in"
$depotcache = Join-Path $SteamPath "depotcache"
$loadedAppsPath = Join-Path $backend "loadedappids.txt"
$appidLogPath = Join-Path $backend "appidlogs.txt"

function Write-State {
  param([hashtable]$State)
  New-Item -ItemType Directory -Path $temp -Force | Out-Null
  $payload = @{} + $State
  $payload.updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  $payload | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $statusPath -Encoding UTF8
}

function Invoke-SteamConfigRescanProbe {
  param(
    [Parameter(Mandatory=$true)][string]$InstalledLuaPath
  )

  $now = Get-Date
  foreach ($path in @($InstalledLuaPath, $targetDir, $depotcache, (Join-Path $SteamPath "config"))) {
    try {
      if (Test-Path -LiteralPath $path) {
        (Get-Item -LiteralPath $path -Force).LastWriteTime = $now
      }
    } catch {}
  }

  foreach ($dir in @($targetDir, $depotcache, (Join-Path $SteamPath "config"))) {
    try {
      if (Test-Path -LiteralPath $dir) {
        $probe = Join-Path $dir (".luatools_rescan_probe_{0}.tmp" -f $AppId)
        Set-Content -LiteralPath $probe -Value $now.ToString("o") -Encoding ASCII
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
      }
    } catch {}
  }
}

function Get-DlcCountFromLua {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$BaseAppId
  )

  try {
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $match = [regex]::Match($text, '(?im)^\s*--\s*Total\s+DLCs\s*:\s*(\d+)\s*$')
    if ($match.Success -and [int]$match.Groups[1].Value -gt 0) {
      return [int]$match.Groups[1].Value
    }

    $depotIds = @{}
    foreach ($manifestMatch in [regex]::Matches($text, '(?im)^\s*setManifestid\s*\(\s*(\d+)')) {
      $depotIds[$manifestMatch.Groups[1].Value] = $true
    }

    $dlcIds = @{}
    foreach ($appidMatch in [regex]::Matches($text, '(?im)^\s*addappid\s*\(\s*(\d+)\s*(?:,|\))')) {
      $id = $appidMatch.Groups[1].Value
      if ($id -ne $BaseAppId -and -not $depotIds.ContainsKey($id)) {
        $dlcIds[$id] = $true
      }
    }

    return $dlcIds.Count
  } catch {}

  return 0
}

function Clear-DownloadArtifacts {
  foreach ($path in @($zipPath, $extractPath)) {
    try {
      if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
      }
    } catch {}
  }
}

try {
  New-Item -ItemType Directory -Path $temp -Force | Out-Null
  New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
  New-Item -ItemType Directory -Path $depotcache -Force | Out-Null

  Write-State @{ status = "downloading"; currentApi = $ApiName; bytesRead = 0; totalBytes = 0 }

  Invoke-WebRequest -Uri $Url -OutFile $zipPath -MaximumRedirection 10 -Headers @{ "User-Agent" = "discord(dot)gg/luatools" }
  $zipInfo = Get-Item -LiteralPath $zipPath
  Write-State @{ status = "processing"; currentApi = $ApiName; bytesRead = $zipInfo.Length; totalBytes = $zipInfo.Length }

  Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
  Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

  $manifestCount = 0
  Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter "*.manifest" | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $depotcache $_.Name) -Force
    $manifestCount += 1
  }

  $luaFile = Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter "$AppId.lua" | Select-Object -First 1
  if (-not $luaFile) {
    $luaFile = Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter "*.lua" | Select-Object -First 1
  }
  if (-not $luaFile) {
    throw "No lua file found in downloaded archive"
  }

  $dlcCount = Get-DlcCountFromLua -Path $luaFile.FullName -BaseAppId $AppId
  $installedLuaPath = Join-Path $targetDir ("{0}.lua" -f $AppId)
  Copy-Item -LiteralPath $luaFile.FullName -Destination $installedLuaPath -Force
  Invoke-SteamConfigRescanProbe -InstalledLuaPath $installedLuaPath

  $name = "UNKNOWN ($AppId)"
  $lines = @()
  if (Test-Path -LiteralPath $loadedAppsPath) {
    $lines = Get-Content -LiteralPath $loadedAppsPath | Where-Object { $_ -notlike "$AppId`:*" }
  }
  $lines += "$AppId`:$name"
  $lines | Set-Content -LiteralPath $loadedAppsPath -Encoding UTF8

  $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  Add-Content -LiteralPath $appidLogPath -Value "[ADDED - $ApiName] $AppId - $name - $stamp"

  Write-State @{
    status = "done"
    success = $true
    currentApi = $ApiName
    api = $ApiName
    bytesRead = $zipInfo.Length
    totalBytes = $zipInfo.Length
    manifests = $manifestCount
    dlcs = $dlcCount
  }
} catch {
  Write-State @{
    status = "failed"
    success = $false
    currentApi = $ApiName
    error = $_.Exception.Message
  }
} finally {
  Clear-DownloadArtifacts
}
