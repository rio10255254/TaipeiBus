@echo off
chcp 65001 >nul
set PYTHONUTF8=1
set PYTHONUNBUFFERED=1
cd /d "%~dp0"
runtime\python.exe -X utf8 capture.py
echo.
echo Reports are in the reports folder beside this file.
pause
