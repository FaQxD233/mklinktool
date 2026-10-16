# 测试共用的断言、摘要与清理函数，由各测试脚本点调用（GUI 测试主体在 GUI 副本的脚本作用域内点调用）。
$script:TestPass = 0
$script:TestFail = 0

function Assert([bool]$Condition, [string]$Name, [string]$Detail = '') {
    if ($Condition) { $script:TestPass++; "  PASS $Name" } else { $script:TestFail++; "  FAIL $Name $Detail" }
}

function Write-TestSummary {
    # Invoke-AllTests 与 Test-Gui 按这一行汇总结果。
    "SUMMARY pass=$($script:TestPass) fail=$($script:TestFail)"
}

function Set-UniqueText([string]$Text, [string]$Old, [string]$New) {
    # 给脚本副本注入测试代码：$Old 必须恰好出现一次，防止产品代码改动后注入点悄悄落空或落错位置。
    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($count -ne 1) { throw "Expected exactly one '$Old', found $count." }
    return $Text.Replace($Old, $New)
}

function ConvertTo-Literal([string]$Value) {
    # 生成 PowerShell 单引号字符串字面量。
    return "'" + $Value.Replace("'", "''") + "'"
}

function Remove-TestTree([string]$Path) {
    # 删除测试目录：先拆除所有重解析点本身，再清只读属性，最后递归删除，不会穿过链接触及其目标。
    if ([string]::IsNullOrEmpty($Path) -or -not [System.IO.Directory]::Exists($Path)) { return }
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Path)
    $directories = New-Object 'System.Collections.Generic.List[string]'
    while ($pending.Count -gt 0) {
        $dir = $pending.Pop()
        $directories.Add($dir)
        foreach ($entry in [System.IO.DirectoryInfo]::new($dir).GetFileSystemInfos()) {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                [System.IO.File]::SetAttributes($entry.FullName, $entry.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly))
                if (($entry.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) { [System.IO.Directory]::Delete($entry.FullName) } else { [System.IO.File]::Delete($entry.FullName) }
            } elseif (($entry.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $pending.Push($entry.FullName)
            } elseif (($entry.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                [System.IO.File]::SetAttributes($entry.FullName, [System.IO.FileAttributes]::Normal)
            }
        }
    }
    foreach ($dir in $directories) { [System.IO.File]::SetAttributes($dir, [System.IO.FileAttributes]::Normal) }
    [System.IO.Directory]::Delete($Path, $true)
}
