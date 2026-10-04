@echo off
echo Starting Medartis AI Hub Installation...
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0Install-MedartisAIHub.ps1"
echo.
pause
