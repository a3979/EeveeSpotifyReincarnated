@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0upload-spotify-922-ipa.ps1"
if errorlevel 1 (
    echo.
    echo The IPA upload helper reported an error.
    pause
    exit /b 1
)
endlocal
