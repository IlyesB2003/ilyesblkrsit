@echo off
setlocal
cd /d "%~dp0"
if exist "wizard.hta" (
    start "" mshta.exe "%~dp0wizard.hta"
) else (
    echo wizard.hta was not found next to this file.
    pause
)
endlocal
