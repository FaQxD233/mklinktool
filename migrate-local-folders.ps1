$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    Write-Error '需要 Windows PowerShell 5.1 或更高版本。'
    exit 1
}

Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:EnginePath = Join-Path $PSScriptRoot 'migration-engine.ps1'
$script:WorkerPath = Join-Path $PSScriptRoot 'migration-worker.ps1'
$script:Jobs = New-Object System.Collections.ArrayList
$script:Worker = $null
$script:WorkerPipe = $null
$script:WorkerReader = $null
$script:WorkerWriter = $null
$script:WorkerPipeName = ''
$script:WorkerAction = ''
$script:ActiveJob = $false
$script:WorkerRequestId = ''
$script:WorkerResultPath = ''
$script:WorkerEnginePid = 0
$script:WorkerEngineStartTime = ''
# 没收到 Worker 的任务确认、只能凭结果文件跟踪任务时，加在状态栏进度文字前的说明。
$script:WorkerStatusPrefix = ''
$script:WorkerReadTimeoutMs = 30000
$script:WorkerState = $null
$script:WorkerStatePath = ''
$script:WorkerLogPath = ''
$script:WorkerSessionPath = ''
$script:WorkerItems = @()
$script:WorkerJournalPath = ''
$script:LogBytesShown = 0
$script:PlanValid = $false
$script:LastAnalysisSignature = ''
$script:ContextPath = ''
# 每次迁移开始前写入一份中断恢复记录，启动时据此检测“备份存在而原路径缺失”。
$script:RecoveryJournalRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'mklinktool\pending'
# Everyone / Authenticated Users / Users / INTERACTIVE：本机任意账户都属于的宽泛组。
$script:BroadPrincipalSids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-4')
# 能修改内容、删除或改写权限的访问位，另含 GENERIC_WRITE(0x40000000) 与 GENERIC_ALL(0x10000000)。
$script:WriteRightsMask = [int][System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, DeleteSubdirectoriesAndFiles, Delete, ChangePermissions, TakeOwnership' -bor 0x50000000

Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class MklinkToolPipeNative { [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetNamedPipeClientProcessId(IntPtr pipe, out uint clientProcessId); }'

function Format-Bytes([long]$Bytes) {
    $units = @('B', 'KiB', 'MiB', 'GiB', 'TiB')
    [double]$value = $Bytes
    $unitIndex = 0
    while ($value -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $value = $value / 1024
        $unitIndex++
    }
    return ('{0:N1} {1}' -f $value, $units[$unitIndex])
}

function Convert-StatusText([string]$Code) {
    # 作业的 Status 一律保存状态码（引擎状态码或下面的界面状态码），只在显示时转换为中文。
    $labels = @{
        NotChecked = '待预检'; Queued = '等待扫描'; Stale = '待重新预检'; NotStarted = '未执行'; Waiting = '等待中'
        Starting = '启动中'; Analyzing = '扫描中'; Ready = '预检通过'; Checking = '检查中'; Scanning = '扫描中'
        Error = '错误'; PreflightFailed = '预检未通过'; Copying = '复制中'; Verifying = '校验中'
        RenamingSource = '备份改名中'; CreatingLink = '创建链接中'; Complete = '完成'
        CompleteBackupRetained = '完成，保留备份'; RolledBack = '已回滚'; RecoveryRequired = '需要人工恢复'; Failed = '失败'
        Cleaning = '清理中'; Cleaned = '副本已清理'; CleanupFailed = '清理失败'
        Restoring = '恢复中'; Restored = '已恢复'; RestoreSkipped = '无需恢复'; RestoreFailed = '恢复失败'
    }
    if ($labels.ContainsKey($Code)) { return $labels[$Code] }
    return $Code
}

function ConvertTo-UiFullPath([string]$Path) {
    try { return [System.IO.Path]::GetFullPath($Path) } catch { return $Path }
}

function ConvertTo-UiDevicePath([string]$Path) {
    # \\?\ 设备路径不受 .NET Framework 260 字符限制（系统未启用 LongPathsEnabled 时）；UNC 需写成 \\?\UNC\。
    if ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal)) { return $Path }
    if ($Path.StartsWith('\\', [System.StringComparison]::Ordinal)) { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function Join-UiPath([string]$BasePath, [string]$ChildPath) {
    # 纯字符串拼接：Join-Path 会解析 PowerShell 驱动器，根目录填了不存在的盘符时直接抛 DriveNotFoundException。
    return $BasePath.TrimEnd('\', '/') + '\' + $ChildPath
}

function Get-StructureMode {
    if ($structureCombo.SelectedIndex -eq 1) { return 'Categorized' }
    return 'Flat'
}

function Get-GeneratedTarget([string]$Source, [string]$Root, [string]$Mode) {
    if ([string]::IsNullOrWhiteSpace($Root)) { return '' }
    $fullSource = (ConvertTo-UiFullPath $Source).TrimEnd('\')
    $name = [System.IO.Path]::GetFileName($fullSource)
    if ([string]::IsNullOrWhiteSpace($name)) { return '' }
    if ($Mode -eq 'Categorized') {
        $parent = [System.IO.DirectoryInfo]::new($fullSource).Parent
        if ($null -eq $parent) { return '' }
        if ([string]::Equals($parent.FullName.TrimEnd('\'), $parent.Root.FullName.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            $rootPath = [System.IO.Path]::GetPathRoot($fullSource)
            if ($rootPath -match '^[a-zA-Z]:\\?$') {
                $category = $rootPath.Substring(0, 1).ToLowerInvariant()
            } else {
                $category = 'root'
            }
        } else {
            $category = $parent.Name.ToLowerInvariant()
        }
        $datedCategory = '{0}-{1}{2}' -f $category, $name, (Get-Date -Format 'yyMMdd')
        return Join-UiPath (Join-UiPath $Root $datedCategory) $name
    }
    return Join-UiPath $Root $name
}
function Get-CurrentSignature {
    # 只纳入影响预检结论的内容。Analyze 不使用 SHA-256 与备份清理选项，Migrate 会读取当时的勾选值并重新预检，
    # 因此切换这两项不必作废预检结果。
    $currentJobs = @()
    foreach ($job in $script:Jobs) {
        $currentJobs += [pscustomobject]@{ Source = $job.Source; Target = $job.Target }
    }
    $signatureObject = [pscustomobject]@{
        LinkType = 'SymbolicLink'
        Jobs = $currentJobs
    }
    return ($signatureObject | ConvertTo-Json -Depth 4 -Compress)
}

function Refresh-Grid {
    # 仅在行数变化（增删任务）时全量重建；其余情况逐单元格就地更新，
    # 避免每 500ms 全量 Rows.Clear() 造成闪烁、滚动位置与选中状态丢失。
    if ($grid.Rows.Count -ne $script:Jobs.Count) {
        $grid.Rows.Clear()
        foreach ($job in $script:Jobs) { [void]$grid.Rows.Add() }
    }
    for ($i = 0; $i -lt $script:Jobs.Count; $i++) {
        $job = $script:Jobs[$i]
        $row = $grid.Rows[$i]
        $row.Tag = $job
        $cellValues = [ordered]@{
            Source = [string]$job.Source
            Target = [string]$job.Target
            FileCount = [string]$job.FileCount
            Size = Format-Bytes ([long]$job.TotalBytes)
            JunctionCount = [string]$job.JunctionCount
            SymbolicLinkCount = [string]$job.SymbolicLinkCount
            Status = Convert-StatusText ([string]$job.Status)
        }
        foreach ($columnName in $cellValues.Keys) {
            $cell = $row.Cells[$columnName]
            $newValue = [string]$cellValues[$columnName]
            if (-not [string]::Equals([string]$cell.Value, $newValue, [System.StringComparison]::Ordinal)) {
                $cell.Value = $newValue
            }
        }
        # 无条件赋值（含空串），确保上一轮的错误与警告提示会被清除；
        # 行头不可见，错误图标必须挂在 Status 单元格上才能被用户看到。
        $statusCell = $row.Cells['Status']
        $statusCell.ErrorText = [string]$job.Error
        $statusCell.ToolTipText = @(@([string]$job.Warning, [string]$job.PermissionWarning) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
    }
    Update-CleanupButton
}

function Test-WorkerActive {
    return [bool]$script:ActiveJob
}

function Add-SourcePaths([string[]]$Paths) {
    if (Test-WorkerActive) {
        [System.Windows.Forms.MessageBox]::Show('后台扫描或迁移期间不能更改来源列表。', 'mklinktool', 'OK', 'Warning') | Out-Null
        return
    }

    if ($grid.IsCurrentCellInEditMode) { [void]$grid.EndEdit() }
    $mode = Get-StructureMode
    $addedCount = 0
    $duplicateCount = 0
    $invalidPaths = New-Object System.Collections.ArrayList
    $unsupportedPaths = New-Object System.Collections.ArrayList
    foreach ($pathValue in $Paths) {
        if ([string]::IsNullOrWhiteSpace([string]$pathValue)) { continue }
        $rawPath = ([string]$pathValue).Trim()
        # “D:” 会被 GetFullPath 解析为该盘的当前目录，“D:\” 是盘符根；两者都直接拒绝，
        # 避免静默添加错误的路径或生成空目标。
        if ($rawPath -match '^[a-zA-Z]:$') {
            [void]$unsupportedPaths.Add($rawPath)
            continue
        }
        $source = ConvertTo-UiFullPath $rawPath
        if ($source -match '^[a-zA-Z]:\\?$') {
            [void]$unsupportedPaths.Add($rawPath)
            continue
        }
        # GetFullPath 会保留末尾反斜杠；统一去掉，使 C:\a 与 C:\a\ 去重时视为同一目录。
        $source = $source.TrimEnd('\')
        if (-not [System.IO.Directory]::Exists($source)) {
            [void]$invalidPaths.Add([string]$pathValue)
            continue
        }

        $duplicate = $false
        foreach ($job in $script:Jobs) {
            if ([string]::Equals($job.Source, $source, [System.StringComparison]::OrdinalIgnoreCase)) {
                $duplicate = $true
                break
            }
        }
        if ($duplicate) {
            $duplicateCount++
            continue
        }

        $job = [pscustomobject]@{
            Source = $source
            Target = Get-GeneratedTarget -Source $source -Root $rootTextBox.Text -Mode $mode
            IsCustomTarget = $false
            FileCount = 0
            TotalBytes = 0L
            JunctionCount = 0
            SymbolicLinkCount = 0
            AbsoluteLinkCount = 0
            Status = 'NotChecked'
            Warning = ''
            PermissionWarning = ''
            Error = ''
            # 迁移在改名前失败或已回滚后遗留的目标副本路径，供“清理失败副本”使用。
            CleanupTarget = ''
        }
        [void]$script:Jobs.Add($job)
        $addedCount++
    }

    if ($addedCount -gt 0) {
        Refresh-Grid
        Set-PlanStale ("已添加 {0} 个来源目录，请扫描并预检。" -f $addedCount)
    }

    if ($invalidPaths.Count -gt 0 -or $unsupportedPaths.Count -gt 0 -or ($addedCount -eq 0 -and $duplicateCount -gt 0)) {
        $message = "已添加 $addedCount 个目录。"
        if ($duplicateCount -gt 0) { $message += "`r`n跳过 $duplicateCount 个已在列表中的目录。" }
        if ($unsupportedPaths.Count -gt 0) {
            $message += "`r`n跳过 $($unsupportedPaths.Count) 个盘符根目录（不支持迁移整个盘符根）："
            $shownUnsupported = @($unsupportedPaths | Select-Object -First 5)
            if ($shownUnsupported.Count -gt 0) { $message += "`r`n" + ($shownUnsupported -join "`r`n") }
        }
        if ($invalidPaths.Count -gt 0) {
            $message += "`r`n跳过 $($invalidPaths.Count) 个不存在或不是文件夹的路径。"
            $shown = @($invalidPaths | Select-Object -First 5)
            if ($shown.Count -gt 0) { $message += "`r`n" + ($shown -join "`r`n") }
        }
        [System.Windows.Forms.MessageBox]::Show($message, 'mklinktool', 'OK', 'Information') | Out-Null
    }
}

function Remove-SelectedJobs {
    if (Test-WorkerActive) {
        [System.Windows.Forms.MessageBox]::Show('后台扫描或迁移期间不能移除来源目录。', 'mklinktool', 'OK', 'Warning') | Out-Null
        return
    }
    $selectedJobs = @()
    foreach ($row in $grid.SelectedRows) {
        if ($null -ne $row.Tag) { $selectedJobs += $row.Tag }
    }
    if ($grid.IsCurrentCellInEditMode) { [void]$grid.EndEdit() }
    if ($selectedJobs.Count -eq 0) { return }
    foreach ($job in $selectedJobs) { [void]$script:Jobs.Remove($job) }
    Refresh-Grid
    Set-PlanStale ("已移除 {0} 项，请重新扫描并预检。" -f $selectedJobs.Count)
}

function Set-PlanStale([string]$Message) {
    $script:PlanValid = $false
    $startButton.Enabled = $false
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $statusLabel.Text = $Message }
    foreach ($job in $script:Jobs) {
        if ($job.Status -eq 'Ready') { $job.Status = 'Stale' }
        $job.PermissionWarning = ''
    }
    Refresh-Grid
}

function Update-GeneratedTargets([string]$Reason) {
    foreach ($job in $script:Jobs) {
        if (-not $job.IsCustomTarget) {
            $job.Target = Get-GeneratedTarget -Source $job.Source -Root $rootTextBox.Text -Mode (Get-StructureMode)
        }
    }
    Set-PlanStale $Reason
}

function Get-WorkerConfig {
    $configJobs = @()
    foreach ($job in $script:Jobs) {
        $configJobs += [pscustomobject]@{ Source = $job.Source; Target = $job.Target }
    }
    return [pscustomobject]@{
        LinkType = 'SymbolicLink'
        VerifySha256 = [bool]$shaCheckbox.Checked
        DeleteBackup = [bool]$deleteBackupCheckbox.Checked
        Jobs = $configJobs
    }
}

function Get-PathSecurity([string]$Path) {
    $devicePath = ConvertTo-UiDevicePath $Path
    if ([System.IO.Directory]::Exists($devicePath)) { return [System.IO.Directory]::GetAccessControl($devicePath) }
    return [System.IO.File]::GetAccessControl($devicePath)
}

function Get-WritePrincipalSids($Security, [bool]$InheritedToNewSubdirectories) {
    # 返回 DACL 中被授予写入类权限的 SID。$InheritedToNewSubdirectories=$true 时只看会继承给新建子目录的 ACE
    # （即新建的目标目录将得到的权限），否则只看作用于该对象本身的 ACE。不计 Deny ACE：只会多报，不会漏报。
    $sids = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rule in $Security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        if (([int]$rule.FileSystemRights -band $script:WriteRightsMask) -eq 0) { continue }
        if ($InheritedToNewSubdirectories) {
            if (($rule.InheritanceFlags -band [System.Security.AccessControl.InheritanceFlags]::ContainerInherit) -eq 0) { continue }
        } elseif (($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) {
            continue
        }
        $sid = $rule.IdentityReference.Value
        if (-not $sids.Contains($sid)) { $sids.Add($sid) }
    }
    return $sids.ToArray()
}

function Get-PrincipalDisplayName([string]$Sid) {
    try {
        return ([System.Security.Principal.SecurityIdentifier]::new($Sid)).Translate([System.Security.Principal.NTAccount]).Value
    } catch {
        return $Sid
    }
}

function Get-ToolTamperWarning {
    # 提权 Worker 与引擎直接从本目录加载脚本。除当前用户、SYSTEM、Administrators、TrustedInstaller 外，
    # 任何账户或组能写入（或拥有）这些文件或目录，都能在下次提权时以管理员身份执行任意代码。
    $trustedSids = @(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        'S-1-5-18', 'S-1-5-32-544', 'S-1-3-4',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    )
    $untrustedSids = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in @($PSScriptRoot, $PSCommandPath, $script:WorkerPath, $script:EnginePath, (Join-Path $PSScriptRoot 'migrate-local-folders.cmd'))) {
        try {
            $security = Get-PathSecurity $path
            $sids = @(Get-WritePrincipalSids $security $false) + @($security.GetOwner([System.Security.Principal.SecurityIdentifier]).Value)
        } catch {
            # 文件缺失或无法读取 ACL：跳过（缺失的脚本会在使用时另行报错）。
            continue
        }
        foreach ($sid in $sids) {
            if ($trustedSids -notcontains $sid -and -not $untrustedSids.Contains($sid)) { $untrustedSids.Add($sid) }
        }
    }
    if ($untrustedSids.Count -eq 0) { return '' }
    $names = @($untrustedSids | ForEach-Object { Get-PrincipalDisplayName $_ }) -join '、'
    return "工具目录或其中的脚本可被以下账户或组修改：$names。`r`n这些脚本会以管理员身份运行，其他账户可借此在你下次提权时执行任意代码。`r`n建议把工具移到仅管理员可写的位置，例如 C:\Program Files\mklinktool。`r`n工具目录：$PSScriptRoot"
}

function Get-TargetPermissionWarning($Job) {
    # 工具不复制源目录 ACL（Robocopy /COPY:DAT），目标副本会继承目标位置的权限。目标位置允许宽泛组写入、
    # 而来源目前不允许时，迁移会扩大能修改这些数据的账户范围；若是程序目录，其他账户还可借此替换会被提权运行的文件。
    try {
        $ancestor = [System.IO.Path]::GetDirectoryName((ConvertTo-UiDevicePath (ConvertTo-UiFullPath ([string]$Job.Target))))
        while (-not [string]::IsNullOrEmpty($ancestor) -and -not [System.IO.Directory]::Exists($ancestor)) {
            $ancestor = [System.IO.Path]::GetDirectoryName($ancestor)
        }
        if ([string]::IsNullOrEmpty($ancestor)) { return '' }
        $targetWriters = @(Get-WritePrincipalSids (Get-PathSecurity $ancestor) $true | Where-Object { $script:BroadPrincipalSids -contains $_ })
        if ($targetWriters.Count -eq 0) { return '' }
        $sourceWriters = @(Get-WritePrincipalSids (Get-PathSecurity ([string]$Job.Source)) $false)
        $addedWriters = @($targetWriters | Where-Object { $sourceWriters -notcontains $_ })
        if ($addedWriters.Count -eq 0) { return '' }
        $names = @($addedWriters | ForEach-Object { Get-PrincipalDisplayName $_ }) -join '、'
        return "权限提示：目标位置会让 $names 获得写入权限（工具不复制源目录权限），而来源目前不允许；迁移后本机其他账户可修改这些数据。若这是程序目录，还可能被用来提权。"
    } catch {
        # 权限检查只是提示：读不到 ACL 时不阻断流程。
        return ''
    }
}

function Update-PermissionWarnings {
    $warningCount = 0
    foreach ($job in $script:Jobs) {
        $job.PermissionWarning = Get-TargetPermissionWarning $job
        if (-not [string]::IsNullOrEmpty($job.PermissionWarning)) {
            $warningCount++
            $logTextBox.AppendText("$($job.Source)：$($job.PermissionWarning)" + [Environment]::NewLine)
        }
    }
    Refresh-Grid
    return $warningCount
}

function Get-ProcessStartStamp([int]$ProcessId) {
    try { return [string](Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToFileTimeUtc() } catch { return '' }
}

function Save-RecoveryJournal([string]$Path, $Journal) {
    $temporaryPath = $Path + '.tmp'
    [System.IO.File]::WriteAllText($temporaryPath, ($Journal | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
    if ([System.IO.File]::Exists($Path)) {
        # 不要备份文件：必须传真正的 null。PowerShell 会把 $null 转成空串传给 .NET 的 string 参数（实测抛“路径格式非法”）。
        [System.IO.File]::Replace($temporaryPath, $Path, [System.Management.Automation.Language.NullString]::Value)
    } else {
        [System.IO.File]::Move($temporaryPath, $Path)
    }
}

function Write-RecoveryJournal([string]$SessionName, [object[]]$Jobs) {
    # 每次迁移一个记录文件；记下所属主窗口的 PID 与启动时间，避免另一个窗口把正在进行的迁移误判为中断。
    [void][System.IO.Directory]::CreateDirectory($script:RecoveryJournalRoot)
    $journalPath = Join-Path $script:RecoveryJournalRoot ($SessionName + '.json')
    $journal = [pscustomobject]@{
        Version = 1
        OwnerPid = $PID
        OwnerStartTime = Get-ProcessStartStamp $PID
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        Jobs = @($Jobs | ForEach-Object { [pscustomobject]@{ Source = [string]$_.Source; Target = [string]$_.Target } })
    }
    Save-RecoveryJournal $journalPath $journal
    return $journalPath
}

function Remove-RecoveryJournal([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return }
    try { [System.IO.File]::Delete($Path) } catch { }
}

function Test-InterruptedMigration([string]$Source) {
    # 备份是普通目录、而原路径上什么都没有（包括失效链接）时，才是在“改名后、建链前”中断的迁移。
    $sourcePath = $Source.TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($sourcePath)) { return $false }
    $backupDevicePath = ConvertTo-UiDevicePath ($sourcePath + '_migration_backup')
    $sourceDevicePath = ConvertTo-UiDevicePath $sourcePath
    if (-not [System.IO.Directory]::Exists($backupDevicePath)) { return $false }
    if (([System.IO.File]::GetAttributes($backupDevicePath) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    return -not ([System.IO.Directory]::Exists($sourceDevicePath) -or [System.IO.File]::Exists($sourceDevicePath))
}

function Find-InterruptedMigrations {
    # 返回所有“备份存在而原路径缺失”的条目，并把不再满足该条件的条目（已完成、未开始或已恢复）移出记录。
    # 记录所属的主窗口仍在运行时整份跳过，不干扰它正在进行的迁移。
    $found = New-Object System.Collections.ArrayList
    if (-not [System.IO.Directory]::Exists($script:RecoveryJournalRoot)) { return }
    foreach ($journalPath in [System.IO.Directory]::GetFiles($script:RecoveryJournalRoot, '*.json')) {
        try {
            $journal = [System.IO.File]::ReadAllText($journalPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ((Get-ProcessStartStamp ([int]$journal.OwnerPid)) -eq [string]$journal.OwnerStartTime) { continue }
            $entries = @($journal.Jobs)
            $pending = @($entries | Where-Object { Test-InterruptedMigration ([string]$_.Source) })
            if ($pending.Count -eq 0) {
                [System.IO.File]::Delete($journalPath)
            } elseif ($pending.Count -lt $entries.Count) {
                $journal.Jobs = $pending
                Save-RecoveryJournal $journalPath $journal
            }
            foreach ($entry in $pending) {
                [void]$found.Add([pscustomobject]@{ Source = ([string]$entry.Source).TrimEnd('\'); Target = [string]$entry.Target; Status = 'Waiting'; Error = ''; Warning = '' })
            }
        } catch {
            # 记录损坏或暂时无法读取：保留文件供人工检查，不影响启动。
        }
    }
    return $found.ToArray()
}

function ConvertTo-WorkerMessageJson([hashtable]$Message) {
    $Message.Version = 1
    return ($Message | ConvertTo-Json -Depth 5 -Compress)
}

function Read-WorkerMessage {
    if ($null -eq $script:WorkerReader) { throw '提权 Worker 连接不可用。' }
    $readTask = $script:WorkerReader.ReadLineAsync()
    try {
        if (-not $readTask.Wait($script:WorkerReadTimeoutMs)) {
            # 超时后挂起的异步读会让 StreamReader 一直处于“in use”状态，同一连接上的后续读取必然失败，
            # 必须断开连接（下次操作由 Connect-ElevatedWorker 重建）。Worker 进程对象保留，供调用方判断它何时退出。
            Close-WorkerConnection
            throw '等待提权 Worker 回复超时。'
        }
    } catch [System.AggregateException] {
        Close-WorkerConnection
        throw '提权 Worker 连接发生错误。'
    }
    $line = $readTask.Result
    if ($null -eq $line) { throw '提权 Worker 已断开连接。' }
    if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -gt 65536) {
        throw '提权 Worker 返回了无效或过长的协议消息。'
    }
    return ($line | ConvertFrom-Json -ErrorAction Stop)
}

function Connect-ElevatedWorker {
    if ($null -ne $script:Worker) {
        $script:Worker.Refresh()
        if (-not $script:Worker.HasExited -and $null -ne $script:WorkerPipe -and $script:WorkerPipe.IsConnected) {
            return
        }
        Close-ElevatedWorker
    }

    if (-not [System.IO.File]::Exists($script:WorkerPath)) {
        throw "找不到提权 Worker：$script:WorkerPath"
    }

    $pipeName = 'mklinktool-pipe-' + [guid]::NewGuid().ToString('N')
    $pipeSecurity = New-Object System.IO.Pipes.PipeSecurity
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $pipeSecurity.SetOwner($currentSid)
    $pipeRule = New-Object System.IO.Pipes.PipeAccessRule($currentSid, [System.IO.Pipes.PipeAccessRights]::ReadWrite, [System.Security.AccessControl.AccessControlType]::Allow)
    $pipeSecurity.AddAccessRule($pipeRule)
    # 以“另一个管理员账号”提权（OTS）时，Worker 令牌的用户 SID 与当前用户不同，
    # 但其令牌组包含已启用的 BUILTIN\Administrators；补充该 ACE 否则 Worker 连接管道会被拒绝。
    $adminsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $adminsRule = New-Object System.IO.Pipes.PipeAccessRule($adminsSid, [System.IO.Pipes.PipeAccessRights]::ReadWrite, [System.Security.AccessControl.AccessControlType]::Allow)
    $pipeSecurity.AddAccessRule($adminsRule)
    $pipeServer = [System.IO.Pipes.NamedPipeServerStream]::new(
        $pipeName,
        [System.IO.Pipes.PipeDirection]::InOut,
        1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::Asynchronous,
        65536,
        65536,
        $pipeSecurity
    )
    $pendingConnection = $pipeServer.BeginWaitForConnection($null, $null)
    $workerProcess = $null
    $reader = $null
    $writer = $null
    try {
        $powershellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -PipeName "{1}" -ParentPid {2}' -f $script:WorkerPath, $pipeName, $PID
        $workerProcess = Start-Process -FilePath $powershellPath -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -Verb RunAs -PassThru -WindowStyle Hidden
        $connected = $false
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            if ($pendingConnection.AsyncWaitHandle.WaitOne(1000)) { $connected = $true; break }
            $workerProcess.Refresh()
            if ($workerProcess.HasExited) { throw "提权 Worker 在连接管道前退出，退出码 $($workerProcess.ExitCode)。" }
        }
        if (-not $connected) { throw '提权 Worker 未能在 30 秒内连接命名管道。' }
        $pipeServer.EndWaitForConnection($pendingConnection)
        $pendingConnection.AsyncWaitHandle.Dispose()

        [uint32]$clientPid = 0
        if (-not [MklinkToolPipeNative]::GetNamedPipeClientProcessId($pipeServer.SafePipeHandle.DangerousGetHandle(), [ref]$clientPid) -or $clientPid -ne [uint32]$workerProcess.Id) {
            throw '命名管道客户端进程与本次启动的 Worker 不匹配。'
        }

        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $reader = New-Object System.IO.StreamReader($pipeServer, $utf8)
        $writer = New-Object System.IO.StreamWriter($pipeServer, $utf8)
        $writer.NewLine = [Environment]::NewLine
        $writer.AutoFlush = $true

        $helloTask = $reader.ReadLineAsync()
        if (-not $helloTask.Wait($script:WorkerReadTimeoutMs)) {
            throw '提权 Worker 未在超时时间内返回握手消息。'
        }
        $hello = $helloTask.Result
        if ([string]::IsNullOrWhiteSpace($hello) -or $hello.Length -gt 65536) {
            throw '提权 Worker 未返回有效握手消息。'
        }
        $helloMessage = $hello | ConvertFrom-Json -ErrorAction Stop
        if ([int]$helloMessage.Version -ne 1 -or [string]$helloMessage.Type -ne 'Hello' -or
            [int]$helloMessage.WorkerPid -ne $workerProcess.Id -or [int]$helloMessage.ParentPid -ne $PID) {
            throw '提权 Worker 的握手身份校验失败。'
        }

        $ack = @{ Version = 1; Type = 'HelloAck'; ParentPid = $PID } | ConvertTo-Json -Compress
        $writer.WriteLine($ack)
        $writer.Flush()

        $script:Worker = $workerProcess
        $script:WorkerPipe = $pipeServer
        $script:WorkerReader = $reader
        $script:WorkerWriter = $writer
        $script:WorkerPipeName = $pipeName
        $workerProcess = $null
        $pipeServer = $null
        $reader = $null
        $writer = $null
    } catch {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $pipeServer) { $pipeServer.Dispose() }
        if ($null -ne $pendingConnection) { try { $pendingConnection.AsyncWaitHandle.Dispose() } catch { } }
        if ($null -ne $workerProcess) {
            Stop-WorkerProcess $workerProcess
            $workerProcess.Dispose()
        }
        throw
    }
}

function Stop-WorkerProcess([System.Diagnostics.Process]$Process) {
    # 只用于空闲的 Worker（窗口关闭、连接已失效）或尚未接手任务的 Worker（握手失败），先等它自行退出。
    # 非提权的主窗口按完整性级别无法终止提权进程，taskkill 只在主窗口本身已提权时才会生效；
    # 不带 /T，即使 Worker 意外仍有引擎子进程，也不强制终止可能正在复制或切换源路径的引擎。
    try {
        if ($Process.HasExited -or $Process.WaitForExit(3000)) { return }
        $taskkill = Join-Path $env:WINDIR 'System32\taskkill.exe'
        if ([System.IO.File]::Exists($taskkill)) {
            # taskkill 失败时会写 stderr，在 Stop 偏好下会变成终止错误，必须单独捕获。
            try { & $taskkill /PID $Process.Id /F 2>&1 | Out-Null } catch { }
            if ($Process.WaitForExit(1000)) { return }
        }
        $message = '提权 Worker 未能被终止（权限不足）；它会在读到管道关闭后自行退出。'
        try {
            if ($null -ne $logTextBox) { $logTextBox.AppendText($message + [Environment]::NewLine) }
            if ($null -ne $statusLabel) { $statusLabel.Text = $message }
        } catch { }
    } catch { }
}

function Close-WorkerConnection {
    # 只断开管道、保留 Worker 进程对象：Worker 做完手头的任务后读到管道关闭就会退出，调用方可据此判断任务是否结束。
    if ($null -ne $script:WorkerWriter) { try { $script:WorkerWriter.Dispose() } catch { } }
    if ($null -ne $script:WorkerReader) { try { $script:WorkerReader.Dispose() } catch { } }
    if ($null -ne $script:WorkerPipe) { try { $script:WorkerPipe.Dispose() } catch { } }
    $script:WorkerPipe = $null
    $script:WorkerReader = $null
    $script:WorkerWriter = $null
    $script:WorkerPipeName = ''
}

function Close-ElevatedWorker {
    if ($null -ne $script:Worker -and -not $script:Worker.HasExited -and
        $null -ne $script:WorkerPipe -and $script:WorkerPipe.IsConnected -and -not $script:ActiveJob) {
        try {
            $script:WorkerWriter.WriteLine((ConvertTo-WorkerMessageJson @{ Type = 'Shutdown' }))
            $script:WorkerWriter.Flush()
        } catch { }
    }

    Close-WorkerConnection
    if ($null -ne $script:Worker) {
        Stop-WorkerProcess $script:Worker
        $script:Worker.Dispose()
    }
    $script:Worker = $null
}

function Get-CleanupCandidates {
    $script:Jobs | Where-Object { -not [string]::IsNullOrEmpty([string]$_.CleanupTarget) }
}

function Update-CleanupButton {
    $cleanupButton.Enabled = (-not $script:ActiveJob) -and (@(Get-CleanupCandidates).Count -gt 0)
}

function Set-WorkerBusy([bool]$Busy) {
    $analyzeButton.Enabled = -not $Busy
    $addButton.Enabled = -not $Busy
    $removeButton.Enabled = -not $Busy
    # 运行期间只锁定可编辑的目标列，保留表格滚动与悬停提示，便于查看各行进度与错误。
    $grid.Columns['Target'].ReadOnly = $Busy
    $browseRootButton.Enabled = -not $Busy
    $rootTextBox.Enabled = -not $Busy
    $structureCombo.Enabled = -not $Busy
    $shaCheckbox.Enabled = -not $Busy
    $deleteBackupCheckbox.Enabled = -not $Busy
    $startButton.Enabled = (-not $Busy) -and $script:PlanValid
    Update-CleanupButton
}

function Show-RestoreSummary {
    $restoredCount = @($script:WorkerItems | Where-Object { $_.Status -eq 'Restored' }).Count
    $lines = foreach ($item in $script:WorkerItems) {
        $detail = if (-not [string]::IsNullOrEmpty([string]$item.Error)) { [string]$item.Error } else { [string]$item.Warning }
        $line = '{0}：{1}' -f (Convert-StatusText ([string]$item.Status)), $item.Source
        if (-not [string]::IsNullOrEmpty($detail)) { $line += "`r`n    $detail" }
        $line
    }
    $message = $lines -join "`r`n"
    $unprocessedCount = @($script:WorkerItems | Where-Object { $_.Status -eq 'Waiting' }).Count
    if ($unprocessedCount -gt 0 -and $null -ne $script:WorkerState -and @($script:WorkerState.Errors).Count -gt 0) {
        $message += "`r`n`r`n未执行的原因：" + [string]@($script:WorkerState.Errors)[-1]
    }
    $statusLabel.Text = "中断恢复：已恢复 $restoredCount / $(@($script:WorkerItems).Count) 项。"
    [System.Windows.Forms.MessageBox]::Show($form, $message, '中断恢复结果', 'OK', 'Information') | Out-Null
}

function Complete-WorkerAction([int]$ExitCode, [string]$Message = '') {
    $completedAction = $script:WorkerAction
    $script:ActiveJob = $false
    $script:WorkerTimer.Stop()
    $progressBar.Style = 'Blocks'
    $progressBar.MarqueeAnimationSpeed = 0
    Set-WorkerBusy $false

    if ($completedAction -eq 'Migrate' -and $ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($Message)) {
        # 全部成功才移除中断恢复记录；其余情况留到下次启动，按文件系统的实际状态复查。
        Remove-RecoveryJournal $script:WorkerJournalPath
    }

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $script:PlanValid = $false
        $startButton.Enabled = $false
        $statusLabel.Text = $Message
    } elseif ($completedAction -eq 'Analyze') {
        $script:PlanValid = ($ExitCode -eq 0)
        $startButton.Enabled = $script:PlanValid
        if ($script:PlanValid) {
            $script:LastAnalysisSignature = Get-CurrentSignature
            $permissionWarningCount = Update-PermissionWarnings
            # 含中文弯引号的文本只能用单引号字符串：PowerShell 把“”当作双引号，会截断双引号字符串。
            $statusLabel.Text = if ($permissionWarningCount -gt 0) { '预检通过；其中 {0} 项的目标位置允许本机其他账户写入，悬停“状态”列可查看。' -f $permissionWarningCount } else { '预检通过。检查目标路径后可以开始迁移。' }
        } else {
            $statusLabel.Text = '预检失败。请查看表格“状态”列的错误提示和日志。'
        }
    } elseif ($completedAction -eq 'Cleanup') {
        $script:PlanValid = $false
        $startButton.Enabled = $false
        $statusLabel.Text = if ($ExitCode -eq 0) { '失败副本已清理，可以重新扫描并预检。' } else { '部分副本未能清理。请查看表格“状态”列的错误提示和日志。' }
    } elseif ($completedAction -eq 'Restore') {
        Show-RestoreSummary
    } else {
        $script:PlanValid = $false
        $startButton.Enabled = $false
        $statusLabel.Text = if ($ExitCode -eq 0) { '迁移完成。请检查每项状态和日志。' } else { '迁移未全部完成。请检查错误、备份路径和目标副本；改名前失败遗留的副本可用“清理失败副本”删除。' }
    }
    if ($completedAction -eq 'Restore') {
        # 已恢复或无需恢复的条目因原路径已存在而移出记录；恢复失败的保留，下次启动再提示。
        [void](Find-InterruptedMigrations)
    }
    if ($null -ne $script:WorkerState -and [bool]$script:WorkerState.LogIncomplete) {
        $statusLabel.Text += '（部分引擎日志未能写入）'
    }
    $script:WorkerAction = ''
    $script:WorkerItems = @()
    $script:WorkerJournalPath = ''
    $script:WorkerRequestId = ''
    $script:WorkerResultPath = ''
    $script:WorkerEnginePid = 0
    $script:WorkerEngineStartTime = ''
    $script:WorkerStatusPrefix = ''
}

function Enter-WorkerTask([string]$Action, [object[]]$Items, [string]$JournalPath, [string]$RequestId, [string]$SessionPath, [int]$EnginePid, [string]$EngineStartTime, [string]$LostReplyReason) {
    # 把界面切换到“任务进行中”：锁定会改动作业的控件，由计时器轮询会话目录直到任务结束。
    # $LostReplyReason 非空表示没收到 Worker 的任务确认，只能凭结果文件以及 Worker、引擎进程是否还在来判断任务何时结束。
    $script:WorkerAction = $Action
    $script:WorkerItems = $Items
    $script:WorkerJournalPath = $JournalPath
    $script:WorkerRequestId = $RequestId
    $script:WorkerSessionPath = $SessionPath
    $script:WorkerStatePath = Join-Path $SessionPath 'state.json'
    $script:WorkerLogPath = Join-Path $SessionPath 'engine.log'
    $script:WorkerResultPath = Join-Path $SessionPath ('result-{0}.json' -f $RequestId)
    $script:WorkerEnginePid = $EnginePid
    $script:WorkerEngineStartTime = $EngineStartTime
    $script:WorkerState = $null
    $script:LogBytesShown = 0
    $script:ActiveJob = $true
    $trackingOnly = -not [string]::IsNullOrEmpty($LostReplyReason)
    $script:WorkerStatusPrefix = if ($trackingOnly) { '未收到任务确认，正在等待任务结束：' } else { '' }

    Set-WorkerBusy $true
    # 启动时的恢复不清空日志：其中可能有启动检查写入的安全警告。
    if ($Action -ne 'Restore') { $logTextBox.Clear() }
    if ($trackingOnly) {
        $notice = '未收到提权 Worker 的任务确认：{0}任务可能已经在运行，界面会在它结束后解锁。' -f $LostReplyReason
        $statusLabel.Text = $notice
        $logTextBox.AppendText($notice + [Environment]::NewLine)
    } else {
        $statusLabel.Text = switch ($Action) {
            'Analyze' { '正在后台扫描来源并检查目标…' }
            'Migrate' { '迁移进行中…' }
            'Cleanup' { '正在清理失败副本…' }
            default { '正在恢复中断的迁移…' }
        }
    }
    $progressBar.Style = 'Marquee'
    $progressBar.MarqueeAnimationSpeed = 25
    $script:WorkerTimer.Start()
}

function Start-Worker([string]$Action, [object[]]$Items, $Config) {
    # $Items 与 $Config.Jobs 一一对应且顺序相同：引擎按此顺序回写序号，状态据此写回 $Items 中的对象。
    if (-not (Test-Path -LiteralPath $script:EnginePath -PathType Leaf)) {
        throw "找不到迁移引擎：$script:EnginePath"
    }

    $sessionName = 'mklinktool-' + [guid]::NewGuid().ToString('N')
    $sessionPath = Join-Path ([System.IO.Path]::GetTempPath()) $sessionName
    $journalPath = ''
    $requestId = [guid]::NewGuid().ToString('N')
    $requestSent = $false
    $requestRejected = $false
    try {
        [void][System.IO.Directory]::CreateDirectory($sessionPath)
        $configJson = ($Config | ConvertTo-Json -Depth 5)
        [System.IO.File]::WriteAllText((Join-Path $sessionPath 'job.json'), $configJson, [System.Text.UTF8Encoding]::new($false))

        Connect-ElevatedWorker
        if ($Action -eq 'Migrate') {
            # 必须在发出迁移请求前落盘：迁移若在“源目录改名为备份、尚未建立链接”时被断电或强制终止，
            # 下次启动据此检测并提示恢复。
            $journalPath = Write-RecoveryJournal $sessionName $Items
        }
        $request = @{
            Type = 'Execute'
            RequestId = $requestId
            Action = $Action
            SessionPath = $sessionPath
            # Worker 可能以另一个管理员账号运行（OTS 提权），其 %TEMP% 与当前用户不同；
            # 显式传入主窗口的临时根目录供 Worker 校验会话位置。
            SessionTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        }
        # 从开始写出请求起就按“可能已送达”处理：写入中途出错时，Worker 也可能已经读到完整的一行。
        $requestSent = $true
        $script:WorkerWriter.WriteLine((ConvertTo-WorkerMessageJson $request))
        $script:WorkerWriter.Flush()
        $reply = Read-WorkerMessage
        if ([string]$reply.Type -eq 'Error') {
            $requestRejected = $true
            throw "提权 Worker 拒绝了本次任务：$([string]$reply.Message)"
        }
        if ([string]$reply.Type -ne 'Accepted' -or [string]$reply.RequestId -ne $requestId -or [string]$reply.Action -ne $Action) {
            throw '提权 Worker 返回了不匹配的任务确认。'
        }
        Enter-WorkerTask $Action $Items $journalPath $requestId $sessionPath ([int]$reply.EnginePid) ([string]$reply.EngineStartTime) ''
    } catch {
        if ($requestSent -and -not $requestRejected) {
            # 请求可能已被 Worker 接手，只是确认超时、丢失或无法解析。此时解锁界面会让人以为没有任务在运行，
            # 进而重复操作或关闭窗口；改为断开连接并跟踪结果文件。Worker 做完手头的任务、读到管道关闭就会退出，
            # 所以跟踪一定会结束。会话目录与中断恢复记录都要保留。
            Close-WorkerConnection
            Enter-WorkerTask $Action $Items $journalPath $requestId $sessionPath 0 '' $_.Exception.Message
            return
        }
        # 任务没有交给 Worker（尚未发出或被明确拒绝）：不可能已在处理本会话，可安全清理会话目录与中断恢复记录。
        try { [System.IO.Directory]::Delete($sessionPath, $true) } catch { }
        Remove-RecoveryJournal $journalPath
        throw
    }
}

function Read-WorkerLogDelta {
    # 必须以 ReadWrite|Delete 共享打开：只允许读共享的句柄会让引擎同时进行的追加写因共享冲突而失败。
    # 按字节偏移增量读取，只消费到最后一个换行符，避免在半行或多字节字符中间截断。
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.FileStream]::new($script:WorkerLogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $available = $stream.Length - $script:LogBytesShown
        if ($available -le 0) { return '' }
        [void]$stream.Seek($script:LogBytesShown, [System.IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] ([int]$available)
        $count = 0
        while ($count -lt $buffer.Length) {
            $read = $stream.Read($buffer, $count, $buffer.Length - $count)
            if ($read -le 0) { break }
            $count += $read
        }
        if ($count -le 0) { return '' }
        $lastNewLine = [Array]::LastIndexOf($buffer, [byte]10, $count - 1)
        if ($lastNewLine -lt 0) { return '' }
        $script:LogBytesShown += $lastNewLine + 1
        return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $lastNewLine + 1)
    } finally {
        $stream.Dispose()
    }
}

function Update-WorkerItem($Item, $Result) {
    $Item.Status = [string]$Result.Status
    $Item.Error = [string]$Result.Error
    $Item.Warning = [string]$Result.Warning
    if ($null -ne $Result.PSObject.Properties['FileCount']) {
        $Item.FileCount = [int]$Result.FileCount
        $Item.TotalBytes = [long]$Result.TotalBytes
        $Item.JunctionCount = [int]$Result.JunctionCount
        $Item.SymbolicLinkCount = [int]$Result.SymbolicLinkCount
        $Item.AbsoluteLinkCount = [int]$Result.AbsoluteLinkCount
    }
    if ($script:WorkerAction -eq 'Migrate') {
        if ($Item.Status -in @('Failed', 'RolledBack')) {
            # 改名前失败或已回滚：来源仍完好，遗留的目标副本可用“清理失败副本”删除。
            $Item.CleanupTarget = [string]$Result.Target
        } elseif ($Item.Status -in @('Complete', 'CompleteBackupRetained')) {
            # 迁移已成功：先前记下的失败副本要么已被手动处理（甚至就是现在的目标），要么因来源已是链接而不能再自动清理。
            $Item.CleanupTarget = ''
        }
    } elseif ($script:WorkerAction -eq 'Cleanup' -and $Item.Status -eq 'Cleaned') {
        $Item.CleanupTarget = ''
    }
}

function Read-WorkerStateFile {
    # 以 ReadWrite|Delete 共享读取 state.json（引擎随时会原子替换它）；不存在或读取失败时返回 $null。
    if ([string]::IsNullOrWhiteSpace($script:WorkerStatePath) -or -not [System.IO.File]::Exists($script:WorkerStatePath)) { return $null }
    $stateStream = $null
    $stateReader = $null
    try {
        $stateShare = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stateStream = [System.IO.FileStream]::new($script:WorkerStatePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $stateShare)
        $stateReader = [System.IO.StreamReader]::new($stateStream, [System.Text.Encoding]::UTF8)
        $state = $stateReader.ReadToEnd() | ConvertFrom-Json
        if ($script:WorkerEnginePid -le 0 -and $null -ne $state.PSObject.Properties['EnginePid']) {
            # 没收到 Worker 的任务确认时，改用引擎自己写入的进程标识判断它是否仍在运行。
            $script:WorkerEnginePid = [int]$state.EnginePid
            $script:WorkerEngineStartTime = [string]$state.EngineStartTime
        }
        return $state
    } catch {
        return $null
    } finally {
        if ($null -ne $stateReader) {
            $stateReader.Dispose()
        } elseif ($null -ne $stateStream) {
            $stateStream.Dispose()
        }
    }
}

function Read-WorkerProgress {
    # 把引擎日志的新增部分与 state.json 中的进度写回界面；读取失败（文件正被替换等）留到下一次轮询。
    if (-not [string]::IsNullOrWhiteSpace($script:WorkerLogPath) -and [System.IO.File]::Exists($script:WorkerLogPath)) {
        try {
            $delta = Read-WorkerLogDelta
            if ($delta.Length -gt 0) {
                $logTextBox.AppendText($delta)
                $logTextBox.SelectionStart = $logTextBox.TextLength
                $logTextBox.ScrollToCaret()
            }
        } catch { }
    }

    $state = Read-WorkerStateFile
    if ($null -eq $state) { return }
    $script:WorkerState = $state
    try {
        foreach ($resultJob in @($state.Jobs)) {
            # 引擎按 job.json 的顺序回写序号：按序号匹配，不依赖两侧路径规范化（8.3、..、末尾点等）一致。
            if ($null -eq $resultJob.Index) { continue }
            $itemIndex = [int]$resultJob.Index
            if ($itemIndex -ge 0 -and $itemIndex -lt $script:WorkerItems.Count) {
                Update-WorkerItem $script:WorkerItems[$itemIndex] $resultJob
            }
        }
        Refresh-Grid
        if ($state.Phase) { $statusLabel.Text = $script:WorkerStatusPrefix + (Convert-StatusText ([string]$state.Phase)) }
    } catch { }
}

function Test-EngineRunning {
    # Get-Process 只列出仍在运行的进程；再核对进程名与启动时间，避免 PID 被复用后误判。
    # 不读取 HasExited：非提权的主窗口打开提权引擎时，它需要的 PROCESS_QUERY_INFORMATION 会被完整性级别拒绝，
    # 而 PowerShell 会把属性 getter 的异常静默变成 $null。WaitForExit(0) 只需 SYNCHRONIZE，且是方法调用，失败会正常抛出。
    # 判断不了时一律按“仍在运行”处理：宁可多锁定，也不在引擎还在改动目录时解锁。
    if ($script:WorkerEnginePid -le 0) { return $false }
    try {
        $engineProcess = Get-Process -Id $script:WorkerEnginePid -ErrorAction Stop
    } catch {
        return $false
    }
    try {
        if ($engineProcess.WaitForExit(0)) { return $false }
    } catch { }
    if ($engineProcess.ProcessName -ne 'powershell') { return $false }
    if ([string]::IsNullOrEmpty($script:WorkerEngineStartTime)) { return $true }
    try {
        return ([string]$engineProcess.StartTime.ToFileTime()) -eq $script:WorkerEngineStartTime
    } catch {
        return $true
    }
}

function Get-WorkerCompletion {
    # 判断当前任务是否已结束：仍在进行返回 $null；否则返回 ExitCode（未知为 $null）与需要提示的说明。
    if ([System.IO.File]::Exists($script:WorkerResultPath)) {
        try {
            $result = [System.IO.File]::ReadAllText($script:WorkerResultPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            if ([int]$result.Version -eq 1 -and [string]$result.RequestId -eq $script:WorkerRequestId -and [string]$result.Action -eq $script:WorkerAction) {
                # [int]$null 为 0，不能把缺失的退出码当成成功。
                if ($null -eq $result.ExitCode) {
                    return [pscustomobject]@{ ExitCode = $null; Message = '提权 Worker 没有取得引擎的退出码，任务结果未知；请核对日志与当前状态。' }
                }
                return [pscustomobject]@{ ExitCode = [int]$result.ExitCode; Message = '' }
            }
        } catch { }
    }
    if ($null -ne $script:Worker) {
        $script:Worker.Refresh()
        if (-not $script:Worker.HasExited) { return $null }
    }
    # Worker 已退出却没有结果：引擎不随 Worker 退出，确认它也已结束才算结束。
    if ($script:WorkerEnginePid -le 0) { [void](Read-WorkerStateFile) }
    if (Test-EngineRunning) { return $null }
    return [pscustomobject]@{ ExitCode = $null; Message = '提权 Worker 已退出且没有返回本次任务的结果；引擎进程已结束，请核对日志与当前状态。' }
}

function Update-WorkerView {
    # 必须先判定是否结束、再读取进度：Worker 在引擎退出之后才写结果文件、才会退出，所以先确认“已结束”，
    # 随后读到的就一定是最终状态与完整日志。顺序反过来，引擎的最后一次写入可能恰好落在两步之间而被永久漏掉。
    $completion = if ($script:ActiveJob) { Get-WorkerCompletion } else { $null }
    Read-WorkerProgress
    if ($null -eq $completion) { return }
    $exitCode = $completion.ExitCode
    if ($null -eq $exitCode) {
        $exitCode = if ($null -ne $script:WorkerState -and [bool]$script:WorkerState.Success) { 0 } else { 1 }
    }
    Complete-WorkerAction $exitCode $completion.Message
}
$script:WorkerTimer = New-Object System.Windows.Forms.Timer
$script:WorkerTimer.Interval = 500
$script:WorkerTimer.Add_Tick({ Update-WorkerView })

$form = New-Object System.Windows.Forms.Form
$form.Text = '目录迁移与链接工具'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1180, 790)
$form.MinimumSize = New-Object System.Drawing.Size(960, 650)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.AllowDrop = $true

$rootLabel = New-Object System.Windows.Forms.Label
$rootLabel.Text = '目标根目录'
$rootLabel.Location = New-Object System.Drawing.Point(16, 18)
$rootLabel.AutoSize = $true
$form.Controls.Add($rootLabel)

$rootTextBox = New-Object System.Windows.Forms.TextBox
$rootTextBox.Location = New-Object System.Drawing.Point(100, 14)
$rootTextBox.Size = New-Object System.Drawing.Size(700, 26)
$rootTextBox.Anchor = 'Top,Left,Right'
$form.Controls.Add($rootTextBox)

$browseRootButton = New-Object System.Windows.Forms.Button
$browseRootButton.Text = '浏览…'
$browseRootButton.Location = New-Object System.Drawing.Point(810, 12)
$browseRootButton.Size = New-Object System.Drawing.Size(82, 30)
$browseRootButton.Anchor = 'Top,Right'
$form.Controls.Add($browseRootButton)

$structureLabel = New-Object System.Windows.Forms.Label
$structureLabel.Text = '目标结构'
$structureLabel.Location = New-Object System.Drawing.Point(16, 55)
$structureLabel.AutoSize = $true
$form.Controls.Add($structureLabel)

$structureCombo = New-Object System.Windows.Forms.ComboBox
$structureCombo.DropDownStyle = 'DropDownList'
$structureCombo.Items.Add('平铺：根目录\来源目录名') | Out-Null
$structureCombo.Items.Add('分类：父目录或盘符-来源名日期\来源目录名') | Out-Null
$structureCombo.SelectedIndex = 1
$structureCombo.Location = New-Object System.Drawing.Point(100, 51)
$structureCombo.Size = New-Object System.Drawing.Size(300, 28)
$form.Controls.Add($structureCombo)

$linkTypeLabel = New-Object System.Windows.Forms.Label
$linkTypeLabel.Text = '链接类型'
$linkTypeLabel.Location = New-Object System.Drawing.Point(422, 55)
$linkTypeLabel.AutoSize = $true
$form.Controls.Add($linkTypeLabel)

$linkTypeValueLabel = New-Object System.Windows.Forms.Label
$linkTypeValueLabel.Text = 'SymbolicLink'
$linkTypeValueLabel.Location = New-Object System.Drawing.Point(493, 55)
$linkTypeValueLabel.Size = New-Object System.Drawing.Size(160, 24)
$form.Controls.Add($linkTypeValueLabel)

$linkHintLabel = New-Object System.Windows.Forms.Label
$linkHintLabel.Text = '顶层使用 SymbolicLink；首次预检会请求一次管理员权限。'
$linkHintLabel.Location = New-Object System.Drawing.Point(666, 55)
$linkHintLabel.Size = New-Object System.Drawing.Size(480, 24)
$linkHintLabel.Anchor = 'Top,Left,Right'
$form.Controls.Add($linkHintLabel)

$addButton = New-Object System.Windows.Forms.Button
$addButton.Text = '添加来源文件夹…'
$addButton.Location = New-Object System.Drawing.Point(16, 93)
$addButton.Size = New-Object System.Drawing.Size(150, 32)
$form.Controls.Add($addButton)

$removeButton = New-Object System.Windows.Forms.Button
$removeButton.Text = '移除选中项'
$removeButton.Location = New-Object System.Drawing.Point(175, 93)
$removeButton.Size = New-Object System.Drawing.Size(115, 32)
$form.Controls.Add($removeButton)

$shaCheckbox = New-Object System.Windows.Forms.CheckBox
$shaCheckbox.Text = '附加 SHA-256 校验（耗时较长）'
$shaCheckbox.AutoSize = $true
$shaCheckbox.Location = New-Object System.Drawing.Point(315, 100)
$form.Controls.Add($shaCheckbox)

$deleteBackupCheckbox = New-Object System.Windows.Forms.CheckBox
$deleteBackupCheckbox.Text = '链接验证成功后删除源备份'
$deleteBackupCheckbox.Checked = $true
$deleteBackupCheckbox.AutoSize = $true
$deleteBackupCheckbox.Location = New-Object System.Drawing.Point(560, 100)
$form.Controls.Add($deleteBackupCheckbox)

$analyzeButton = New-Object System.Windows.Forms.Button
$analyzeButton.Text = '扫描并预检'
$analyzeButton.Location = New-Object System.Drawing.Point(16, 136)
$analyzeButton.Size = New-Object System.Drawing.Size(120, 34)
$form.Controls.Add($analyzeButton)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = '开始迁移'
$startButton.Location = New-Object System.Drawing.Point(147, 136)
$startButton.Size = New-Object System.Drawing.Size(120, 34)
$startButton.Enabled = $false
$form.Controls.Add($startButton)

$openLogsButton = New-Object System.Windows.Forms.Button
$openLogsButton.Text = '打开日志目录'
$openLogsButton.Location = New-Object System.Drawing.Point(278, 136)
$openLogsButton.Size = New-Object System.Drawing.Size(120, 34)
$form.Controls.Add($openLogsButton)

$cleanupButton = New-Object System.Windows.Forms.Button
$cleanupButton.Text = '清理失败副本'
$cleanupButton.Location = New-Object System.Drawing.Point(409, 136)
$cleanupButton.Size = New-Object System.Drawing.Size(120, 34)
$cleanupButton.Enabled = $false
$form.Controls.Add($cleanupButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = '可将一个或多个来源文件夹直接拖入窗口，或使用“添加来源文件夹”。'
$statusLabel.Location = New-Object System.Drawing.Point(540, 144)
$statusLabel.Size = New-Object System.Drawing.Size(606, 22)
$statusLabel.Anchor = 'Top,Left,Right'
$form.Controls.Add($statusLabel)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(16, 182)
$grid.AllowDrop = $true
$grid.Size = New-Object System.Drawing.Size(1130, 330)
$grid.Anchor = 'Top,Bottom,Left,Right'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $true
$grid.AutoSizeColumnsMode = 'Fill'
$grid.BackgroundColor = [System.Drawing.SystemColors]::Window
$grid.Columns.Add('Source', '来源路径') | Out-Null
$grid.Columns.Add('Target', '目标路径（可编辑）') | Out-Null
$grid.Columns.Add('FileCount', '文件数') | Out-Null
$grid.Columns.Add('Size', '预估大小') | Out-Null
$grid.Columns.Add('JunctionCount', '内部 Junction') | Out-Null
$grid.Columns.Add('SymbolicLinkCount', '内部符号链接') | Out-Null
$grid.Columns.Add('Status', '状态') | Out-Null
$grid.Columns['Source'].FillWeight = 29
$grid.Columns['Target'].FillWeight = 36
$grid.Columns['FileCount'].FillWeight = 7
$grid.Columns['Size'].FillWeight = 8
$grid.Columns['JunctionCount'].FillWeight = 8
$grid.Columns['SymbolicLinkCount'].FillWeight = 9
$grid.Columns['Status'].FillWeight = 11
$grid.Columns['Source'].ReadOnly = $true
$grid.Columns['Target'].ReadOnly = $false
$grid.Columns['FileCount'].ReadOnly = $true
$grid.Columns['Size'].ReadOnly = $true
$grid.Columns['JunctionCount'].ReadOnly = $true
$grid.Columns['SymbolicLinkCount'].ReadOnly = $true
$grid.Columns['Status'].ReadOnly = $true
# 禁用列排序：就地刷新假设行序与 $script:Jobs 严格一致，点表头排序会导致错位。
foreach ($column in $grid.Columns) { $column.SortMode = 'NotSortable' }
# 开启双缓冲，消除定时刷新带来的闪烁（属性为 protected，经反射打开）。
[Windows.Forms.DataGridView].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($grid, $true, $null)
$form.Controls.Add($grid)

$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = '运行日志'
$logLabel.Location = New-Object System.Drawing.Point(16, 526)
$logLabel.AutoSize = $true
$logLabel.Anchor = 'Bottom,Left'
$form.Controls.Add($logLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(96, 523)
$progressBar.Size = New-Object System.Drawing.Size(1050, 24)
$progressBar.Anchor = 'Bottom,Left,Right'
$progressBar.Style = 'Blocks'
$form.Controls.Add($progressBar)

$logTextBox = New-Object System.Windows.Forms.TextBox
$logTextBox.Location = New-Object System.Drawing.Point(16, 555)
$logTextBox.Size = New-Object System.Drawing.Size(1130, 180)
$logTextBox.Anchor = 'Bottom,Left,Right'
$logTextBox.Multiline = $true
$logTextBox.ReadOnly = $true
$logTextBox.ScrollBars = 'Vertical'
$logTextBox.WordWrap = $false
$logTextBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($logTextBox)

$interactionToolTip = New-Object System.Windows.Forms.ToolTip
$interactionToolTip.SetToolTip($grid, 'Ctrl+单击或 Shift+单击可多选；右键来源或目标路径可打开菜单。')
$interactionToolTip.SetToolTip($addButton, '添加一个或多个文件夹；也可以从资源管理器直接拖入窗口或列表。')
$interactionToolTip.SetToolTip($cleanupButton, '删除迁移在改名前失败或已回滚后遗留的目标副本；只在来源仍完好保留在原位置时才会删除。')

# 启动时检查工具目录与脚本的写入权限：会被提权运行的脚本若可被其他账户修改，就构成提权执行面。
$toolTamperWarning = Get-ToolTamperWarning
if (-not [string]::IsNullOrEmpty($toolTamperWarning)) {
    $linkHintLabel.Text = '安全警告：工具目录可被其他账户修改，悬停查看详情。'
    $linkHintLabel.ForeColor = [System.Drawing.Color]::Firebrick
    $interactionToolTip.SetToolTip($linkHintLabel, $toolTamperWarning)
    $logTextBox.AppendText('安全警告：' + $toolTamperWarning + [Environment]::NewLine)
}



$folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
$folderDialog.ShowNewFolderButton = $false

$pathContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$openPathMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('打开此目录')
$copyPathMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('复制文件夹路径')
$resetTargetMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('重置目标为自动生成')
$removePathMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('移除此项')
[void]$pathContextMenu.Items.Add($openPathMenuItem)
[void]$pathContextMenu.Items.Add($copyPathMenuItem)
[void]$pathContextMenu.Items.Add($resetTargetMenuItem)
[void]$pathContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$pathContextMenu.Items.Add($removePathMenuItem)

$resetTargetMenuItem.Add_Click({
    if (Test-WorkerActive) { return }
    $resetCount = 0
    foreach ($row in $grid.SelectedRows) {
        $job = $row.Tag
        if ($null -eq $job) { continue }
        $job.IsCustomTarget = $false
        $job.Target = Get-GeneratedTarget -Source $job.Source -Root $rootTextBox.Text -Mode (Get-StructureMode)
        $resetCount++
    }
    if ($resetCount -gt 0) {
        Set-PlanStale ("已将 {0} 项目标重置为自动生成，请重新扫描并预检。" -f $resetCount)
    }
})

$openPathMenuItem.Add_Click({
    $path = $script:ContextPath
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    if (-not [System.IO.Directory]::Exists($path)) {
        [System.Windows.Forms.MessageBox]::Show("目录尚不存在：`r`n$path", 'mklinktool', 'OK', 'Information') | Out-Null
        return
    }
    try {
        Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('"' + $path.TrimEnd('\') + '"') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'mklinktool', 'OK', 'Error') | Out-Null
    }
})

$copyPathMenuItem.Add_Click({
    if ([string]::IsNullOrWhiteSpace($script:ContextPath)) { return }
    try {
        [System.Windows.Forms.Clipboard]::SetText($script:ContextPath)
        $statusLabel.Text = '已复制文件夹路径。'
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'mklinktool', 'OK', 'Error') | Out-Null
    }
})

$removePathMenuItem.Add_Click({ Remove-SelectedJobs })


$browseRootButton.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($rootTextBox.Text) -and [System.IO.Directory]::Exists($rootTextBox.Text)) {
        $folderDialog.SelectedPath = $rootTextBox.Text
    }
    $folderDialog.Description = '选择迁移数据的目标根目录'
    if ($folderDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $rootTextBox.Text = $folderDialog.SelectedPath
    }
})

$rootTextBox.Add_TextChanged({ Update-GeneratedTargets '目标根目录已更改，请重新扫描并预检。' })
$structureCombo.Add_SelectedIndexChanged({ Update-GeneratedTargets '目标结构已更改，请重新扫描并预检。' })

$addButton.Add_Click({
    $folderDialog.Description = '选择要迁移的来源文件夹'
    $folderDialog.SelectedPath = ''
    if ($folderDialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    Add-SourcePaths -Paths @($folderDialog.SelectedPath)
})

$removeButton.Add_Click({ Remove-SelectedJobs })

$grid.Add_CellMouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Right -or $eventArgs.RowIndex -lt 0 -or $eventArgs.ColumnIndex -lt 0) { return }
    $columnName = $grid.Columns[$eventArgs.ColumnIndex].Name
    if ($columnName -ne 'Source' -and $columnName -ne 'Target') { return }

    $clickedRow = $grid.Rows[$eventArgs.RowIndex]
    if (-not $clickedRow.Selected) {
        $grid.ClearSelection()
        $clickedRow.Selected = $true
    }
    $grid.CurrentCell = $clickedRow.Cells[$eventArgs.ColumnIndex]
    $script:ContextPath = [string]$clickedRow.Cells[$columnName].Value
    $removePathMenuItem.Text = if ($grid.SelectedRows.Count -gt 1) { '移除所选 {0} 项' -f $grid.SelectedRows.Count } else { '移除此项' }
    $removePathMenuItem.Enabled = -not (Test-WorkerActive)
    $resetTargetMenuItem.Enabled = -not (Test-WorkerActive)
    $openPathMenuItem.Enabled = -not [string]::IsNullOrWhiteSpace($script:ContextPath)
    $copyPathMenuItem.Enabled = -not [string]::IsNullOrWhiteSpace($script:ContextPath)
    # CellMouseDown 的 X/Y 相对于单元格而不是表格，直接在光标处弹出菜单。
    $pathContextMenu.Show([System.Windows.Forms.Cursor]::Position)
})

$grid.Add_CellEndEdit({
    param($sender, $eventArgs)
    if ($eventArgs.RowIndex -lt 0 -or $eventArgs.ColumnIndex -ne $grid.Columns['Target'].Index) { return }
    $job = $grid.Rows[$eventArgs.RowIndex].Tag
    $targetCell = $grid.Rows[$eventArgs.RowIndex].Cells['Target']
    # 仅归一首尾空白、斜杠方向与末尾反斜杠；不调用 GetFullPath，避免把相对路径绑定到 GUI 进程 cwd 而绕过引擎的明确拒绝。
    $editedTarget = ([string]$targetCell.Value).Trim().Replace('/', '\').TrimEnd('\')
    if ([string]::Equals($editedTarget, [string]$job.Target, [System.StringComparison]::OrdinalIgnoreCase)) {
        # 进入编辑后未改动（含按 Esc 取消）也会触发 CellEndEdit：不标记为自定义，也不作废预检结果。
        $targetCell.Value = $job.Target
        return
    }
    if ([string]::IsNullOrEmpty($editedTarget)) {
        # 清空目标视为恢复自动生成。
        $job.IsCustomTarget = $false
        $job.Target = Get-GeneratedTarget -Source $job.Source -Root $rootTextBox.Text -Mode (Get-StructureMode)
    } else {
        $job.IsCustomTarget = $true
        $job.Target = $editedTarget
    }
    $targetCell.Value = $job.Target
    $job.Status = 'NotChecked'
    $job.Error = ''
    Set-PlanStale '目标路径已手动调整，请重新扫描并预检。'
})

$analyzeButton.Add_Click({
    if ($script:Jobs.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('请先添加至少一个来源目录。', 'mklinktool', 'OK', 'Warning') | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($rootTextBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show('请先选择目标根目录。', 'mklinktool', 'OK', 'Warning') | Out-Null
        return
    }
    try {
        Start-Worker 'Analyze' @($script:Jobs) (Get-WorkerConfig)
    } catch {
        $statusLabel.Text = '无法启动提权 Worker 或预检任务。'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'mklinktool', 'OK', 'Error') | Out-Null
        return
    }
    # 任务被接受后才清空上一轮结果：启动失败（如取消 UAC）时保留原有数据与状态，确认框中的统计不会变成 0。
    # 计时器的首次刷新发生在本处理程序返回之后，不会与这里的清空交错。
    foreach ($job in $script:Jobs) {
        $job.Status = 'Queued'
        $job.Error = ''
        $job.Warning = ''
        $job.PermissionWarning = ''
        $job.FileCount = 0
        $job.TotalBytes = 0L
        $job.JunctionCount = 0
        $job.SymbolicLinkCount = 0
        $job.AbsoluteLinkCount = 0
    }
    Refresh-Grid
})

$startButton.Add_Click({
    if (-not $script:PlanValid -or $script:LastAnalysisSignature -ne (Get-CurrentSignature)) {
        Set-PlanStale '当前设置与最近一次预检不一致，请重新扫描。'
        return
    }
    $totalBytes = [long]0
    $totalJunctions = 0
    $totalSymbolicLinks = 0
    $totalAbsoluteLinks = 0
    foreach ($job in $script:Jobs) {
        $totalBytes += [long]$job.TotalBytes
        $totalJunctions += [int]$job.JunctionCount
        $totalSymbolicLinks += [int]$job.SymbolicLinkCount
        $totalAbsoluteLinks += [int]$job.AbsoluteLinkCount
    }
    $backupAction = if ($deleteBackupCheckbox.Checked) { '链接验证成功后会删除同目录迁移备份。' } else { '链接验证成功后会保留同目录迁移备份。' }
    $nestedLinkNotice = ''
    if (($totalJunctions + $totalSymbolicLinks) -gt 0) {
        $nestedLinkNotice = "`r`n来源中有 $totalJunctions 个目录 Junction 和 $totalSymbolicLinks 个目录 SymbolicLink；迁移会保留链接本身，不复制它们指向的内容。"
        if ($totalAbsoluteLinks -gt 0) {
            $nestedLinkNotice += "`r`n其中 $totalAbsoluteLinks 个绝对目标链接依赖原来源路径持续保留为顶层 SymbolicLink。"
        }
    }
    $permissionWarningCount = @($script:Jobs | Where-Object { -not [string]::IsNullOrEmpty([string]$_.PermissionWarning) }).Count
    $permissionNotice = if ($permissionWarningCount -gt 0) { "`r`n" + ('其中 {0} 项的目标位置允许本机其他账户写入（工具不复制源目录权限），详见“状态”列提示。' -f $permissionWarningCount) } else { '' }
    $summary = "即将处理 $($script:Jobs.Count) 个目录，总计约 $(Format-Bytes $totalBytes)。`r`n顶层链接类型：SymbolicLink。$nestedLinkNotice$permissionNotice`r`n$backupAction`r`n`r`n目标路径和源路径都将按当前表格内容处理。确认开始？"
    $answer = [System.Windows.Forms.MessageBox]::Show($summary, '确认迁移', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        Start-Worker 'Migrate' @($script:Jobs) (Get-WorkerConfig)
    } catch {
        $statusLabel.Text = '无法启动提权 Worker 或迁移任务。'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'mklinktool', 'OK', 'Error') | Out-Null
    }
})

$cleanupButton.Add_Click({
    $candidates = @(Get-CleanupCandidates)
    if ($candidates.Count -eq 0) { return }
    $listed = @($candidates | Select-Object -First 8 | ForEach-Object { $_.CleanupTarget })
    $more = if ($candidates.Count -gt $listed.Count) { "`r`n…等共 $($candidates.Count) 项" } else { '' }
    $message = "以下目标副本是迁移在改名前失败或已回滚后遗留的，对应来源仍在原位置：`r`n" + ($listed -join "`r`n") + $more +
        "`r`n`r`n删除前引擎会再次确认：来源仍是原路径上的普通目录、不存在迁移备份、副本本身不是链接；不满足的项不会删除。需要管理员权限。`r`n确认删除这些副本？"
    if ([System.Windows.Forms.MessageBox]::Show($message, '清理失败副本', 'YesNo', 'Warning') -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $config = [pscustomobject]@{ Jobs = @($candidates | ForEach-Object { [pscustomobject]@{ Source = $_.Source; Target = $_.CleanupTarget } }) }
    try {
        Start-Worker 'Cleanup' $candidates $config
    } catch {
        $statusLabel.Text = '无法启动提权 Worker 或清理任务。'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'mklinktool', 'OK', 'Error') | Out-Null
    }
})

$openLogsButton.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($script:WorkerSessionPath) -and [System.IO.Directory]::Exists($script:WorkerSessionPath)) {
        Start-Process -FilePath explorer.exe -ArgumentList ('"' + $script:WorkerSessionPath + '"') | Out-Null
    } else {
        [System.Windows.Forms.MessageBox]::Show('完成一次扫描或迁移后，这里会打开本次日志目录。', 'mklinktool', 'OK', 'Information') | Out-Null
    }
})

$dragEnterHandler = {
    param($sender, $eventArgs)
    # 运行期间表格保持可用（便于滚动查看），因此在这里显式拒绝拖放。
    if (-not (Test-WorkerActive) -and $eventArgs.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    } else {
        $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::None
    }
}
$dragDropHandler = {
    param($sender, $eventArgs)
    try {
        $paths = [string[]]$eventArgs.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
        if ($paths.Count -gt 0) {
            Add-SourcePaths -Paths $paths
            $statusLabel.Text = "已接收拖入的 $($paths.Count) 个路径；请检查列表并扫描预检。"
        }
    } catch {
        $message = '无法导入拖入的文件夹：' + [Environment]::NewLine + $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show($message, 'mklinktool', 'OK', 'Error') | Out-Null
    }
}
$form.Add_DragEnter($dragEnterHandler)
$form.Add_DragDrop($dragDropHandler)
$grid.Add_DragEnter($dragEnterHandler)
$grid.Add_DragDrop($dragDropHandler)
$form.Add_Shown({
    # 检测上次在“源目录已改名为备份、尚未创建链接”时中断（断电、强制结束）的迁移，提示把备份改回原路径。
    $interrupted = @(Find-InterruptedMigrations)
    if ($interrupted.Count -eq 0) { return }
    $listed = @($interrupted | Select-Object -First 6 | ForEach-Object { "原路径：$($_.Source)`r`n备份：$($_.Source)_migration_backup" })
    $more = if ($interrupted.Count -gt $listed.Count) { "`r`n`r`n…等共 $($interrupted.Count) 项" } else { '' }
    $newLine = [Environment]::NewLine
    $message = ('检测到 {0} 项迁移在“源目录已改名为备份、尚未创建链接”时中断，原路径目前不存在：' -f $interrupted.Count) + $newLine + $newLine +
        ($listed -join ($newLine + $newLine)) + $more + $newLine + $newLine +
        '是否现在把备份改回原路径？需要管理员权限，恢复前会再次确认原路径仍为空。' + $newLine +
        '选择“否”不做任何改动，下次启动会再次提示；也可以按 README 的“中断恢复”手动处理。'
    if ([System.Windows.Forms.MessageBox]::Show($form, $message, '检测到中断的迁移', 'YesNo', 'Warning') -ne [System.Windows.Forms.DialogResult]::Yes) {
        $statusLabel.Text = "有 $($interrupted.Count) 项中断的迁移尚未恢复，下次启动会再次提示。"
        return
    }
    $config = [pscustomobject]@{ Jobs = @($interrupted | ForEach-Object { [pscustomobject]@{ Source = $_.Source; Target = $_.Target } }) }
    try {
        Start-Worker 'Restore' $interrupted $config
    } catch {
        $statusLabel.Text = '无法启动提权 Worker 或恢复任务；下次启动会再次提示。'
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'mklinktool', 'OK', 'Error') | Out-Null
    }
})
$form.Add_FormClosing({
    param($sender, $eventArgs)
    # 系统关机时必须放行，否则会阻止 Windows 正常关机。
    if ($eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::WindowsShutDown) { return }
    if (Test-WorkerActive) {
        $eventArgs.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show('后台扫描或迁移仍在运行。为避免中断复制或源目录切换，请等待当前步骤结束后再关闭窗口。', 'mklinktool', 'OK', 'Warning') | Out-Null
    }
})
$form.Add_FormClosed({ Close-ElevatedWorker })
[void]$form.ShowDialog()