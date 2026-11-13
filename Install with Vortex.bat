@echo off
title Ai modpack - Vortex installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-VortexInstall.ps1" %*
if errorlevel 1 pause
