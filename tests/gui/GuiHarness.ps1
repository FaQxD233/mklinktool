# GUI 测试主体共用的函数，在 GUI 副本的脚本作用域内点调用。窗口显示时会触发启动检查，
# 所以 Show-TestForm 必须在测试主体定义好桩函数之后再调用。

function Show-TestForm {
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(-4000, -4000)
    $form.ShowInTaskbar = $false
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
}

function Wait-TaskEnd([int]$TimeoutMs) {
    # 代替计时器手动轮询，直到任务结束或超时；返回任务是否已结束。
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($script:ActiveJob -and $watch.ElapsedMilliseconds -lt $TimeoutMs) {
        Start-Sleep -Milliseconds 200
        Update-WorkerView
        [System.Windows.Forms.Application]::DoEvents()
    }
    return -not $script:ActiveJob
}

function Get-SessionDirs {
    @([System.IO.Directory]::GetDirectories([System.IO.Path]::GetTempPath(), 'mklinktool-*'))
}
