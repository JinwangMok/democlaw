@echo off
:: =============================================================================
:: stop.bat -- Stop and clean up the entire DemoClaw stack (Windows)
::
:: Removes containers and network. Model weights are preserved.
::
:: Usage:
::   scripts\stop.bat
:: =============================================================================
setlocal enabledelayedexpansion

echo [stop] ========================================
echo [stop]   DemoClaw Stack -- Teardown
echo [stop] ========================================

:: Detect runtime
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
    echo [stop] ERROR: No container runtime found. >&2
    exit /b 1
)
echo [stop] Runtime: %RUNTIME%

:: Remove containers (openclaw first, then llamacpp)
for %%c in (democlaw-openclaw democlaw-llamacpp) do (
    %RUNTIME% container inspect "%%c" >nul 2>&1
    if !errorlevel! equ 0 (
        echo [stop] Removing container '%%c' ...
        %RUNTIME% rm -f "%%c" >nul 2>&1
    ) else (
        echo [stop] Container '%%c' not found -- skipping.
    )
)

:: Remove network
%RUNTIME% network inspect democlaw-net >nul 2>&1
if !errorlevel! equ 0 (
    echo [stop] Removing network 'democlaw-net' ...
    %RUNTIME% network rm democlaw-net >nul 2>&1
) else (
    echo [stop] Network 'democlaw-net' not found -- skipping.
)

echo [stop] Done. (Model weights preserved at %%USERPROFILE%%\.cache\democlaw\models)

endlocal
