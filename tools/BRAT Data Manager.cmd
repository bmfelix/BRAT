@echo off
rem Double-click to open BRAT Data Manager (wipe / pull Warcraft Logs data per spec).
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0BRAT-Data-Manager.ps1"
