@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%\..\.."

set "EDITOR_DIR=%CD%\tools\mod_data_editor"
set "SPEC_FILE=%EDITOR_DIR%\WXAutoModDataEditor.spec"
set "DIST_DIR=%EDITOR_DIR%\dist"
set "WORK_DIR=%EDITOR_DIR%\build"
set "SERVER_FILE=%EDITOR_DIR%\server.py"

if exist "%SPEC_FILE%" del /f /q "%SPEC_FILE%"

echo [1/3] Install/Upgrade PyInstaller...
python -m pip install -U pyinstaller pystray pillow
if errorlevel 1 goto :fail

echo [2/3] Build EXE...
python -m PyInstaller ^
  --noconfirm ^
  --clean ^
  --name WXAutoModDataEditor ^
  --onedir ^
  --noconsole ^
  --distpath "%DIST_DIR%" ^
  --workpath "%WORK_DIR%" ^
  --specpath "%EDITOR_DIR%" ^
  --add-data "%EDITOR_DIR%\index.html;mod_data_editor_static" ^
  --add-data "%EDITOR_DIR%\styles.css;mod_data_editor_static" ^
  --add-data "%EDITOR_DIR%\app.js;mod_data_editor_static" ^
  "%SERVER_FILE%"
if errorlevel 1 goto :fail

if not exist "%DIST_DIR%\WXAutoModDataEditor\WXAutoModDataEditor.exe" goto :fail_no_exe

echo [3/3] Done.
echo Output: %DIST_DIR%\WXAutoModDataEditor\WXAutoModDataEditor.exe
popd
exit /b 0

:fail_no_exe
echo Build finished but exe not found.
popd
exit /b 1

:fail
echo Build failed.
popd
exit /b 1
