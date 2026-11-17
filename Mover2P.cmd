@echo off
REM Runs Mover2P without changing the machine execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Mover2P.ps1" %*
