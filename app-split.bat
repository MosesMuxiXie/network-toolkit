@echo off
chcp 65001 >nul
title 双链路分流 - 自检 + 选择软件
echo ==========================================
echo   双链路分流（Wi-Fi + 手机 USB）
echo ==========================================
echo.
echo [第一步] 链路自检
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0split-proxy.ps1" -Probe
if errorlevel 1 (
    echo.
    echo 自检未通过，已取消启动。
    pause
    exit /b 1
)
echo.
echo [第二步] 选择要分流的软件
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app-split.ps1" %*
echo.
pause
