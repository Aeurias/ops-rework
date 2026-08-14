@echo off
title AzerothCore - STOP FOR MAINTENANCE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\azeroth\ops-rework\Stop-AzerothCoreMaintenance.ps1"
echo.
pause
