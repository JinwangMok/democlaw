@echo off
:: =============================================================================
:: stop.bat -- Stop and clean up the entire DemoClaw stack
:: =============================================================================

echo [stop] ========================================
echo [stop]   DemoClaw Stack -- Teardown
echo [stop] ========================================

:: Detect runtime
set "RT="
where docker >nul 2>&1 && set "RT=docker"
if not defined RT where podman >nul 2>&1 && set "RT=podman"
if not defined RT (
    echo [stop] ERROR: No container runtime found.
    exit /b 1
)
echo [stop] Runtime: %RT%

:: Remove openclaw container
%RT% container inspect democlaw-openclaw >nul 2>&1 && (
    echo [stop] Removing container 'democlaw-openclaw' ...
    %RT% rm -f democlaw-openclaw >nul 2>&1
) || echo [stop] Container 'democlaw-openclaw' not found -- skipping.

:: Remove llamacpp container
%RT% container inspect democlaw-llamacpp >nul 2>&1 && (
    echo [stop] Removing container 'democlaw-llamacpp' ...
    %RT% rm -f democlaw-llamacpp >nul 2>&1
) || echo [stop] Container 'democlaw-llamacpp' not found -- skipping.

:: Remove network
%RT% network inspect democlaw-net >nul 2>&1 && (
    echo [stop] Removing network 'democlaw-net' ...
    %RT% network rm democlaw-net >nul 2>&1
) || echo [stop] Network 'democlaw-net' not found -- skipping.

echo [stop] Done.
