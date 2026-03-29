Param(
    [string]$PythonExe = "python"
)

$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$EditorDir = Join-Path $ProjectRoot "tools\mod_data_editor"
$SpecPath = Join-Path $EditorDir "WXAutoModDataEditor.spec"
$DistPath = Join-Path $EditorDir "dist"
$WorkPath = Join-Path $EditorDir "build"
$IndexPath = Join-Path $EditorDir "index.html"
$StylesPath = Join-Path $EditorDir "styles.css"
$AppJsPath = Join-Path $EditorDir "app.js"
$ServerPath = Join-Path $EditorDir "server.py"

if (Test-Path $SpecPath) {
    Remove-Item -Force $SpecPath
}

Set-Location $ProjectRoot

Write-Host "[1/3] Install/Upgrade PyInstaller..."
& $PythonExe -m pip install -U pyinstaller pystray pillow
if ($LASTEXITCODE -ne 0) {
    throw "pip install failed with exit code $LASTEXITCODE"
}

Write-Host "[2/3] Build EXE..."
& $PythonExe -m PyInstaller `
    --noconfirm `
    --clean `
    --name WXAutoModDataEditor `
    --onedir `
    --noconsole `
    --distpath $DistPath `
    --workpath $WorkPath `
    --specpath $EditorDir `
    --add-data "${IndexPath};mod_data_editor_static" `
    --add-data "${StylesPath};mod_data_editor_static" `
    --add-data "${AppJsPath};mod_data_editor_static" `
    $ServerPath
if ($LASTEXITCODE -ne 0) {
    throw "PyInstaller failed with exit code $LASTEXITCODE"
}

$ExePath = Join-Path $DistPath "WXAutoModDataEditor\WXAutoModDataEditor.exe"
if (-not (Test-Path $ExePath)) {
    throw "Build completed but exe not found: $ExePath"
}

Write-Host "[3/3] Done"
Write-Host "Output dir: $DistPath\WXAutoModDataEditor"
Write-Host "Exe path : $ExePath"
