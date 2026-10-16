# GUI 测试：把 migrate-local-folders.ps1 复制到临时目录，用点调用测试主体替换末尾的 [void]$form.ShowDialog()，
# 再以 STA 运行这份副本。点调用脚本里的 exit 传不出 -File 进程，因此按输出中的 SUMMARY 行判断成败。
# -Mode Fake（默认）：gui\GuiTests.Body.ps1，Worker 由 gui\FakeWorker.ps1 扮演。
# -Mode RealWorker：gui\WorkerTests.Body.ps1，真实的 Worker 与引擎以普通权限运行（Worker 副本去掉提权检查，
#                   GUI 副本去掉 -Verb RunAs），不弹 UAC。
# -Mode Elevated：gui\WorkerTests.Body.ps1，仓库里原样的 Worker 经 UAC 提权启动，需要有人点一次“是”。
param([ValidateSet('Fake', 'RealWorker', 'Elevated')][string]$Mode = 'Fake')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$guiPath = Join-Path $repoRoot 'migrate-local-folders.ps1'
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('mkl-gui-tests-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($workDir)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

function Set-UniqueText([string]$Text, [string]$Old, [string]$New) {
    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($count -ne 1) { throw "Expected exactly one '$Old', found $count." }
    return $Text.Replace($Old, $New)
}

function ConvertTo-Literal([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

try {
    $text = [System.IO.File]::ReadAllText($guiPath, [System.Text.Encoding]::UTF8)
    switch ($Mode) {
        'Fake' {
            $prelude = ''
            $bodyPath = Join-Path $PSScriptRoot 'gui\GuiTests.Body.ps1'
        }
        'RealWorker' {
            # Worker 与引擎复制到同一临时目录（Worker 按自身所在目录找引擎），只去掉 Worker 副本的提权检查。
            $engineText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'migration-engine.ps1'), [System.Text.Encoding]::UTF8)
            [System.IO.File]::WriteAllText((Join-Path $workDir 'migration-engine.ps1'), $engineText, $utf8Bom)
            $workerText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'migration-worker.ps1'), [System.Text.Encoding]::UTF8)
            $workerText = Set-UniqueText $workerText "throw 'The migration worker was not started with an elevated token.'" "`$null = 'test copy: elevation check skipped'"
            $workerPath = Join-Path $workDir 'migration-worker.ps1'
            [System.IO.File]::WriteAllText($workerPath, $workerText, $utf8Bom)
            $text = Set-UniqueText $text ' -Verb RunAs' ''
            $prelude = "`$script:TestWorkerElevated = `$false; `$script:TestWorkerPath = $(ConvertTo-Literal $workerPath); "
            $bodyPath = Join-Path $PSScriptRoot 'gui\WorkerTests.Body.ps1'
        }
        'Elevated' {
            # 只放宽测试副本：等 Worker 连接管道的时间从 30 秒延长到 120 秒，留出点 UAC 的时间。
            $text = Set-UniqueText $text 'for ($attempt = 0; $attempt -lt 30; $attempt++) {' 'for ($attempt = 0; $attempt -lt 120; $attempt++) {'
            $prelude = "`$script:TestWorkerElevated = `$true; `$script:TestWorkerPath = $(ConvertTo-Literal (Join-Path $repoRoot 'migration-worker.ps1')); "
            $bodyPath = Join-Path $PSScriptRoot 'gui\WorkerTests.Body.ps1'
        }
    }
    $text = Set-UniqueText $text '[void]$form.ShowDialog()' ($prelude + '. ' + (ConvertTo-Literal $bodyPath))
    $harnessPath = Join-Path $workDir 'gui-harness.ps1'
    [System.IO.File]::WriteAllText($harnessPath, $text, $utf8Bom)

    $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $powershellExe -NoProfile -STA -ExecutionPolicy Bypass -File $harnessPath 2>&1 | ForEach-Object { "$_" })
    } finally {
        $ErrorActionPreference = $previous
    }
    $output
    $summary = @($output | Where-Object { $_ -match '^SUMMARY pass=\d+ fail=\d+$' }) | Select-Object -Last 1
    if ($summary -match '^SUMMARY pass=\d+ fail=(\d+)$') {
        if ([int]$Matches[1] -gt 0) { exit 1 }
        exit 0
    }
    # 测试主体没跑完（例如脚本解析失败）：补一行失败摘要，供 Invoke-AllTests 汇总。
    'SUMMARY pass=0 fail=1'
    exit 1
} finally {
    try { [System.IO.Directory]::Delete($workDir, $true) } catch { }
}
