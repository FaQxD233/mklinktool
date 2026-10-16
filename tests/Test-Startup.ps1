# 启动失败提示（N14）的端到端测试：把启动器与 GUI 副本放进名称含空格和单引号的临时目录，运行启动器副本。
# [S1] 正常启动：GUI 副本把 [void]$form.ShowDialog() 换成写标记文件，确认经启动器能运行到这一步、$PSScriptRoot 正确。
# [S2] 启动阶段抛异常：GUI 副本中注入 throw，应只弹出 GUI 自身的中文提示，关闭后进程退出。
# [S3] 语法错误：脚本根本无法运行，应弹出启动器的兜底提示。
# 会在屏幕上短暂弹出真实的对话框（读出文字后随即由测试关闭），以确认提示确实能显示出来。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$repoRoot = Split-Path -Parent $PSScriptRoot
$guiText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'migrate-local-folders.ps1'), [System.Text.Encoding]::UTF8)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mkl-startup-tests-' + [guid]::NewGuid().ToString('N'))
$launcherPids = New-Object 'System.Collections.Generic.List[int]'

function New-LauncherCopy([string]$Name, [string]$GuiScriptText) {
    # 目录名含空格与单引号：启动器把脚本路径经环境变量交给 PowerShell，路径中的任何字符都不应被当作代码解析。
    $dir = Join-Path $workRoot "$Name it's here"
    [void][System.IO.Directory]::CreateDirectory($dir)
    [System.IO.File]::Copy((Join-Path $repoRoot 'migrate-local-folders.cmd'), (Join-Path $dir 'migrate-local-folders.cmd'))
    [System.IO.File]::WriteAllText((Join-Path $dir 'migrate-local-folders.ps1'), $GuiScriptText, $utf8Bom)
    return $dir
}

function Start-LauncherCopy([string]$Dir) {
    # 返回 cmd 的进程号：启动器用 start 拉起 PowerShell 后立即退出，PowerShell 是它的子进程。
    $cmdPath = Join-Path $env:WINDIR 'System32\cmd.exe'
    $launcher = Start-Process -FilePath $cmdPath -ArgumentList @('/c', ('"' + (Join-Path $Dir 'migrate-local-folders.cmd') + '"')) -WindowStyle Hidden -PassThru
    $launcherPids.Add($launcher.Id)
    return $launcher.Id
}

function Get-LauncherChildren([int]$LauncherPid) {
    foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $LauncherPid AND Name = 'powershell.exe'")) {
        try { [System.Diagnostics.Process]::GetProcessById([int]$child.ProcessId) } catch { }
    }
}

function Wait-LauncherDialog([int]$LauncherPid, [int]$TimeoutMs) {
    # 等启动器拉起的 PowerShell 弹出标题为 mklinktool 的对话框，返回进程与对话框中的文字；超时返回 $null。
    # 不按控件类型筛选：实测消息框的正文是 Static 控件，UI Automation 有时把它报告为 Pane 而不是 Text。
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        foreach ($process in @(Get-LauncherChildren $LauncherPid)) {
            if ($process.MainWindowHandle -ne [IntPtr]::Zero -and $process.MainWindowTitle -eq 'mklinktool') {
                $dialog = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
                $text = @($dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name }) -join "`n"
                return [pscustomobject]@{ Process = $process; Text = $text }
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Close-Dialog($Dialog) {
    # 关掉对话框后进程应很快退出；若又弹出第二个对话框，进程就不会退出。
    [void]$Dialog.Process.CloseMainWindow()
    return $Dialog.Process.WaitForExit(15000)
}

[void][System.IO.Directory]::CreateDirectory($workRoot)
try {
    '[S1] Normal start through the launcher reaches the main window'
    $marker = Join-Path $workRoot 'S1-started.txt'
    $dir = New-LauncherCopy 'S1' (Set-UniqueText $guiText '[void]$form.ShowDialog()' ('[System.IO.File]::WriteAllText(' + (ConvertTo-Literal $marker) + ', $PSScriptRoot)'))
    $launcherPid = Start-LauncherCopy $dir
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not [System.IO.File]::Exists($marker) -and $watch.ElapsedMilliseconds -lt 30000) { Start-Sleep -Milliseconds 200 }
    $root = if ([System.IO.File]::Exists($marker)) { [System.IO.File]::ReadAllText($marker) } else { '' }
    Assert ($root -eq $dir) 'reached ShowDialog with the right script root' "marker=$root"

    '[S2] An exception during startup: the GUI script shows its own message, once'
    $dir = New-LauncherCopy 'S2' (Set-UniqueText $guiText 'Add-Type -AssemblyName System.Drawing' "throw 'injected startup failure'")
    $dialog = Wait-LauncherDialog (Start-LauncherCopy $dir) 30000
    Assert ($null -ne $dialog -and $dialog.Text.Contains('目录迁移工具启动失败') -and $dialog.Text.Contains('injected startup failure')) 'startup error shown by the script' $(if ($null -ne $dialog) { $dialog.Text } else { 'no dialog' })
    if ($null -ne $dialog) { Assert (Close-Dialog $dialog) 'process exits once the message is closed (no second message)' }

    '[S3] The script cannot run at all (syntax error): the launcher shows its fallback message'
    $dir = New-LauncherCopy 'S3' ($guiText + "`r`nif (`$true) {`r`n")
    $dialog = Wait-LauncherDialog (Start-LauncherCopy $dir) 30000
    Assert ($null -ne $dialog -and $dialog.Text.Contains('mklinktool could not start')) 'fallback message from the launcher' $(if ($null -ne $dialog) { $dialog.Text } else { 'no dialog' })
    if ($null -ne $dialog) { Assert (Close-Dialog $dialog) 'process exits once the message is closed' }
} catch {
    "TEST ERROR: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
    $script:TestFail++
} finally {
    # 只结束本测试经启动器拉起、且仍未退出的进程（例如对话框没能关闭）。
    foreach ($launcherPid in $launcherPids) {
        foreach ($process in @(Get-LauncherChildren $launcherPid)) { try { $process.Kill(); [void]$process.WaitForExit(5000) } catch { } }
    }
    try { Remove-TestTree $workRoot } catch { "  cleanup of $workRoot failed: $($_.Exception.Message)" }
}
Write-TestSummary
if ($script:TestFail -gt 0) { exit 1 }
exit 0
