@echo off
:: =============================================================================
:: approve-device.bat -- Manually approve pending device pairing requests
::
:: Interactive script:
::   1. Lists pending pairing requests
::   2. Lets user select a device
::   3. Asks approve or cancel
::   4. Executes the chosen action
::
:: Usage:
::   scripts\windows\approve-device.bat
:: =============================================================================
setlocal EnableDelayedExpansion

echo.
echo ========================================
echo   OpenClaw Device Pairing Manager
echo ========================================
echo.

:: ---------------------------------------------------------------------------
:: Detect runtime
:: ---------------------------------------------------------------------------
set "RT="
where docker >nul 2>&1 && set "RT=docker"
if not defined RT where podman >nul 2>&1 && set "RT=podman"
if not defined RT (
    echo ERROR: No container runtime found.
    exit /b 1
)

:: ---------------------------------------------------------------------------
:: Check OpenClaw container is running
:: ---------------------------------------------------------------------------
%RT% container inspect democlaw-openclaw >nul 2>&1
if errorlevel 1 (
    echo ERROR: Container 'democlaw-openclaw' is not running.
    echo Start it first with: scripts\windows\start.bat
    exit /b 1
)

:: ---------------------------------------------------------------------------
:: Get pending devices as JSON
:: ---------------------------------------------------------------------------
set "TMPJSON=%TEMP%\democlaw-devices-%RANDOM%.json"
%RT% exec democlaw-openclaw openclaw devices list --json >"%TMPJSON%" 2>nul

:: Count pending devices
set "PENDING_COUNT=0"
for /f %%n in ('%RT% exec democlaw-openclaw openclaw devices list --json 2^>nul ^| findstr /c:"requestId"') do (
    set /a "PENDING_COUNT=PENDING_COUNT+1"
)

:: ---------------------------------------------------------------------------
:: Show paired devices summary
:: ---------------------------------------------------------------------------
echo --- Currently Paired Devices ---
set "PAIRED_IDX=0"
for /f "delims=" %%l in ('%RT% exec democlaw-openclaw openclaw devices list --json 2^>nul') do set "JSON_LINE=%%l"
%RT% exec democlaw-openclaw sh -c "openclaw devices list --json 2>/dev/null | jq -r '.paired[] | \"  [\(.platform)] \(.clientMode) - \(.deviceId[0:16])... (IP: \(.remoteIp // \"n/a\"))\"'" 2>nul
echo.

:: ---------------------------------------------------------------------------
:: Get and show pending devices
:: ---------------------------------------------------------------------------
echo --- Pending Pairing Requests ---

:: Extract pending requests into numbered list
set "PCOUNT=0"
for /f "delims=" %%l in ('%RT% exec democlaw-openclaw sh -c "openclaw devices list --json 2>/dev/null | jq -r '.pending[] | \"\(.requestId)|\(.deviceId[0:16])|\(.platform // \"unknown\")|\(.clientMode // \"unknown\")|\(.remoteIp // \"n/a\")\"'" 2^>nul') do (
    set /a "PCOUNT=PCOUNT+1"
    set "DEVICE_!PCOUNT!=%%l"
    for /f "tokens=1,2,3,4,5 delims=|" %%a in ("%%l") do (
        echo   [!PCOUNT!] ID: %%a
        echo       Device: %%b...  Platform: %%c  Mode: %%d  IP: %%e
    )
)

if %PCOUNT% equ 0 (
    echo   No pending pairing requests found.
    echo.
    echo   If you just clicked "Connect" in the browser,
    echo   wait a moment and run this script again.
    del /f /q "%TMPJSON%" >nul 2>&1
    exit /b 0
)

echo.
echo ----------------------------------------

:: ---------------------------------------------------------------------------
:: User selection
:: ---------------------------------------------------------------------------
if %PCOUNT% equ 1 (
    set "SELECTION=1"
    echo Only one pending request found. Auto-selected [1].
) else (
    echo Enter device number to manage [1-%PCOUNT%], or 'a' for all, or 'q' to quit:
    set /p "SELECTION="
)

if /i "!SELECTION!"=="q" (
    echo Cancelled.
    del /f /q "%TMPJSON%" >nul 2>&1
    exit /b 0
)

:: ---------------------------------------------------------------------------
:: Approve or Cancel
:: ---------------------------------------------------------------------------
echo.
echo Choose action:
echo   [1] Approve  - Allow this device to connect
echo   [2] Cancel   - Deny and quit
echo.
set /p "ACTION=Your choice [1/2]: "

if "!ACTION!"=="2" (
    echo Cancelled. No devices were approved.
    del /f /q "%TMPJSON%" >nul 2>&1
    exit /b 0
)

if not "!ACTION!"=="1" (
    echo Invalid choice. Exiting.
    del /f /q "%TMPJSON%" >nul 2>&1
    exit /b 1
)

:: ---------------------------------------------------------------------------
:: Execute approval
:: ---------------------------------------------------------------------------
if /i "!SELECTION!"=="a" (
    echo Approving ALL pending devices ...
    for /L %%i in (1,1,%PCOUNT%) do (
        for /f "tokens=1 delims=|" %%r in ("!DEVICE_%%i!") do (
            echo   Approving %%r ...
            %RT% exec democlaw-openclaw openclaw devices approve "%%r" >nul 2>&1
            if errorlevel 1 (
                echo   WARNING: Failed to approve %%r
            ) else (
                echo   Approved.
            )
        )
    )
) else (
    set "IDX=!SELECTION!"
    if not defined DEVICE_!IDX! (
        echo Invalid selection. Exiting.
        del /f /q "%TMPJSON%" >nul 2>&1
        exit /b 1
    )
    for /f "tokens=1 delims=|" %%r in ("!DEVICE_%IDX%!") do (
        echo Approving %%r ...
        %RT% exec democlaw-openclaw openclaw devices approve "%%r" 2>&1
        if errorlevel 1 (
            echo WARNING: Failed to approve device.
        ) else (
            echo Device approved successfully!
        )
    )
)

echo.
echo Done. Refresh the browser to connect.
del /f /q "%TMPJSON%" >nul 2>&1
