@echo off
REM cursor-lark-bridge launcher shim -> fb.ps1 (located alongside this file)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fb.ps1" %*
