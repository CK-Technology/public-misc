# winUp.ps1
# Windows Update via PSWindowsUpdate with transcript logging.

$LogPath = "C:\ProgramData\CKTECH-Scripts\UpdateLog_$(Get-Date -Format 'yyyyMMdd_HHmm').txt"

Start-Transcript -Path $LogPath -Append

try {
    Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process -Force

    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false
    Install-Module -Name PSWindowsUpdate -Force -Confirm:$false
    Import-Module -Name PSWindowsUpdate

    $Updates = Get-WUList -MicrosoftUpdate
    Write-Output "Available Updates: $($Updates.Count)"
    $Updates | ForEach-Object { Write-Output "Title: $($_.Title) - KB: $($_.KB)" }

    if ($Updates.Count -gt 0) {
        Write-Output "Installing updates..."
        $InstalledUpdates = Install-WindowsUpdate -AcceptAll -IgnoreUserInput -IgnoreReboot | Out-String
        Write-Output "Installed Updates: $InstalledUpdates"
    } else {
        Write-Output "No updates available."
    }
}
catch {
    Write-Output "An error occurred: $_"
}
finally {
    Stop-Transcript
}

Set-ExecutionPolicy -ExecutionPolicy Default -Scope Process -Force
