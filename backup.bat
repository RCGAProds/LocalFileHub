@echo off
setlocal enabledelayedexpansion
title Vaultdrop - Backup

set "PROYECTO_DIR=%~dp0"
set "BACKUP_BASE=%~dp0backups"

:: Date and time for backup folder name
for /f "tokens=1-3 delims=/" %%a in ("%date%") do (
    set "DIA=%%a"
    set "MES=%%b"
    set "ANO=%%c"
)
for /f "tokens=1-2 delims=:" %%a in ("%time: =0%") do (
    set "HORA=%%a"
    set "MIN=%%b"
)
set "TIMESTAMP=%ANO%-%MES%-%DIA%_%HORA%-%MIN%"
set "DESTINO=%BACKUP_BASE%\backup_%TIMESTAMP%"

echo.
echo  =========================================
echo   Vaultdrop - Backup
echo  =========================================
echo.

:: Check that uploads folder exists
if not exist "%PROYECTO_DIR%uploads" (
    echo  [ERROR] Could not find the uploads folder at:
    echo          %PROYECTO_DIR%
    echo.
    echo  Make sure backup.bat is in the same folder as server.py
    echo.
    pause
    exit /b 1
)

if not exist "%PROYECTO_DIR%database.db" (
    echo  [WARNING] database.db not found.
    echo            Only the uploads folder will be backed up.
    echo.
)

:: Create destination folder
if not exist "%BACKUP_BASE%" mkdir "%BACKUP_BASE%"
mkdir "%DESTINO%"

echo  Starting backup...
echo  Destination: %DESTINO%
echo.

:: Copy uploads
echo  [1/2] Copying files (uploads/)...
xcopy "%PROYECTO_DIR%uploads" "%DESTINO%\uploads" /E /I /H /Q >nul 2>&1
if %errorlevel% neq 0 (
    echo  [ERROR] Failed to copy uploads folder
    pause
    exit /b 1
)
echo        OK

:: Copy database
if exist "%PROYECTO_DIR%database.db" (
    echo  [2/2] Copying database...
    copy "%PROYECTO_DIR%database.db" "%DESTINO%\database.db" >nul 2>&1
    if %errorlevel% neq 0 (
        echo  [ERROR] Failed to copy database.db
        echo         Make sure the server is stopped before running a backup.
        pause
        exit /b 1
    )
    echo        OK
) else (
    echo  [2/2] database.db not found, skipped.
)

:: Count copied files
set "SIZE=0"
for /r "%DESTINO%" %%f in (*) do set /a SIZE+=1

:: Keep only the 10 most recent backups
echo.
echo  Removing old backups (keeping 10 most recent)...
set COUNT=0
for /f "delims=" %%d in ('dir "%BACKUP_BASE%" /ad /b /o-n 2^>nul') do (
    set /a COUNT+=1
    if !COUNT! gtr 10 (
        echo  Removing: %%d
        rd /s /q "%BACKUP_BASE%\%%d"
    )
)

:: Summary
echo.
echo  =========================================
echo   Backup completed successfully
echo  -----------------------------------------
echo   Date:      %DIA%/%MES%/%ANO% %HORA%:%MIN%
echo   Files:     %SIZE%
echo   Location:  %DESTINO%
echo  =========================================
echo.
pause
