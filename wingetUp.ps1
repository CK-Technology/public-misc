# wingetUp.ps1
# Upgrades all winget packages silently with transcript logging.

$LogPath = "C:\ProgramData\CKTECH-Scripts\winget.txt"

Start-Transcript -Path $LogPath -Append

try {
    # Locate winget executable
    $WingetPath = ((gci "C:\Program Files\WindowsApps" -Recurse -File | Where-Object { ($_.fullname -match 'C:\\Program Files\\WindowsApps\\Microsoft.DesktopAppInstaller_' -and $_.name -match 'winget.exe') } | sort fullname -descending | %{$_.FullName}) -Split [Environment]::NewLine)[0]

    Write-Output "Winget Path: $WingetPath"
    & "$WingetPath" --info

    # Update source
    & "$WingetPath" source update

    # Upgrade all packages
    $WingetOutput = & "$WingetPath" upgrade --all --silent --accept-source-agreements | Out-String
    Write-Output "Winget Output: $WingetOutput"
}
catch {
    Write-Output "An error occurred: $_"
}
finally {
    Stop-Transcript
}
