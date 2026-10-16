# 运行全部测试：静态检查、引擎端到端与故障注入、GUI。
# 用法：powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-AllTests.ps1 [-IncludeElevated]
# 要求：Windows PowerShell 5.1；开启开发者模式（或以管理员身份运行）以便非提权创建目录符号链接；有桌面会话（GUI 测试会在屏幕外创建窗口）。
# 默认的 GUI 测试分两组：假 Worker；真实 Worker 与引擎以普通权限运行（不弹 UAC）。
# -IncludeElevated：再跑一组走真实 UAC 与提权 Worker 的端到端测试，运行时需要有人点一次 UAC 的“是”。
# 测试只在 %TEMP% 下的临时目录中工作，结束时清理；不会改动真实的中断恢复记录或旧会话目录。
param([switch]$IncludeElevated)
$ErrorActionPreference = 'Stop'
$powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$suites = @(
    @{ Name = 'Test-Static.ps1'; Arguments = @() },
    @{ Name = 'Test-Engine.ps1'; Arguments = @() },
    @{ Name = 'Test-Gui.ps1'; Arguments = @() },
    @{ Name = 'Test-Gui.ps1'; Arguments = @('-Mode', 'RealWorker') })
if ($IncludeElevated) { $suites += @{ Name = 'Test-Gui.ps1'; Arguments = @('-Mode', 'Elevated') } }
$totalPass = 0
$totalFail = 0
$broken = New-Object System.Collections.Generic.List[string]
foreach ($suite in $suites) {
    $label = ($suite.Name + ' ' + ($suite.Arguments -join ' ')).Trim()
    "===== $label"
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $powershellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $suite.Name) @($suite.Arguments) 2>&1 | ForEach-Object { "$_" })
    } finally {
        $ErrorActionPreference = $previous
    }
    $exitCode = $LASTEXITCODE
    $output
    $summary = @($output | Where-Object { $_ -match '^SUMMARY pass=\d+ fail=\d+$' }) | Select-Object -Last 1
    if ($summary -match '^SUMMARY pass=(\d+) fail=(\d+)$') {
        $totalPass += [int]$Matches[1]
        $totalFail += [int]$Matches[2]
        if ($exitCode -ne 0 -and [int]$Matches[2] -eq 0) { $broken.Add("$label (exit $exitCode)") }
    } else {
        $broken.Add("$label (no SUMMARY, exit $exitCode)")
    }
    '----- {0}: {1:N0} s' -f $label, $watch.Elapsed.TotalSeconds
}
''
"TOTAL pass=$totalPass fail=$totalFail"
if ($broken.Count -gt 0) { 'BROKEN: ' + ($broken -join '; ') }
if ($totalFail -gt 0 -or $broken.Count -gt 0) { exit 1 }
exit 0
