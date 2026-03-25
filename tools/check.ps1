param(
    [string]$GodotExe = "",
    [switch]$SkipJson,
    [switch]$SkipArchitecture,
    [switch]$SkipLeakGuard
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ===========================
# WXAuto 一键快速校验脚本
# ===========================
# 功能：
# 1) 用 Godot headless 启动项目并立即退出，检查脚本加载/场景初始化错误。
# 2) 校验仓库内所有 JSON 文件语法（可通过 -SkipJson 跳过）。
# 3) 校验 Phase 0 架构约束（可通过 -SkipArchitecture 跳过）。
# 4) 校验关键测试无泄漏（可通过 -SkipLeakGuard 跳过）。
#
# 用法示例：
#   powershell -ExecutionPolicy Bypass -File .\tools\check.ps1
#   .\tools\check.ps1 -GodotExe "D:\Godot_v4.6.1\godot.exe"
#   .\tools\check.ps1 -SkipJson
#   .\tools\check.ps1 -SkipArchitecture
#   .\tools\check.ps1 -SkipLeakGuard

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

function Invoke-ArchitectureGuardCheck {
    param([string]$ProjectPath)

    $guardScript = Join-Path $ProjectPath "tools\architecture_guard.ps1"
    if (-not (Test-Path -LiteralPath $guardScript)) {
        throw "未找到架构约束脚本：$guardScript"
    }

    Write-Host "[CHECK] Architecture guard"
    & powershell -ExecutionPolicy Bypass -File $guardScript -Root $ProjectPath
    if (-not $?) {
        throw "架构约束校验失败。"
    }

    Write-Host "[OK] 架构约束校验通过"
}

function Get-LeakGuardTests {
    param([string]$ProjectPath)

    $configPath = Join-Path $ProjectPath "tools\baselines\leak_guard_tests.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "未找到泄漏测试清单：$configPath"
    }

    $raw = Get-Content -LiteralPath $configPath -Raw
    $json = $raw | ConvertFrom-Json

    if ($null -eq $json.tests) {
        throw "泄漏测试清单缺少 tests 字段：$configPath"
    }

    $tests = New-Object System.Collections.Generic.List[string]
    foreach ($item in $json.tests) {
        $testPath = [string]$item
        if ([string]::IsNullOrWhiteSpace($testPath)) {
            continue
        }
        $tests.Add($testPath)
    }

    if ($tests.Count -eq 0) {
        throw "泄漏测试清单为空：$configPath"
    }

    return $tests
}

function Test-LeakLine {
    param([string]$Line)

    if ($Line -match "WARNING:\s+ObjectDB instances leaked at exit") {
        return $true
    }
    if ($Line -match "WARNING:\s+\d+\s+RIDs of type\s+""[^""]+""\s+were leaked\.") {
        return $true
    }
    if ($Line -match "ERROR:\s+\d+\s+resources still in use at exit") {
        return $true
    }
    if ($Line -match "^Leaked instance:") {
        return $true
    }
    return $false
}

function Invoke-LeakGuardCheck {
    param(
        [string]$ExePath,
        [string]$ProjectPath
    )

    Write-Host "[CHECK] Leak guard"
    $tests = Get-LeakGuardTests -ProjectPath $ProjectPath
    $failures = New-Object System.Collections.Generic.List[object]

    foreach ($test in $tests) {
        $testAbs = Join-Path $ProjectPath $test
        if (-not (Test-Path -LiteralPath $testAbs)) {
            throw "泄漏测试脚本不存在：$test"
        }

        Write-Host ("[LEAK] running {0}" -f $test)
        $rawOutput = @(& $ExePath --headless --verbose --path $ProjectPath --script $testAbs 2>&1)
        $exitCode = $LASTEXITCODE

        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $rawOutput) {
            $line = [string]$entry
            $lines.Add($line)
            Write-Host $line
        }

        if ($exitCode -ne 0) {
            throw ("泄漏门禁测试执行失败：{0} (exit={1})" -f $test, $exitCode)
        }

        $matched = New-Object System.Collections.Generic.List[string]
        foreach ($line in $lines) {
            if (Test-LeakLine -Line $line) {
                $matched.Add($line)
            }
        }

        if ($matched.Count -gt 0) {
            $failures.Add([PSCustomObject]@{
                test = $test
                leak_lines = @($matched)
            })
        }
    }

    if ($failures.Count -gt 0) {
        Write-Host "[LEAK] 检测到泄漏，详情如下："
        foreach ($failure in $failures) {
            Write-Host ("  - {0}" -f $failure.test)
            foreach ($line in $failure.leak_lines) {
                Write-Host ("    {0}" -f $line)
            }
        }
        throw "泄漏门禁校验失败。"
    }

    Write-Host "[OK] 泄漏门禁校验通过"
}

$resolvedGodot = Resolve-GodotExecutable -ManualPath $GodotExe
Invoke-GodotHeadlessCheck -ExePath $resolvedGodot -ProjectPath $projectRoot

if (-not $SkipJson) {
    Invoke-JsonSyntaxCheck -ProjectPath $projectRoot
}

if (-not $SkipArchitecture) {
    Invoke-ArchitectureGuardCheck -ProjectPath $projectRoot
}

if (-not $SkipLeakGuard) {
    Invoke-LeakGuardCheck -ExePath $resolvedGodot -ProjectPath $projectRoot
}

Write-Host "[DONE] 全部校验完成"
