@echo off
setlocal enabledelayedexpansion
:: =============================================================================
:: device-approve.bat -- List and approve pending devices on the OpenClaw gateway
::
:: Queries the OpenClaw container for pending device pairing requests
:: and lets you approve them from the host.
::
:: Usage:
::   scripts\device-approve.bat                            Interactive: list + select
::   scripts\device-approve.bat --list                     List pending devices only
::   scripts\device-approve.bat <id>                       Approve a specific device by ID
::   scripts\device-approve.bat --pairing <platform> <code>  Approve a pairing code (e.g. discord)
:: =============================================================================

if not defined OPENCLAW_CONTAINER set "OPENCLAW_CONTAINER=democlaw-openclaw"

:: ---------------------------------------------------------------------------
:: Detect container runtime
:: ---------------------------------------------------------------------------
set "RUNTIME="
if defined CONTAINER_RUNTIME (
    where "%CONTAINER_RUNTIME%" >nul 2>&1
    if !errorlevel! equ 0 set "RUNTIME=%CONTAINER_RUNTIME%"
)
if not defined RUNTIME (
    where docker >nul 2>&1
    if !errorlevel! equ 0 (
        set "RUNTIME=docker"
    ) else (
        where podman >nul 2>&1
        if !errorlevel! equ 0 (
            set "RUNTIME=podman"
        )
    )
)
if not defined RUNTIME (
    echo ERROR: No container runtime found. >&2
    exit /b 1
)

:: ---------------------------------------------------------------------------
:: Verify OpenClaw container is running
:: ---------------------------------------------------------------------------
%RUNTIME% container inspect %OPENCLAW_CONTAINER% >nul 2>&1
if !errorlevel! neq 0 (
    echo ERROR: Container '%OPENCLAW_CONTAINER%' is not running. >&2
    echo Start the stack first: scripts\start.bat >&2
    exit /b 1
)

:: ---------------------------------------------------------------------------
:: Parse arguments
:: ---------------------------------------------------------------------------
if "%~1"=="--pairing" goto :do_pairing
if "%~1"=="-p" goto :do_pairing
if "%~1"=="--list" goto :do_list
if "%~1"=="-l" goto :do_list
if "%~1"=="--help" goto :do_help
if "%~1"=="-h" goto :do_help
if not "%~1"=="" goto :do_approve_direct

:: ---------------------------------------------------------------------------
:: Interactive mode
:: ---------------------------------------------------------------------------
echo Fetching pending devices from %OPENCLAW_CONTAINER% ...
echo.
%RUNTIME% exec %OPENCLAW_CONTAINER% openclaw devices list 2>nul
echo.

:: Collect UUIDs into numbered list
set "COUNT=0"
for /f "tokens=*" %%L in ('%RUNTIME% exec %OPENCLAW_CONTAINER% openclaw devices list 2^>nul') do (
    for %%W in (%%L) do (
        echo %%W | findstr /r "[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-" >nul 2>&1
        if !errorlevel! equ 0 (
            set /a "COUNT+=1"
            set "ID_!COUNT!=%%W"
            echo   [!COUNT!] %%W
        )
    )
)

if %COUNT% equ 0 (
    echo No pending devices found.
    exit /b 0
)

echo   [a] Approve all
echo   [q] Quit
echo.
set /p "CHOICE=Select device to approve (number/a/q): "

if /i "!CHOICE!"=="q" (
    echo Cancelled.
    exit /b 0
)

if /i "!CHOICE!"=="a" (
    for /l %%i in (1,1,%COUNT%) do (
        echo Approving !ID_%%i! ...
        %RUNTIME% exec %OPENCLAW_CONTAINER% openclaw devices approve "!ID_%%i!" 2>nul
        if !errorlevel! equ 0 (echo   Approved.) else (echo   Failed.)
    )
    exit /b 0
)

:: Approve by number
set "SEL_ID=!ID_%CHOICE%!"
if not defined SEL_ID (
    echo Invalid selection. >&2
    exit /b 1
)
echo Approving !SEL_ID! ...
%RUNTIME% exec %OPENCLAW_CONTAINER% openclaw devices approve "!SEL_ID!" 2>nul
if !errorlevel! equ 0 (echo Approved.) else (echo Failed.)
exit /b 0

:do_list
echo Pending devices on %OPENCLAW_CONTAINER%:
echo.
%RUNTIME% exec %OPENCLAW_CONTAINER% openclaw devices list 2>nul
exit /b 0

:do_pairing
if "%~2"=="" (
    echo Usage: %~nx0 --pairing ^<platform^> ^<code^> >&2
    echo   e.g.: %~nx0 --pairing discord 5GVUDXE4 >&2
    exit /b 1
)
if "%~3"=="" (
    echo Usage: %~nx0 --pairing ^<platform^> ^<code^> >&2
    echo   e.g.: %~nx0 --pairing discord 5GVUDXE4 >&2
    exit /b 1
)
echo Approving pairing code %~3 for %~2 ...
%RUNTIME% exec %OPENCLAW_CONTAINER% openclaw pairing approve "%~2" "%~3" 2>nul
if !errorlevel! equ 0 (echo Approved.) else (echo Failed.)
exit /b 0

:do_help
echo Usage: %~nx0 [--list ^| --pairing ^<platform^> ^<code^> ^| --help ^| ^<device-id^>]
echo.
echo   (no args)                          Interactive: list pending devices and select one to approve
echo   --list, -l                         List pending devices only
echo   --pairing, -p ^<platform^> ^<code^>   Approve a pairing code (e.g. discord)
echo   ^<device-id^>                        Approve a specific device by ID
echo   --help, -h                         Show this help
exit /b 0

:do_approve_direct
echo Approving device %~1 ...
%RUNTIME% exec %OPENCLAW_CONTAINER% openclaw devices approve "%~1" 2>nul
if !errorlevel! equ 0 (echo Approved.) else (echo Failed.)
exit /b 0
