# enableDefender.ps1
# Re-enables Windows Defender real-time protection and related services.

# Enable real-time monitoring
Set-MpPreference -DisableRealtimeMonitoring $false

# Enable IOAV Protection
Set-MpPreference -DisableIOAVProtection $false

# Create registry key for Real-Time Protection
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Name "Real-Time Protection" -Force

# Set registry values for Real-Time Protection
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableBehaviorMonitoring" -Value 0 -PropertyType DWORD -Force
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableOnAccessProtection" -Value 0 -PropertyType DWORD -Force
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableScanOnRealtimeEnable" -Value 0 -PropertyType DWORD -Force

# Ensure AntiSpyware is enabled
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Name "DisableAntiSpyware" -Value 0 -PropertyType DWORD -Force

# Start Defender services
Start-Service WinDefend
Start-Service WdNisSvc
