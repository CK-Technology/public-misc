# powerfabUp.ps1
# Copies Tekla PowerFab update installer locally and runs it.

$SourcePath = "\\Iron-file1\it\Applications\Tekla-Powerfab\2026\TeklaPowerFab2026SP1.exe"
$DestDir    = "C:\Users\Public\Documents\Tekla\Tekla Powerfab\Update"
$DestFile   = Join-Path $DestDir "TeklaPowerFab2026SP1.exe"

Write-Host "Creating update directory..."
New-Item -ItemType Directory -Path $DestDir -Force | Out-Null

Write-Host "Copying Tekla PowerFab update..."
Copy-Item -Path $SourcePath -Destination $DestFile -Force

if (!(Test-Path $DestFile)) {
    Write-Error "Copy failed. Installer not found at $DestFile"
    exit 1
}

Write-Host "Launching Tekla PowerFab update (silent)..."
Start-Process -FilePath $DestFile -ArgumentList "/S" -Wait

Write-Host "Tekla PowerFab update completed."
exit 0
