@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem Minimal Wazuh installer for XP-class systems that cannot run the modern
rem PowerShell deployment. Stage this file beside the pinned MSI on a read-only
rem domain share and invoke it as a computer startup script.

set "WAZUH_VERSION=4.14.7-1"
set "MANAGER=%~1"
set "GROUPS=%~2"
set "MSI=%~3"

if not defined MANAGER goto :usage
if not defined GROUPS goto :usage
if not defined MSI set "MSI=%~dp0wazuh-agent-%WAZUH_VERSION%.msi"

set "LOGDIR=%ALLUSERSPROFILE%\CKTech\logs"
set "LOGFILE=%LOGDIR%\wazuh_legacy_deploy.log"
set "MSILOG=%LOGDIR%\wazuh_legacy_msi.log"

if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>&1
call :log Starting Wazuh legacy deployment.

sc.exe query WazuhSvc >nul 2>&1
if not errorlevel 1 goto :service_exists

if not exist "%MSI%" (
    call :log FAIL: MSI not found at %MSI%
    exit /b 2
)

call :log Installing Wazuh Agent %WAZUH_VERSION%.
msiexec.exe /i "%MSI%" /qn /norestart /L*v "%MSILOG%" WAZUH_MANAGER="%MANAGER%" WAZUH_AGENT_GROUP="%GROUPS%" WAZUH_AGENT_NAME="%COMPUTERNAME%"
set "MSIRC=%ERRORLEVEL%"
if "%MSIRC%"=="0" goto :start_service
if "%MSIRC%"=="3010" goto :start_service
call :log FAIL: msiexec returned %MSIRC%.
exit /b %MSIRC%

:service_exists
call :log WazuhSvc already exists; group membership must be checked on the manager.

:start_service
sc.exe config WazuhSvc start= auto >nul 2>&1
sc.exe start WazuhSvc >nul 2>&1
sc.exe query WazuhSvc | findstr /C:"RUNNING" >nul 2>&1
if errorlevel 1 (
    call :log FAIL: WazuhSvc is not running.
    exit /b 3
)

call :log WazuhSvc is running. Deployment complete.
if "%MSIRC%"=="3010" exit /b 3010
exit /b 0

:usage
echo Usage: %~nx0 MANAGER GROUPS [MSI_PATH]
echo Example: %~nx0 wazuh.example.com default,CLIENT
exit /b 64

:log
>>"%LOGFILE%" echo %DATE% %TIME% %*
exit /b 0
