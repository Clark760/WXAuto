param(
    [switch]$ReportOnly,
    [switch]$WriteBaseline,
    [string]$Root = ""
)

# NOTE: Keep this script encoded as UTF-8 with BOM for Windows PowerShell 5.1 compatibility.
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
$readabilityCommentCoverageThreshold = 0.10
$readabilityCommentCoverageMinCodeLines = 20
$readabilityLongFileLineThreshold = 200
$readabilityBlankLineThreshold = 0.08
$readabilityLineLengthLimit = 120
$readabilityFunctionLineLimit = 80
$readabilityFunctionCommentCoverageThreshold = 0.80
$readabilityFunctionCommentCoverageMinFunctions = 3
$readabilityNamedCommentBlockLimit = 6
$singleLineStatementPatternText = '^\s*(?:func\b.*\)\s*(?:->\s*[^:]+)?\s*:\s*\S+|if\b.+:\s*\S+|elif\b.+:\s*\S+|else\s*:\s*\S+|for\b.+:\s*\S+|while\b.+:\s*\S+|match\b.+:\s*\S+)'
$chineseCharPatternText = '[一-龥]'
$sceneFirstPattern = [regex]::new($sceneFirstPatternText)
$rootLookupPattern = [regex]::new($rootLookupPatternText)
$dynamicCallPattern = [regex]::new($dynamicCallPatternText)
$singleLineStatementPattern = [regex]::new($singleLineStatementPatternText)
$chineseCharPattern = [regex]::new($chineseCharPatternText)

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

function Get-SafeCount {
    param([object]$Value)

    if ($null -eq $Value) {
        return 0
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return $Value.Keys.Count
    }

    if ($Value -is [System.Collections.ICollection]) {
        return $Value.Count
    }

    return @($Value).Count
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

function Get-ChangedScriptFiles {
    param(
        [string]$RootPath,
        [string[]]$ExcludePrefixes = @()
    )

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $gitCmd) {
        return @()
    }

    $relativePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    $restoreNativeErrorPreference = $false
    $previousNativeErrorPreference = $false

    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
        $restoreNativeErrorPreference = $true
        $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }

    Push-Location $RootPath
    try {
        $diffGroups = @()
        $baseRef = [string]$env:ARCH_GUARD_BASE_REF

        if (-not [string]::IsNullOrWhiteSpace($baseRef)) {
            $mergeBaseOutput = @(& git -c core.autocrlf=false -c core.safecrlf=false merge-base $baseRef HEAD 2>$null)
            $diffRange = if ($LASTEXITCODE -eq 0 -and $mergeBaseOutput.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$mergeBaseOutput[0])) {
                ("{0}...HEAD" -f ([string]$mergeBaseOutput[0]).Trim())
            } else {
                ("{0}...HEAD" -f $baseRef.Trim())
            }

            $diffGroups += ,(@(& git -c core.autocrlf=false -c core.safecrlf=false diff --name-only --diff-filter=ACMR $diffRange -- scripts 2>$null))
            $diffGroups += ,(@(& git -c core.autocrlf=false -c core.safecrlf=false ls-files --others --exclude-standard -- scripts 2>$null))
        } else {
            $diffGroups += ,(@(& git -c core.autocrlf=false -c core.safecrlf=false diff --name-only --diff-filter=ACMR HEAD -- scripts 2>$null))
            $diffGroups += ,(@(& git -c core.autocrlf=false -c core.safecrlf=false diff --cached --name-only --diff-filter=ACMR HEAD -- scripts 2>$null))
            $diffGroups += ,(@(& git -c core.autocrlf=false -c core.safecrlf=false ls-files --others --exclude-standard -- scripts 2>$null))
        }

        foreach ($group in $diffGroups) {
            foreach ($entry in $group) {
                $relativePath = ([string]$entry).Trim() -replace '\\', '/'
                if ([string]::IsNullOrWhiteSpace($relativePath)) {
                    continue
                }
                if (-not $relativePath.EndsWith(".gd", [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }
                if ($ExcludePrefixes.Count -gt 0 -and (Test-PathPrefix -RelativePath $relativePath -Prefixes $ExcludePrefixes)) {
                    continue
                }
                $relativePaths.Add($relativePath) | Out-Null
            }
        }
    } finally {
        Pop-Location
        if ($restoreNativeErrorPreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
        }
    }

    $items = @()
    foreach ($relativePath in ($relativePaths | Sort-Object)) {
        $absolutePath = Join-Path $RootPath ($relativePath -replace '/', '\')
        if (-not (Test-Path -LiteralPath $absolutePath)) {
            continue
        }

        $items += @([pscustomobject]@{
                path = (Resolve-Path -LiteralPath $absolutePath).Path
                relative_path = $relativePath
            })
    }

    return $items
}

function Load-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    # Windows PowerShell 5.1 默认会按 ANSI 读取无 BOM JSON。
    # 基线和例外表包含中文 reason，必须显式按 UTF-8 读取。
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
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
    return (Get-Content -LiteralPath $Path -Encoding UTF8 | Measure-Object -Line).Lines
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
        foreach ($line in Get-Content -LiteralPath $file.path -Encoding UTF8) {
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

function Get-LineIndentWidth {
    param([string]$Line)

    $expanded = $Line -replace "`t", "    "
    return ($expanded.Length - $expanded.TrimStart().Length)
}

function Get-FunctionLengthViolations {
    param([string[]]$Lines)

    $violations = New-Object System.Collections.Generic.List[object]
    $currentFunction = $null

    for ($index = 0; $index -lt $Lines.Count; $index++) {
        $line = [string]$Lines[$index]
        $trimmed = $line.Trim()
        $indentWidth = Get-LineIndentWidth -Line $line
        $startsFunction = $trimmed -match '^func\b'

        if ($startsFunction) {
            if ($null -ne $currentFunction -and $currentFunction.body_lines -gt $readabilityFunctionLineLimit) {
                $violations.Add([pscustomobject]@{
                        line = $currentFunction.start_line
                        rule = "function_length"
                        text = ("函数体 {0} 行，超过 {1} 行上限" -f $currentFunction.body_lines, $readabilityFunctionLineLimit)
                    })
            }

            $currentFunction = [ordered]@{
                start_line = $index + 1
                indent = $indentWidth
                body_lines = 0
            }
            continue
        }

        if ($null -eq $currentFunction) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        if ($indentWidth -le $currentFunction.indent -and -not $trimmed.StartsWith("#")) {
            if ($currentFunction.body_lines -gt $readabilityFunctionLineLimit) {
                $violations.Add([pscustomobject]@{
                        line = $currentFunction.start_line
                        rule = "function_length"
                        text = ("函数体 {0} 行，超过 {1} 行上限" -f $currentFunction.body_lines, $readabilityFunctionLineLimit)
                    })
            }
            $currentFunction = $null
            continue
        }

        if ($indentWidth -gt $currentFunction.indent -and -not $trimmed.StartsWith("#")) {
            $currentFunction.body_lines++
        }
    }

    if ($null -ne $currentFunction -and $currentFunction.body_lines -gt $readabilityFunctionLineLimit) {
        $violations.Add([pscustomobject]@{
                line = $currentFunction.start_line
                rule = "function_length"
                text = ("函数体 {0} 行，超过 {1} 行上限" -f $currentFunction.body_lines, $readabilityFunctionLineLimit)
            })
    }

    return @($violations.ToArray())
}

function Get-FunctionCommentCoverageResult {
    param([string[]]$Lines)

    $violations = New-Object System.Collections.Generic.List[object]
    $functionCount = 0
    $documentedCount = 0

    for ($index = 0; $index -lt $Lines.Count; $index++) {
        $trimmed = ([string]$Lines[$index]).Trim()
        if (-not ($trimmed -match '^func\b')) {
            continue
        }

        $functionCount++
        $hasComment = $false

        for ($lookback = $index - 1; $lookback -ge 0 -and $lookback -ge ($index - 3); $lookback--) {
            $prevTrimmed = ([string]$Lines[$lookback]).Trim()
            if ([string]::IsNullOrWhiteSpace($prevTrimmed)) {
                continue
            }
            if ($prevTrimmed.StartsWith("#")) {
                if ($chineseCharPattern.IsMatch($prevTrimmed)) {
                    $hasComment = $true
                }
                continue
            }
            break
        }

        if ($hasComment) {
            $documentedCount++
            continue
        }

        $violations.Add([pscustomobject]@{
                line = $index + 1
                rule = "function_comment"
                text = "函数缺少紧邻的中文说明注释，请把职责或参数口径写在函数旁边"
            })
    }

    $coverage = if ($functionCount -eq 0) { 1.0 } else { $documentedCount / [double]$functionCount }
    if ($functionCount -ge $readabilityFunctionCommentCoverageMinFunctions -and `
        $coverage -lt $readabilityFunctionCommentCoverageThreshold) {
        $violations.Add([pscustomobject]@{
                line = 0
                rule = "function_comment_coverage"
                text = ("函数注释覆盖率 {0:P1}，低于 {1:P0} 要求" -f `
                        $coverage, $readabilityFunctionCommentCoverageThreshold)
            })
    }

    return [ordered]@{
        function_count = $functionCount
        documented_function_count = $documentedCount
        function_comment_coverage = $coverage
        violations = @($violations.ToArray())
    }
}

function Get-NamedCommentBlockViolations {
    param([string[]]$Lines)

    $violations = New-Object System.Collections.Generic.List[object]

    for ($index = 0; $index -lt $Lines.Count; $index++) {
        $trimmed = ([string]$Lines[$index]).Trim()
        $match = [regex]::Match($trimmed, '^#\s*(文件说明|维护约束|维护提示|[^\r\n#]{0,40}附录)\s*[:：]?\s*$')
        if (-not $match.Success) {
            continue
        }

        $blockName = $match.Groups[1].Value
        $blockLines = 1
        for ($next = $index + 1; $next -lt $Lines.Count; $next++) {
            $nextTrimmed = ([string]$Lines[$next]).Trim()
            if (-not $nextTrimmed.StartsWith("#")) {
                break
            }
            $blockLines++
        }

        if ($blockLines -le $readabilityNamedCommentBlockLimit) {
            continue
        }

        $violations.Add([pscustomobject]@{
                line = $index + 1
                rule = "named_comment_block"
                text = ("{0} 注释块 {1} 行，超过 {2} 行上限；请把说明拆到函数、关键变量和复杂分支旁边" -f `
                        $blockName, $blockLines, $readabilityNamedCommentBlockLimit)
            })
    }

    return @($violations.ToArray())
}

function Get-ReadabilityScan {
    param(
        [object[]]$Files,
        [hashtable]$Exceptions
    )

    $tracked = [ordered]@{}
    $details = [ordered]@{}
    $metrics = [ordered]@{}
    $total = 0

    foreach ($file in $Files) {
        if (Test-IsException -Lookup $Exceptions -Rule "readability_guard" -RelativePath $file.relative_path) {
            continue
        }

        # 可读性扫描必须显式按 UTF-8 读取脚本，避免 Windows PowerShell 默认编码把中文注释读坏。
        $lines = @([string[]](Get-Content -LiteralPath $file.path -Encoding UTF8))
        $lineEntries = New-Object System.Collections.Generic.List[object]
        $blankLines = 0
        $codeLines = 0
        $chineseCommentLines = 0

        for ($index = 0; $index -lt $lines.Count; $index++) {
            $line = [string]$lines[$index]
            $trimmed = $line.Trim()

            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                $blankLines++
                continue
            }

            $commentIndex = $line.IndexOf("#")
            if ($commentIndex -ge 0) {
                $commentText = $line.Substring($commentIndex + 1)
                if ($chineseCharPattern.IsMatch($commentText)) {
                    $chineseCommentLines++
                }
            }

            if ($trimmed.StartsWith("#")) {
                continue
            }

            $codeLines++

            if ($line.Length -gt $readabilityLineLengthLimit) {
                $lineEntries.Add([pscustomobject]@{
                        line = $index + 1
                        rule = "line_length"
                        text = ("单行长度 {0}，超过 {1} 字符上限" -f $line.Length, $readabilityLineLengthLimit)
                    })
                $total++
            }

            if ($singleLineStatementPattern.IsMatch($line)) {
                $lineEntries.Add([pscustomobject]@{
                        line = $index + 1
                        rule = "single_line_statement"
                        text = "禁止单行函数体或单行控制流，请展开为多行结构"
                    })
                $total++
            }
        }

        foreach ($violation in (Get-FunctionLengthViolations -Lines $lines)) {
            $lineEntries.Add($violation)
            $total++
        }

        $functionCommentResult = Get-FunctionCommentCoverageResult -Lines $lines
        foreach ($violation in $functionCommentResult.violations) {
            $lineEntries.Add($violation)
            $total++
        }

        foreach ($violation in (Get-NamedCommentBlockViolations -Lines $lines)) {
            $lineEntries.Add($violation)
            $total++
        }

        $blankLineRatio = if ($lines.Count -eq 0) { 0.0 } else { $blankLines / [double]$lines.Count }
        if ($lines.Count -ge $readabilityLongFileLineThreshold -and $blankLineRatio -lt $readabilityBlankLineThreshold) {
            $lineEntries.Add([pscustomobject]@{
                    line = 0
                    rule = "blank_line_ratio"
                    text = ("空行占比 {0:P1}，低于 {1:P0} 要求" -f $blankLineRatio, $readabilityBlankLineThreshold)
                })
            $total++
        }

        $commentCoverage = if ($codeLines -eq 0) { 0.0 } else { $chineseCommentLines / [double]$codeLines }
        if ($codeLines -ge $readabilityCommentCoverageMinCodeLines -and $commentCoverage -lt $readabilityCommentCoverageThreshold) {
            $lineEntries.Add([pscustomobject]@{
                    line = 0
                    rule = "chinese_comment_ratio"
                    text = ("中文注释占比 {0:P1}，低于 {1:P0} 要求" -f $commentCoverage, $readabilityCommentCoverageThreshold)
                })
            $total++
        }

        $metrics[$file.relative_path] = [ordered]@{
            total_lines = $lines.Count
            blank_lines = $blankLines
            blank_line_ratio = $blankLineRatio
            code_lines = $codeLines
            chinese_comment_lines = $chineseCommentLines
            chinese_comment_ratio = $commentCoverage
            function_count = $functionCommentResult.function_count
            documented_function_count = $functionCommentResult.documented_function_count
            function_comment_coverage = $functionCommentResult.function_comment_coverage
        }

        if ($lineEntries.Count -gt 0) {
            $tracked[$file.relative_path] = $lineEntries.Count
            $details[$file.relative_path] = @($lineEntries.ToArray())
        }
    }

    return [ordered]@{
        files = $tracked
        details = $details
        metrics = $metrics
        total_occurrences = $total
        total_files = Get-SafeCount -Value $tracked
        changed_files = Get-SafeCount -Value $Files
    }
}

function Get-ModuleSplitScan {
    param(
        [object[]]$Files,
        [hashtable]$Exceptions
    )

    $blocked = [ordered]@{}
    $review = [ordered]@{}

    foreach ($file in $Files) {
        if (Test-IsException -Lookup $Exceptions -Rule "module_split_guard" -RelativePath $file.relative_path) {
            continue
        }

        $lineCount = Get-FileLineCount -Path $file.path
        if ($lineCount -gt $lineHardLimit) {
            $blocked[$file.relative_path] = $lineCount
        } elseif ($lineCount -gt $lineSoftLimit) {
            $review[$file.relative_path] = $lineCount
        }
    }

    return [ordered]@{
        files = $blocked
        review_files = $review
        total_files = Get-SafeCount -Value $blocked
        review_total_files = Get-SafeCount -Value $review
        changed_files = Get-SafeCount -Value $Files
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

function Write-ReadabilitySummary {
    param(
        [hashtable]$RuleData,
        [switch]$ShowDetails
    )

    Write-Host ("[ARCH][readability_guard] changed_files={0} violating_files={1} issues={2}" -f `
            $RuleData.changed_files, $RuleData.total_files, $RuleData.total_occurrences)

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

        if (-not $ShowDetails -or -not $RuleData.details.Contains($pair.path)) {
            continue
        }

        foreach ($entry in $RuleData.details[$pair.path]) {
            $lineLabel = if ([int]$entry.line -gt 0) {
                ("line {0}" -f $entry.line)
            } else {
                "file"
            }
            Write-Host ("    [{0}] {1} :: {2}" -f $entry.rule, $lineLabel, $entry.text)
        }
    }
}

function Write-ModuleSplitSummary {
    param([hashtable]$RuleData)

    Write-Host ("[ARCH][module_split_guard] changed_files={0} blocked={1} review={2}" -f `
            $RuleData.changed_files, $RuleData.total_files, $RuleData.review_total_files)

    $blockedPairs = foreach ($key in $RuleData.files.Keys) {
        [pscustomobject]@{
            path = $key
            lines = [int]$RuleData.files[$key]
        }
    }
    foreach ($pair in $blockedPairs | Sort-Object `
            @{ Expression = "lines"; Descending = $true }, `
            @{ Expression = "path"; Descending = $false }) {
        Write-Host ("  - BLOCK {0} :: {1} lines" -f $pair.path, $pair.lines)
    }

    $reviewPairs = foreach ($key in $RuleData.review_files.Keys) {
        [pscustomobject]@{
            path = $key
            lines = [int]$RuleData.review_files[$key]
        }
    }
    foreach ($pair in $reviewPairs | Sort-Object `
            @{ Expression = "lines"; Descending = $true }, `
            @{ Expression = "path"; Descending = $false }) {
        Write-Host ("  - REVIEW {0} :: {1} lines" -f $pair.path, $pair.lines)
    }
}

function Validate-LineCountRule {
    param(
        [hashtable]$CurrentRule,
        [hashtable]$BaselineRule,
        [hashtable]$Exceptions
    )

    $errors = @()
    foreach ($path in $CurrentRule.files.Keys) {
        if (Test-IsException -Lookup $Exceptions -Rule "file_length" -RelativePath $path) {
            continue
        }

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

function Validate-ReadabilityRule {
    param([hashtable]$CurrentRule)

    $errors = @()
    foreach ($path in $CurrentRule.files.Keys) {
        $errors += @("readability_guard: $path 存在 $($CurrentRule.files[$path]) 个可读性违规")
    }
    return $errors
}

function Validate-ModuleSplitRule {
    param([hashtable]$CurrentRule)

    $errors = @()
    foreach ($path in $CurrentRule.files.Keys) {
        $lineCount = [int]$CurrentRule.files[$path]
        $errors += @("module_split_guard: 已修改超长文件 $path 仍为 $lineCount 行，禁止通过压缩排版继续维护，必须先拆模块")
    }
    return $errors
}

$allScripts = Get-ScriptFiles -RootPath $projectRoot -ExcludePrefixes @("scripts/tests")
$changedScripts = Get-ChangedScriptFiles -RootPath $projectRoot -ExcludePrefixes @("scripts/tests", "tools")
$sceneFirstScripts = Get-ScriptFiles -RootPath $projectRoot -IncludePrefixes @("scripts/main", "scripts/ui", "scripts/board")
$exceptions = Get-ExceptionLookup -Path $exceptionsPath
$lineCountScan = Get-LineCountScan -Files $allScripts
$sceneFirstScan = Get-PatternScan -Files $sceneFirstScripts -Pattern $sceneFirstPattern -RuleName "scene_first_ui" -Exceptions $exceptions
$rootLookupScan = Get-PatternScan -Files $allScripts -Pattern $rootLookupPattern -RuleName "root_lookup" -Exceptions $exceptions
$dynamicCallScan = Get-PatternScan -Files $allScripts -Pattern $dynamicCallPattern -RuleName "dynamic_call" -Exceptions $exceptions
$readabilityScan = Get-ReadabilityScan -Files $changedScripts -Exceptions $exceptions
$moduleSplitScan = Get-ModuleSplitScan -Files $changedScripts -Exceptions $exceptions
$baselinePayload = Get-BaselinePayload -LineCount $lineCountScan -SceneFirstUi $sceneFirstScan -RootLookup $rootLookupScan -DynamicCall $dynamicCallScan
$mode = if ($WriteBaseline) { "write-baseline" } elseif ($ReportOnly) { "report-only" } else { "validate" }

Write-Host ("[ARCH] Mode: {0}" -f $mode)
Write-Host ("[ARCH] Root: {0}" -f $projectRoot)
Write-LineCountSummary -RuleData $lineCountScan
Write-RuleSummary -Name "scene_first_ui" -RuleData $sceneFirstScan -ShowLineDetails:($ReportOnly -or $WriteBaseline)
Write-RuleSummary -Name "root_lookup" -RuleData $rootLookupScan -ShowLineDetails:($ReportOnly -or $WriteBaseline)
Write-RuleSummary -Name "dynamic_call" -RuleData $dynamicCallScan -ShowLineDetails:($ReportOnly -or $WriteBaseline)
Write-ReadabilitySummary -RuleData $readabilityScan -ShowDetails:($ReportOnly -or $WriteBaseline)
Write-ModuleSplitSummary -RuleData $moduleSplitScan

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
$failures += @(Validate-LineCountRule -CurrentRule $lineCountScan -BaselineRule $baselineLineCount -Exceptions $exceptions)
$failures += @(Validate-PatternRule -RuleName "scene_first_ui" -CurrentRule $sceneFirstScan -BaselineRule $baselineSceneFirst -Exceptions $exceptions)
$failures += @(Validate-PatternRule -RuleName "root_lookup" -CurrentRule $rootLookupScan -BaselineRule $baselineRootLookup -Exceptions $exceptions)
$failures += @(Validate-PatternRule -RuleName "dynamic_call" -CurrentRule $dynamicCallScan -BaselineRule $baselineDynamicCall -Exceptions $exceptions)
$failures += @(Validate-ReadabilityRule -CurrentRule $readabilityScan)
$failures += @(Validate-ModuleSplitRule -CurrentRule $moduleSplitScan)

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

    foreach ($path in $readabilityScan.files.Keys) {
        foreach ($entry in $readabilityScan.details[$path]) {
            $lineLabel = if ([int]$entry.line -gt 0) {
                ("line {0}" -f $entry.line)
            } else {
                "file"
            }
            Write-Host ("  - [readability_guard] {0} :: {1} :: {2}" -f $path, $lineLabel, $entry.text) -ForegroundColor Red
        }
    }

    foreach ($path in $moduleSplitScan.files.Keys) {
        Write-Host ("  - [module_split_guard] {0} :: {1} lines" -f $path, $moduleSplitScan.files[$path]) -ForegroundColor Red
    }

    exit 1
}

Write-Host "[ARCH] Architecture guard passed"

