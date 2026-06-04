param(
    [string]$Url,
    [Parameter(Mandatory = $true)][string]$DestPath,
    [Parameter(Mandatory = $true)][string]$ExtractDir,
    [string]$StateFile,
    [string]$UserAgent = "discord(dot)gg/luatools"
)

$ErrorActionPreference = 'Stop'

function Update-State($s) {
    if ([string]::IsNullOrWhiteSpace($StateFile)) { return }
    Set-Content -Path $StateFile -Value ("{`"status`":`"" + $s + "`"}")
}

try {
    if (-not [string]::IsNullOrWhiteSpace($Url)) {
        Update-State 'downloading'
        Write-Host "Downloading $Url to $DestPath..."
        Invoke-WebRequest -Uri $Url -OutFile $DestPath -UserAgent $UserAgent -UseBasicParsing
    }
    
    if (-not [string]::IsNullOrWhiteSpace($ExtractDir)) {
        Update-State 'extracting'
        Write-Host "Extracting $DestPath to $ExtractDir..."
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($DestPath)
        foreach ($entry in $zip.Entries) {
            $target = [System.IO.Path]::Combine($ExtractDir, $entry.FullName)
            $dir = [System.IO.Path]::GetDirectoryName($target)
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            if ($entry.Name -ne '') { 
                Write-Host "Extracting $($entry.FullName)..."
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true) 
            }
        }
        $zip.Dispose()
        Update-State 'extracted'
        Write-Host "Extraction complete!"
        Start-Sleep -Seconds 2
    }
    else {
        Update-State 'done'
    }
}
catch {
    Write-Host "ERROR ENCOUNTERED:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    $errLog = [System.IO.Path]::Combine($ExtractDir, "update_error.log")
    Set-Content -Path $errLog -Value $_.Exception.ToString()
    
    if (-not [string]::IsNullOrWhiteSpace($StateFile)) {
        $errMsg = $_.Exception.Message.Replace('\', '\\').Replace('"', '\"')
        Set-Content -Path $StateFile -Value ("{`"status`":`"failed`",`"error`":`"" + $errMsg + "`"}")
    }
    try { Read-Host "Press Enter to exit" } catch {}
    exit 1
}
