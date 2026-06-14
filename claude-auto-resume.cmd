@echo off
REM claude-auto-resume.cmd — Windows CMD wrapper
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-auto-resume.ps1" %*
