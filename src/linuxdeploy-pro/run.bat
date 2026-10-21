@echo off
rem ============================================================
rem LinuxDeploy-Pro build/install launcher.
rem This file is pure ASCII on purpose: cmd mis-parses batch
rem files containing non-ASCII text depending on the console
rem codepage. All logic and Chinese messages live in run.ps1
rem (UTF-8 with BOM).
rem Usage:
rem   run.bat            build + reinstall + launch
rem   run.bat --clear    also wipe app data before installing
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" %*
exit /b %errorlevel%
