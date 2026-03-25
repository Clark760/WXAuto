param(
    [switch]$ReportOnly,
    [switch]$WriteBaseline,
    [string]$Root = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = if ([string]::IsNullOrWhiteSpace($Root)) {
    (Resolve-Path (Join-Path $scriptDir "..")).Path
} else {
    (Resolve-Path $Root).Path
}

$baselinePath = Join-Path $projectRoot "tools/baselines/architecture_guard_baseline.json"
$exceptionsPath = Join-Path $projectRoot "tools/baselines/architecture_guard_exceptions.json"
$lineSoftLimit = 600
$lineHardLimit = 900
$sceneFirstPatternText = '(?<![A-Za-z0-9_])(?:Control|Label|Button|LinkButton|LineEdit|ProgressBar|RichTextLabel|ColorRect|PanelContainer|VBoxContainer|HBoxContainer|GridContainer|MarginContainer|ScrollContainer|TextureRect)\s*\.\s*new\s*\('
$rootLookupPatternText = '_get_root_node\s*\('
$dynamicCallPatternText = '\bcall\s*\('
$sceneFirstPattern = [regex]::new($sceneFirstPatternText)
$rootLookupPattern = [regex]::new($rootLookupPatternText)
$dynamicCallPattern = [regex]::new($dynamicCallPatternText)

function ConvertTo-NativeObject {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $hash = [ordered]@{}
        foreach ($prop in $Value.PSObject.Properties) {
            $hash[$prop.Name] = ConvertTo-NativeObject $prop.Value
        }
        return $hash
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $hash = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $hash[[string]$key] = ConvertTo-NativeObject $Value[$key]
        }
        return $hash
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += @(ConvertTo-NativeObject $item)
        }
        return $items
    }

    return $Value
}

function ConvertTo-RepoRelativePath {
    param(
        [string]$Path,
        [string]$RootPath
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $normalizedRoot = $RootPath.TrimEnd('\', '/')
    if ($resolvedPath.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $resolvedPath.Substring($normalizedRoot.Length).TrimStart('\', '/')
    } else {
        $relative = $resolvedPath
    }
    return ($relative -replace '\\', '/')
}

function Test-PathPrefix {
    param(
        [string]$RelativePath,
        [string[]]$Prefixes
    )

    foreach ($prefix in $Prefixes) {
        $normalizedPrefix = ($prefix -replace '\\', '/').TrimEnd('/')
        if ([string]::IsNullOrWhiteSpace($normalizedPrefix)) {
            continue
        }
        if ($RelativePath.StartsWith($normalizedPrefix + "/", [System.StringComparison]::OrdinalIgnoreCase) -or `
            $RelativePath.Equals($normalizedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-ScriptFiles {
    param(
        [string]$RootPath,
        [string[]]$IncludePrefixes = @(),
        [string[]]$ExcludePrefixes = @()
    )

    $scriptsRoot = Join-Path $RootPath "scripts"
    if (-not (Test-Path -LiteralPath $scriptsRoot)) {
        return @()
    }

    $items = @()
    $files = Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File -Filter *.gd | Sort-Object FullName
    foreach ($file in $files) {
        $relative = ConvertTo-RepoRelativePath -Path $file.FullName -RootPath $RootPath
        if ($IncludePrefixes.Count -gt 0 -and -not (Test-PathPrefix -RelativePath $relative -Prefixes $IncludePrefixes)) {
            continue
        }
        if ($ExcludePrefixes.Count -gt 0 -and (Test-PathPrefix -RelativePath $relative -Prefixes $ExcludePrefixes)) {
            continue
        }
        $items += @([pscustomobject]@{
                path = $file.FullName
                relative_path = $relative
            })
    }
    return $items
}

function Load-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return ConvertTo-NativeObject (ConvertFrom-Json $raw)
}

function Get-ExceptionLookup {
    param([string]$Path)

    $data = Load-JsonFile -Path $Path
    if ($null -eq $data) {
        return @{}
    }

    $items = @()
    if ($data.Contains("exceptions")) {
        $items = @($data["exceptions"])
    } elseif ($data -is [System.Collections.IEnumerable]) {
        $items = @($data)
    }

    $lookup = @{}
    foreach ($item in $items) {
        foreach ($required in @("rule", "path", "reason", "expires_phase")) {
            if (-not $item.Contains($required) -or [string]::IsNullOrWhiteSpace([string]$item[$required])) {
                throw "豁免文件缺少必填字段 '$required'。"
            }
        }

        $rule = [string]$item["rule"]
        $relativePath = ([string]$item["path"]).Trim() -replace '\\', '/'
        if (-not $lookup.ContainsKey($rule)) {
            $lookup[$rule] = @{}
        }
        $lookup[$rule][$relativePath] = $true
    }

    return $lookup
}

function Test-IsException {
    param(
        [hashtable]$Lookup,
        [string]$Rule,
        [string]$RelativePath
    )

    if (-not $Lookup.ContainsKey($Rule)) {
        return $false
    }
    return $Lookup[$Rule].ContainsKey($RelativePath)
}

function Get-FileLineCount {
    param([string]$Path)
    return (Get-Content -LiteralPath $Path | Measure-Object -Line).Lines
}

function Get-LineCountScan {
    param([object[]]$Files)

    $tracked = [ordered]@{}
    $overHard = 0
    $overSoft = 0

    foreach ($file in $Files) {
        $lineCount = Get-FileLineCount -Path $file.path
        if ($lineCount -gt $lineSoftLimit) {
            $tracked[$file.relative_path] = $lineCount
            if ($lineCount -gt $lineHardLimit) {
                $overHard++
            } else {
                $overSoft++
            }
        }
    }

    return [ordered]@{
        files = $tracked
        total_files = $tracked.Count
        over_900_files = $overHard
        between_601_and_900_files = $overSoft
    }
}

function Get-PatternScan {
    param(
        [object[]]$Files,
        [regex]$Pattern,
        [string]$RuleName,
        [hashtable]$Exceptions
    )

    $tracked = [ordered]@{}
    $details = [ordered]@{}
    $total = 0

    foreach ($file in $Files) {
        if (Test-IsException -Lookup $Exceptions -Rule $RuleName -RelativePath $file.relative_path) {
            continue
        }

        $count = 0
        $lineEntries = @()
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $file.path) {
            $lineNumber++
            $matches = $Pattern.Matches($line)
            if ($matches.Count -le 0) {
                continue
            }

            $count++
            $total++
            $lineEntries += @([pscustomobject]@{
                    line = $lineNumber
                    count = $matches.Count
                    text = $line.Trim()
                })
        }

        if ($count -gt 0) {
            $tracked[$file.relative_path] = $count
            $details[$file.relative_path] = $lineEntries
        }
    }

    return [ordered]@{
        files = $tracked
        details = $details
        total_occurrences = $total
        total_files = $tracked.Count
    }
}

function Get-BaselinePayload {
    param(
        [hashtable]$LineCount,
        [hashtable]$SceneFirstUi,
        [hashtable]$RootLookup,
        [hashtable]$DynamicCall
    )

    return [ordered]@{
        version = 1
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        rules = [ordered]@{
            file_length = [ordered]@{
                soft_limit = $lineSoftLimit
                hard_limit = $lineHardLimit
                files = $LineCount.files
                summary = [ordered]@{
                    total_files = $LineCount.total_files
                    over_900_files = $LineCount.over_900_files
                    between_601_and_900_files = $LineCount.between_601_and_900_files
                }
            }
            scene_first_ui = [ordered]@{
                scope = @("scripts/main", "scripts/ui", "scripts/board")
                patterns = @(
                    "Control.new",
                    "Label.new",
                    "Button.new",
                    "LinkButton.new",
                    "LineEdit.new",
                    "ProgressBar.new",
                    "RichTextLabel.new",
                    "ColorRect.new",
                    "PanelContainer.new",
                    "VBoxContainer.new",
                    "HBoxContainer.new",
                    "GridContainer.new",
                    "MarginContainer.new",
                    "ScrollContainer.new",
                    "TextureRect.new"
                )
                files = $SceneFirstUi.files
                total_occurrences = $SceneFirstUi.total_occurrences
                total_files = $SceneFirstUi.total_files
            }
            root_lookup = [ordered]@{
                pattern = "_get_root_node("
                files = $RootLookup.files
                total_occurrences = $RootLookup.total_occurrences
                total_files = $RootLookup.total_files
            }
            dynamic_call = [ordered]@{
                pattern = "call("
                files = $DynamicCall.files
                total_occurrences = $DynamicCall.total_occurrences
                total_files = $DynamicCall.total_files
            }
        }
    }
}

function Get-BaselineRuleFiles {
    param(
        [hashtable]$Baseline,
        [string]$RuleGroup,
        [string]$SubKey = "files"
    )

    if ($null -eq $Baseline -or -not $Baseline.Contains("rules")) {
        return [ordered]@{}
    }
    if (-not $Baseline["rules"].Contains($RuleGroup)) {
        return [ordered]@{}
    }
    if (-not $Baseline["rules"][$RuleGroup].Contains($SubKey)) {
        return [ordered]@{}
    }

    $files = $Baseline["rules"][$RuleGroup][$SubKey]
    if ($null -eq $files) {
        return [ordered]@{}
    }

    return $files
}

function Format-LineSummary {
    param([object[]]$Entries)

    if ($null -eq $Entries -or $Entries.Count -eq 0) {
        return ""
    }

    $parts = @()
    foreach ($entry in $Entries) {
        $parts += @([string]$entry.line)
    }

    $limit = 18
    if ($parts.Count -gt $limit) {
        return (($parts[0..($limit - 1)] -join ", ") + (", ... +{0} more" -f ($parts.Count - $limit)))
    }
    return ($parts -join ", ")
}

function Write-RuleSummary {
    param(
        [string]$Name,
        [hashtable]$RuleData,
        [switch]$ShowLineDetails
    )

    Write-Host ("[ARCH][{0}] occurrences={1} files={2}" -f $Name, $RuleData.total_occurrences, $RuleData.total_files)
    $pairs = foreach ($key in $RuleData.files.Keys) {
        [pscustomobject]@{
            path = $key
            count = [int]$RuleData.files[$key]
        }
    }
    foreach ($pair in $pairs | Sort-Object `
            @{ Expression = "count"; Descending = $true }, `
            @{ Expression = "path"; Descending = $false }) {
        Write-Host ("  - {0} :: {1}" -f $pair.path, $pair.count)
        if ($ShowLineDetails -and $RuleData.details.Contains($pair.path)) {
            Write-Host ("    lines: {0}" -f (Format-LineSummary -Entries $RuleData.details[$pair.path]))
        }
    }
}

function Write-LineCountSummary {
    param([hashtable]$RuleData)

    Write-Host ("[ARCH][file_length] files>600={0} (>900={1}, 601-900={2})" -f `
            $RuleData.total_files, $RuleData.over_900_files, $RuleData.between_601_and_900_files)

    $pairs = foreach ($key in $RuleData.files.Keys) {
        [pscustomobject]@{
            path = $key
            lines = [int]$RuleData.files[$key]
        }
    }
    foreach ($pair in $pairs | Sort-Object `
            @{ Expression = "lines"; Descending = $true }, `
            @{ Expression = "path"; Descending = $false }) {
        Write-Host ("  - {0} :: {1} lines" -f $pair.path, $pair.lines)
    }
}

function Validate-LineCountRule {
    param(
        [hashtable]$CurrentRule,
        [hashtable]$BaselineRule
    )

    $errors = @()
    foreach ($path in $CurrentRule.files.Keys) {
        $currentCount = [int]$CurrentRule.files[$path]
        if (-not $BaselineRule.Contains($path)) {
            $errors += @("file_length: 新文件或新超限文件 $path 达到 $currentCount 行（阈值 $lineSoftLimit）")
            continue
        }

        $baselineCount = [int]$BaselineRule[$path]
        if ($currentCount -gt $baselineCount) {
            $errors += @("file_length: $path 从 $baselineCount 行增长到 $currentCount 行")
        }
    }
    return $errors
}

function Validate-PatternRule {
    param(
        [string]$RuleName,
        [hashtable]$CurrentRule,
        [hashtable]$BaselineRule,
        [hashtable]$Exceptions
    )

    $errors = @()
    foreach ($path in $CurrentRule.files.Keys) {
        if (Test-IsException -Lookup $Exceptions -Rule $RuleName -RelativePath $path) {
            continue
        }

        $currentCount = [int]$CurrentRule.files[$path]
        if (-not $BaselineRule.Contains($path)) {
            $errors += @("{0}: 新增违规文件 {1}，当前次数 {2}" -f $RuleName, $path, $currentCount)
            continue
        }

        $baselineCount = [int]$BaselineRule[$path]
        if ($currentCount -gt $baselineCount) {
            $errors += @("{0}: {1} 从 {2} 次增长到 {3} 次" -f $RuleName, $path, $baselineCount, $currentCount)
        }
    }
    return $errors
}

$allScripts = Get-ScriptFiles -RootPath $projectRoot -ExcludePrefixes @("scripts/tests")
$sceneFirstScripts = Get-ScriptFiles -RootPath $projectRoot -IncludePrefixes @("scripts/main", "scripts/ui", "scripts/board")
$exceptions = Get-ExceptionLookup -Path $exceptionsPath
$lineCountScan = Get-LineCountScan -Files $allScripts
$sceneFirstScan = Get-PatternScan -Files $sceneFirstScripts -Pattern $sceneFirstPattern -RuleName "scene_first_ui" -Exceptions $exceptions
$rootLookupScan = Get-PatternScan -Files $allScripts -Pattern $rootLookupPattern -RuleName "root_lookup" -Exceptions $exceptions
$dynamicCallScan = Get-PatternScan -Files $allScripts -Pattern $dynamicCallPattern -RuleName "dynamic_call" -Exceptions $exceptions
$baselinePayload = Get-BaselinePayload -LineCount $lineCountScan -SceneFirstUi $sceneFirstScan -RootLookup $rootLookupScan -DynamicCall $dynamicCallScan
$mode = if ($WriteBaseline) { "write-baseline" } elseif ($ReportOnly) { "report-only" } else { "validate" }

Write-Host ("[ARCH] Mode: {0}" -f $mode)
Write-Host ("[ARCH] Root: {0}" -f $projectRoot)
Write-LineCountSummary -RuleData $lineCountScan
Write-RuleSummary -Name "scene_first_ui" -RuleData $sceneFirstScan -ShowLineDetails:($ReportOnly -or $WriteBaseline)
Write-RuleSummary -Name "root_lookup" -RuleData $rootLookupScan -ShowLineDetails:($ReportOnly -or $WriteBaseline)
Write-RuleSummary -Name "dynamic_call" -RuleData $dynamicCallScan -ShowLineDetails:($ReportOnly -or $WriteBaseline)

if ($WriteBaseline) {
    $baselineDir = Split-Path -Parent $baselinePath
    if (-not (Test-Path -LiteralPath $baselineDir)) {
        New-Item -ItemType Directory -Path $baselineDir | Out-Null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $json = $baselinePayload | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($baselinePath, $json, $utf8NoBom)
    Write-Host ("[ARCH] Baseline written: {0}" -f $baselinePath)
    exit 0
}

if ($ReportOnly) {
    exit 0
}

$baselineData = Load-JsonFile -Path $baselinePath
if ($null -eq $baselineData) {
    throw "未找到架构基线文件。请先运行 tools/architecture_guard.ps1 -WriteBaseline。"
}

$baselineLineCount = Get-BaselineRuleFiles -Baseline $baselineData -RuleGroup "file_length"
$baselineSceneFirst = Get-BaselineRuleFiles -Baseline $baselineData -RuleGroup "scene_first_ui"
$baselineRootLookup = Get-BaselineRuleFiles -Baseline $baselineData -RuleGroup "root_lookup"
$baselineDynamicCall = Get-BaselineRuleFiles -Baseline $baselineData -RuleGroup "dynamic_call"

$failures = @()
$failures += @(Validate-LineCountRule -CurrentRule $lineCountScan -BaselineRule $baselineLineCount)
$failures += @(Validate-PatternRule -RuleName "scene_first_ui" -CurrentRule $sceneFirstScan -BaselineRule $baselineSceneFirst -Exceptions $exceptions)
$failures += @(Validate-PatternRule -RuleName "root_lookup" -CurrentRule $rootLookupScan -BaselineRule $baselineRootLookup -Exceptions $exceptions)
$failures += @(Validate-PatternRule -RuleName "dynamic_call" -CurrentRule $dynamicCallScan -BaselineRule $baselineDynamicCall -Exceptions $exceptions)

if ($failures.Count -gt 0) {
    Write-Host "[ARCH] Violations detected:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host ("  - {0}" -f $failure) -ForegroundColor Red
    }

    Write-Host "[ARCH] Failure detail line references:" -ForegroundColor Red
    foreach ($rulePack in @(
            @{ name = "scene_first_ui"; data = $sceneFirstScan },
            @{ name = "root_lookup"; data = $rootLookupScan },
            @{ name = "dynamic_call"; data = $dynamicCallScan }
        )) {
        foreach ($path in $rulePack.data.files.Keys) {
            $baselineFiles = switch ($rulePack.name) {
                "scene_first_ui" { $baselineSceneFirst }
                "root_lookup" { $baselineRootLookup }
                "dynamic_call" { $baselineDynamicCall }
            }

            $isNewViolation = (-not $baselineFiles.Contains($path)) -or ([int]$rulePack.data.files[$path] -gt [int]$baselineFiles[$path])
            if (-not $isNewViolation) {
                continue
            }

            Write-Host ("  - [{0}] {1} :: lines {2}" -f $rulePack.name, $path, (Format-LineSummary -Entries $rulePack.data.details[$path])) -ForegroundColor Red
        }
    }

    exit 1
}

Write-Host "[ARCH] Architecture guard passed"
