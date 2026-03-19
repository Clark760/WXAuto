param(
    [string]$GodotExe = "",
    [switch]$SkipJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ===========================
# WXAuto 一键快速校验脚本
# ===========================
# 功能：
# 1) 用 Godot headless 启动项目并立即退出，检查脚本加载/场景初始化错误。
# 2) 校验仓库内所有 JSON 文件语法（可通过 -SkipJson 跳过）。
#
# 用法示例：
#   powershell -ExecutionPolicy Bypass -File .\tools\check.ps1
#   .\tools\check.ps1 -GodotExe "D:\Godot_v4.6.1\godot.exe"
#   .\tools\check.ps1 -SkipJson

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = (Resolve-Path (Join-Path $scriptDir "..")).Path

function Resolve-GodotExecutable {
    param([string]$ManualPath)

    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($ManualPath)) {
        $candidates.Add($ManualPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GODOT_EXE)) {
        $candidates.Add($env:GODOT_EXE)
    }

    $godotCmd = Get-Command godot.exe -ErrorAction SilentlyContinue
    if ($null -ne $godotCmd) {
        $candidates.Add($godotCmd.Source)
    }

    $godotConsoleCmd = Get-Command godot_console.exe -ErrorAction SilentlyContinue
    if ($null -ne $godotConsoleCmd) {
        $candidates.Add($godotConsoleCmd.Source)
    }

    # 常见手动解压目录兜底
    $candidates.Add("D:\Godot_v4.6.1\godot.exe")
    $candidates.Add("D:\Godot_v4.6.1\godot_console.exe")

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "未找到 Godot 可执行文件。请传入 -GodotExe 或设置 GODOT_EXE 环境变量。"
}

function Invoke-GodotHeadlessCheck {
    param(
        [string]$ExePath,
        [string]$ProjectPath
    )

    Write-Host "[CHECK] Godot: $ExePath"
    Write-Host "[CHECK] Project: $ProjectPath"

    & $ExePath --headless --path $ProjectPath --quit
    if (-not $?) {
        throw "Godot headless 校验失败。"
    }

    Write-Host "[OK] Godot headless 启动校验通过"
}

function Invoke-JsonSyntaxCheck {
    param([string]$ProjectPath)

    $pyCommand = Get-Command py -ErrorAction SilentlyContinue
    if ($null -eq $pyCommand) {
        throw "未找到 py 命令，无法执行 JSON 校验。"
    }

    $env:WXAUTO_PROJECT_ROOT = $ProjectPath
    $pythonScript = @'
import json
import os
from pathlib import Path

root = Path(os.environ["WXAUTO_PROJECT_ROOT"])
ok = 0
errors = []

for path in root.rglob("*.json"):
    try:
        json.loads(path.read_text(encoding="utf-8"))
        ok += 1
    except Exception as exc:
        errors.append((str(path), str(exc)))

print(f"JSON_OK={ok}")
if errors:
    print("JSON_ERRORS=")
    for p, e in errors:
        print(p)
        print(e)
    raise SystemExit(1)
'@

    $pythonScript | py -3 -
    if (-not $?) {
        throw "JSON 语法校验失败。"
    }

    Write-Host "[OK] JSON 语法校验通过"
}

$resolvedGodot = Resolve-GodotExecutable -ManualPath $GodotExe
Invoke-GodotHeadlessCheck -ExePath $resolvedGodot -ProjectPath $projectRoot

if (-not $SkipJson) {
    Invoke-JsonSyntaxCheck -ProjectPath $projectRoot
}

Write-Host "[DONE] 全部校验完成"
