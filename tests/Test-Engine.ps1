# 引擎端到端与故障注入测试。需要 Windows PowerShell 5.1，并开启开发者模式（或以管理员身份运行）以创建目录符号链接。
# 每个用例使用独立目录和一份引擎副本；故障注入的做法是在副本里找到唯一匹配的一行代码，在其前后插入或直接替换为测试代码。
# 非提权运行时 Robocopy 无法复制嵌套符号链接，因此来源树里的嵌套链接一律用 Junction。
param([string]$EnginePath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
if ([string]::IsNullOrEmpty($EnginePath)) { $EnginePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'migration-engine.ps1' }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$engineText = [System.IO.File]::ReadAllText($EnginePath, [System.Text.Encoding]::UTF8)
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mkl-engine-tests-' + [guid]::NewGuid().ToString('N'))

function New-Case([string]$Name) {
    $caseDir = Join-Path $testRoot $Name
    [void][System.IO.Directory]::CreateDirectory($caseDir)
    return $caseDir
}

function New-EngineCopy([string]$CaseDir, [string]$Anchor, [string]$Injection, [ValidateSet('Before', 'After', 'Replace', 'None')][string]$Mode) {
    $text = $engineText
    if ($Mode -ne 'None') {
        $replacement = switch ($Mode) {
            'Before' { $Injection + "`n" + $Anchor }
            'After' { $Anchor + "`n" + $Injection }
            'Replace' { $Injection }
        }
        $text = Set-UniqueText $text $Anchor $replacement
    }
    $path = Join-Path $CaseDir 'engine.ps1'
    [System.IO.File]::WriteAllText($path, $text, $utf8Bom)
    return $path
}

function New-Junction([string]$Path, [string]$Target) {
    $null = & cmd.exe /c mklink /J $Path $Target
    if (-not [System.IO.Directory]::Exists($Path)) { throw "Failed to create junction: $Path" }
}

function New-SourceTree([string]$Root) {
    # a.txt / sub\b.txt / ro.txt（只读）/ rodir\c.txt（只读目录）/ jn -> sub（绝对目标的 Junction）
    [void][System.IO.Directory]::CreateDirectory((Join-Path $Root 'sub'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $Root 'rodir'))
    [System.IO.File]::WriteAllText((Join-Path $Root 'a.txt'), 'AAAAA', $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $Root 'sub\b.txt'), 'BBBBBBB', $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $Root 'ro.txt'), 'readonly', $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $Root 'rodir\c.txt'), 'C', $utf8NoBom)
    [System.IO.File]::SetAttributes((Join-Path $Root 'ro.txt'), [System.IO.FileAttributes]::ReadOnly)
    [System.IO.File]::SetAttributes((Join-Path $Root 'rodir'), [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReadOnly)
    New-Junction (Join-Path $Root 'jn') (Join-Path $Root 'sub')
    # 让原始时间戳明显早于测试中的改写。
    foreach ($file in [System.IO.Directory]::GetFiles($Root, '*', [System.IO.SearchOption]::TopDirectoryOnly)) {
        $attributes = [System.IO.File]::GetAttributes($file)
        [System.IO.File]::SetAttributes($file, [System.IO.FileAttributes]::Normal)
        [System.IO.File]::SetLastWriteTimeUtc($file, [DateTime]::UtcNow.AddHours(-2))
        [System.IO.File]::SetAttributes($file, $attributes)
    }
}

function Invoke-Engine([string]$CaseDir, [string]$Action, [object[]]$Jobs, [bool]$DeleteBackup = $true, [string]$Anchor = '', [string]$Injection = '', [string]$Mode = 'None', [switch]$KeepSourcePermissions) {
    $config = [pscustomobject]@{ LinkType = 'SymbolicLink'; VerifySha256 = $false; DeleteBackup = $DeleteBackup; Jobs = @($Jobs) }
    # 只在需要时才加这一项：其余用例的 job.json 没有它，顺带验证引擎能处理旧格式。
    if ($KeepSourcePermissions) { $config | Add-Member -NotePropertyName KeepSourcePermissions -NotePropertyValue $true }
    [System.IO.File]::WriteAllText((Join-Path $CaseDir 'job.json'), ($config | ConvertTo-Json -Depth 5), $utf8NoBom)
    $engine = New-EngineCopy $CaseDir $Anchor $Injection $Mode
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -Action $Action -ConfigPath (Join-Path $CaseDir 'job.json') -StatePath (Join-Path $CaseDir 'state.json') -LogPath (Join-Path $CaseDir 'engine.log') -RobocopyLogPath (Join-Path $CaseDir 'robocopy.log') | Out-Null
    $exitCode = $LASTEXITCODE
    $state = [System.IO.File]::ReadAllText((Join-Path $CaseDir 'state.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $log = [System.IO.File]::ReadAllText((Join-Path $CaseDir 'engine.log'), [System.Text.Encoding]::UTF8)
    return [pscustomobject]@{ Dir = $CaseDir; ExitCode = $exitCode; State = $state; Log = $log; Jobs = @($Jobs) }
}

function Invoke-EngineCase([string]$Name, [int]$JobCount = 1, [bool]$DeleteBackup = $true, [string]$Anchor = '', [string]$Injection = '', [string]$Mode = 'None', [string]$Action = 'Migrate') {
    # 为每项作业生成一棵标准来源树，再以指定动作运行引擎。
    $caseDir = New-Case $Name
    $jobs = @()
    for ($i = 1; $i -le $JobCount; $i++) {
        $source = Join-Path $caseDir "src\data$i"
        New-SourceTree $source
        $jobs += [pscustomobject]@{ Source = $source; Target = (Join-Path $caseDir "dst\data$i") }
    }
    return Invoke-Engine $caseDir $Action $jobs $DeleteBackup $Anchor $Injection $Mode
}

function Get-LinkInfo([string]$Path) {
    $info = [System.IO.DirectoryInfo]::new($Path)
    $target = $info.Target
    if ($target -is [array]) { $target = $target[0] }
    return [pscustomobject]@{ Exists = $info.Exists; LinkType = [string]$info.LinkType; Target = [string]$target }
}

function Test-NormalDirectory([string]$Path) {
    if (-not [System.IO.Directory]::Exists($Path)) { return $false }
    return (([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)
}

function New-TextFile([string]$Path, [string]$Text) {
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Get-AccessRuleSet([string]$Path) {
    # 访问规则的集合（不看是否继承而来），用于比较两处的权限是否一致。
    $security = if ([System.IO.Directory]::Exists($Path)) { [System.IO.Directory]::GetAccessControl($Path) } else { [System.IO.File]::GetAccessControl($Path) }
    $rules = foreach ($rule in $security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        '{0}|{1}|{2}|{3}|{4}' -f $rule.IdentityReference.Value, [int]$rule.FileSystemRights, $rule.InheritanceFlags, $rule.PropagationFlags, $rule.AccessControlType
    }
    return (@($rules | Sort-Object) -join ';')
}

function Get-UncPathForLocal([string]$Path) {
    # 经本机 Users 共享访问 %TEMP% 下的路径；没有这个共享时返回空串。
    $usersRoot = Join-Path $env:SystemDrive 'Users'
    if (-not $Path.StartsWith($usersRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return '' }
    $unc = '\\localhost\Users' + $Path.Substring($usersRoot.Length)
    try { if ([System.IO.Directory]::Exists($unc)) { return $unc } } catch { }
    return ''
}

function Get-VolumeSerial([string]$Path) {
    # 用 vol 命令取路径所在盘的卷序列号（与引擎的查询方式无关，作对照），返回 8 位十六进制；取不到时返回空串。
    # 序列号在卷标之后输出，取最后一个匹配，卷标本身像序列号时也不会取错。
    $output = (& cmd.exe /c vol ([System.IO.Path]::GetPathRoot($Path).TrimEnd('\'))) | Out-String
    $found = [regex]::Matches($output, '([0-9A-F]{4})-([0-9A-F]{4})')
    if ($found.Count -eq 0) { return '' }
    return $found[$found.Count - 1].Groups[1].Value + $found[$found.Count - 1].Groups[2].Value
}

function New-TargetVolumeInjection([string]$IsFixed = '$true', [string]$FileSystem = 'NTFS', [string]$AvailableBytes = '1TB') {
    # 替换 Get-TargetVolumeInfo 查询到的卷信息（本机的卷都是 NTFS 固定磁盘）；Path 用本机不存在的目录，便于在提示中认出它。
    return "`$volume = [pscustomobject]@{ Path = 'X:\injected'; IsRemote = `$false; IsFixed = $IsFixed; FileSystem = '$FileSystem'; Flags = [uint32]0; SerialNumber = [uint32]1; AvailableBytes = [long]$AvailableBytes }"
}

# 下面的注入代码在引擎的 Invoke-Migration 作用域内运行，可直接使用 $source、$backup。
$writeSourceSameSize = "[System.IO.File]::WriteAllText((Join-Path `$source 'a.txt'), 'ZZZZZ'); [System.IO.File]::SetLastWriteTimeUtc((Join-Path `$source 'a.txt'), [DateTime]::UtcNow)"
$writeBackupSameSize = "[System.IO.File]::WriteAllText((Join-Path `$backup 'a.txt'), 'ZZZZZ'); [System.IO.File]::SetLastWriteTimeUtc((Join-Path `$backup 'a.txt'), [DateTime]::UtcNow)"

[void][System.IO.Directory]::CreateDirectory($testRoot)
try {
    '[E1] Migrate success, delete backup, nested junction + read-only file/dir'
    $r = Invoke-EngineCase 'e1'
    $job = @($r.State.Jobs)[0]
    $link = Get-LinkInfo $r.Jobs[0].Source
    Assert ($r.ExitCode -eq 0) 'exit code 0' "exit=$($r.ExitCode) errors=$(@($r.State.Errors) -join ' | ')"
    Assert ($job.Status -eq 'Complete') 'status Complete' "status=$($job.Status) error=$($job.Error)"
    Assert ($link.LinkType -eq 'SymbolicLink' -and $link.Target -eq $r.Jobs[0].Target) 'source is symlink to target' "$($link.LinkType) -> $($link.Target)"
    Assert (-not [System.IO.Directory]::Exists($r.Jobs[0].Source + '_migration_backup')) 'backup deleted'
    Assert ([System.IO.File]::ReadAllText((Join-Path $r.Jobs[0].Target 'a.txt')) -eq 'AAAAA') 'target content'
    Assert ((Get-LinkInfo (Join-Path $r.Jobs[0].Target 'jn')).LinkType -eq 'Junction') 'nested junction kept'
    Assert ([int]$r.State.EnginePid -gt 0 -and -not [string]::IsNullOrEmpty([string]$r.State.EngineStartTime)) 'state has EnginePid/EngineStartTime'
    Assert ($r.Log.Contains('文件大小和修改时间')) 'NTFS target: mtime compared'
    $robocopyLog = [System.IO.File]::ReadAllText((Join-Path $r.Dir 'robocopy.log'))
    Assert (-not $robocopyLog.Contains('a.txt')) 'robocopy log does not list copied files (/NFL)'

    '[E2] Migrate success, keep backup'
    $r = Invoke-EngineCase 'e2' -DeleteBackup $false
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 0 -and $job.Status -eq 'CompleteBackupRetained') 'status CompleteBackupRetained' "exit=$($r.ExitCode) status=$($job.Status) error=$($job.Error)"
    Assert (Test-NormalDirectory ($r.Jobs[0].Source + '_migration_backup')) 'backup retained'

    '[E3] Same-size write after robocopy, before source snapshot -> copy verification fails on mtime'
    $r = Invoke-EngineCase 'e3' -Anchor '$sourceSnapshot = Get-TreeSnapshot -Path $source -IncludeHash:([bool]$Config.VerifySha256)' -Injection $writeSourceSameSize -Mode Before
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 1 -and $job.Status -eq 'Failed') 'status Failed' "exit=$($r.ExitCode) status=$($job.Status) error=$($job.Error)"
    Assert ($job.Error.Contains('修改时间') -and $job.Error.Contains('a.txt')) 'error names the mtime mismatch of a.txt' $job.Error
    Assert ((Test-NormalDirectory $r.Jobs[0].Source) -and [System.IO.File]::ReadAllText((Join-Path $r.Jobs[0].Source 'a.txt')) -eq 'ZZZZZ') 'source intact with the new content'
    Assert (-not [System.IO.Directory]::Exists($r.Jobs[0].Source + '_migration_backup')) 'no backup created'

    '[E4] Same-size write after verification, before rename -> rolled back after the link check'
    $r = Invoke-EngineCase 'e4' -JobCount 2 -Anchor "`$analysis.Status = 'RenamingSource'" -Injection $writeSourceSameSize -Mode Before
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 1 -and $job.Status -eq 'RolledBack') 'status RolledBack' "exit=$($r.ExitCode) status=$($job.Status) error=$($job.Error)"
    Assert ($job.Error.Contains('仍被写入') -and $job.Error.Contains('修改时间')) 'error explains the write' $job.Error
    Assert ((Test-NormalDirectory $r.Jobs[0].Source) -and [System.IO.File]::ReadAllText((Join-Path $r.Jobs[0].Source 'a.txt')) -eq 'ZZZZZ') 'source restored with the newer content'
    Assert ([System.IO.File]::ReadAllText((Join-Path $r.Jobs[0].Target 'a.txt')) -eq 'AAAAA') 'stale target copy kept'
    Assert (-not [System.IO.Directory]::Exists($r.Jobs[0].Source + '_migration_backup')) 'backup renamed back'
    Assert (@($r.State.Jobs)[1].Status -eq 'NotStarted') 'next job NotStarted' (@($r.State.Jobs)[1].Status)

    '[E5] New file before rename -> rolled back (file count)'
    $r = Invoke-EngineCase 'e5' -Anchor "`$analysis.Status = 'RenamingSource'" -Injection "[System.IO.File]::WriteAllText((Join-Path `$source 'new.txt'), 'N')" -Mode Before
    $job = @($r.State.Jobs)[0]
    Assert ($job.Status -eq 'RolledBack' -and $job.Error.Contains('文件数')) 'RolledBack on file count' "status=$($job.Status) error=$($job.Error)"
    Assert ([System.IO.File]::Exists((Join-Path $r.Jobs[0].Source 'new.txt'))) 'new file back at the source'

    '[E6] Write into the renamed backup before link creation -> rolled back'
    $r = Invoke-EngineCase 'e6' -Anchor '$backupCreated = $true' -Injection $writeBackupSameSize -Mode After
    $job = @($r.State.Jobs)[0]
    Assert ($job.Status -eq 'RolledBack' -and $job.Error.Contains('修改时间')) 'RolledBack on the backup write' "status=$($job.Status) error=$($job.Error)"
    Assert ([System.IO.File]::ReadAllText((Join-Path $r.Jobs[0].Source 'a.txt')) -eq 'ZZZZZ') 'source has the write'

    '[E7] Exception right after the commit point -> no rollback'
    $r = Invoke-EngineCase 'e7' -Anchor '$jobSucceeded = $true' -Injection "throw 'injected post-commit failure'" -Mode After
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 0 -and $job.Status -eq 'CompleteBackupRetained') 'CompleteBackupRetained, exit 0' "exit=$($r.ExitCode) status=$($job.Status) error=$($job.Error)"
    Assert ((Get-LinkInfo $r.Jobs[0].Source).LinkType -eq 'SymbolicLink') 'working link kept'
    Assert (Test-NormalDirectory ($r.Jobs[0].Source + '_migration_backup')) 'backup kept'

    '[E8] Link creation failure -> rollback, following job NotStarted'
    $r = Invoke-EngineCase 'e8' -JobCount 2 -Anchor 'New-DirectorySymbolicLink (Get-ExtendedLengthPath $source) $target' -Injection "throw 'injected link failure'" -Mode Replace
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 1 -and $job.Status -eq 'RolledBack') 'RolledBack' "exit=$($r.ExitCode) status=$($job.Status) error=$($job.Error)"
    Assert (Test-NormalDirectory $r.Jobs[0].Source) 'source restored'
    Assert (@($r.State.Jobs)[1].Status -eq 'NotStarted') 'next job NotStarted'

    '[E9] Backup removal fails midway -> link kept, backup reported as possibly incomplete'
    $r = Invoke-EngineCase 'e9' -Anchor '[System.IO.Directory]::Delete($extendedRoot, $true)' -Injection "throw 'injected delete failure'" -Mode Replace
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 0 -and $job.Status -eq 'CompleteBackupRetained') 'CompleteBackupRetained, exit 0' "exit=$($r.ExitCode) status=$($job.Status) error=$($job.Error)"
    Assert ($job.Error.Contains('中途失败')) 'message says the backup may be incomplete' $job.Error
    Assert ((Get-LinkInfo $r.Jobs[0].Source).LinkType -eq 'SymbolicLink') 'working link kept'

    '[E10] Backup enumeration fails before anything is removed -> backup reported intact'
    $r = Invoke-EngineCase 'e10' -Anchor '$ModificationStarted.Value = $true' -Injection "throw 'injected enumeration failure'" -Mode Replace
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 0 -and $job.Status -eq 'CompleteBackupRetained' -and $job.Error.Contains('完整保留')) 'backup reported intact' "status=$($job.Status) error=$($job.Error)"
    Assert ([System.IO.File]::Exists((Join-Path ($r.Jobs[0].Source + '_migration_backup') 'a.txt'))) 'backup really intact'

    '[E11] Analyze'
    $r = Invoke-EngineCase 'e11' -Action 'Analyze'
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 0 -and $job.Status -eq 'Ready' -and [int]$job.FileCount -eq 4 -and [int]$job.JunctionCount -eq 1) 'Analyze Ready with counts' "exit=$($r.ExitCode) status=$($job.Status) files=$($job.FileCount) junctions=$($job.JunctionCount) error=$($job.Error)"

    '[E12] Cross-item conflicts are reported on every affected row'
    $caseDir = New-Case 'e12'
    $outer = Join-Path $caseDir 'src\outer'
    New-SourceTree $outer
    $r = Invoke-Engine $caseDir 'Analyze' @(
        [pscustomobject]@{ Source = $outer; Target = (Join-Path $caseDir 'dst\outer') },
        [pscustomobject]@{ Source = (Join-Path $outer 'sub'); Target = (Join-Path $caseDir 'dst\inner') })
    $items = @($r.State.Jobs)
    Assert ($r.ExitCode -eq 1 -and $items[0].Status -eq 'Error' -and $items[1].Status -eq 'Error') 'both rows marked Error' "exit=$($r.ExitCode) statuses=$($items[0].Status)/$($items[1].Status)"
    Assert ($items[0].Error.Contains('互相包含') -and $items[0].Error -eq $items[1].Error) 'same conflict message on both rows' "$($items[0].Error) | $($items[1].Error)"

    '[E13] Cleanup removes a leftover copy without following links inside it'
    $caseDir = New-Case 'e13'
    $source = Join-Path $caseDir 'src\data'
    New-SourceTree $source
    $target = Join-Path $caseDir 'dst\data'
    New-TextFile (Join-Path $target 'copy.txt') 'copy'
    New-Junction (Join-Path $target 'back-to-source') $source
    $r = Invoke-Engine $caseDir 'Cleanup' @([pscustomobject]@{ Source = $source; Target = $target })
    Assert ($r.ExitCode -eq 0 -and @($r.State.Jobs)[0].Status -eq 'Cleaned') 'status Cleaned' "exit=$($r.ExitCode) status=$(@($r.State.Jobs)[0].Status) error=$(@($r.State.Jobs)[0].Error)"
    Assert (-not [System.IO.Directory]::Exists($target)) 'copy deleted'
    Assert ([System.IO.File]::ReadAllText((Join-Path $source 'a.txt')) -eq 'AAAAA' -and [System.IO.File]::Exists((Join-Path $source 'sub\b.txt'))) 'source untouched through the link'

    '[E14] Cleanup refuses whenever the copy might be the only complete data'
    $caseDir = New-Case 'e14'
    $linkedTarget = Join-Path $caseDir 'dst\linked'
    New-TextFile (Join-Path $linkedTarget 'data.txt') 'only copy'
    [void][System.IO.Directory]::CreateDirectory((Join-Path $caseDir 'src'))
    $linkedSource = Join-Path $caseDir 'src\linked'
    New-Junction $linkedSource $linkedTarget
    $backedSource = Join-Path $caseDir 'src\backed'
    New-SourceTree $backedSource
    [void][System.IO.Directory]::CreateDirectory($backedSource + '_migration_backup')
    $backedTarget = Join-Path $caseDir 'dst\backed'
    New-TextFile (Join-Path $backedTarget 'data.txt') 'copy'
    $plainSource = Join-Path $caseDir 'src\plain'
    New-SourceTree $plainSource
    $elsewhere = Join-Path $caseDir 'elsewhere'
    New-TextFile (Join-Path $elsewhere 'keep.txt') 'keep'
    $linkTarget = Join-Path $caseDir 'dst\plain'
    New-Junction $linkTarget $elsewhere
    $r = Invoke-Engine $caseDir 'Cleanup' @(
        [pscustomobject]@{ Source = $linkedSource; Target = $linkedTarget },
        [pscustomobject]@{ Source = $backedSource; Target = $backedTarget },
        [pscustomobject]@{ Source = $plainSource; Target = $linkTarget })
    $items = @($r.State.Jobs)
    Assert ($r.ExitCode -eq 1) 'exit code 1'
    Assert ($items[0].Status -eq 'CleanupFailed' -and [System.IO.File]::Exists((Join-Path $linkedTarget 'data.txt'))) 'source is a link: copy kept' "$($items[0].Status) $($items[0].Error)"
    Assert ($items[1].Status -eq 'CleanupFailed' -and [System.IO.File]::Exists((Join-Path $backedTarget 'data.txt'))) 'backup exists: copy kept' "$($items[1].Status) $($items[1].Error)"
    Assert ($items[2].Status -eq 'CleanupFailed' -and [System.IO.File]::Exists((Join-Path $elsewhere 'keep.txt'))) 'copy is a link: nothing deleted' "$($items[2].Status) $($items[2].Error)"

    '[E15] Restore moves an orphaned backup back and skips an occupied original path'
    $caseDir = New-Case 'e15'
    $missing = Join-Path $caseDir 'src\missing'
    New-TextFile (Join-Path ($missing + '_migration_backup') 'data.txt') 'backup'
    $occupied = Join-Path $caseDir 'src\occupied'
    New-TextFile (Join-Path $occupied 'current.txt') 'current'
    New-TextFile (Join-Path ($occupied + '_migration_backup') 'old.txt') 'old'
    $r = Invoke-Engine $caseDir 'Restore' @(
        [pscustomobject]@{ Source = $missing; Target = (Join-Path $caseDir 'dst\missing') },
        [pscustomobject]@{ Source = $occupied; Target = (Join-Path $caseDir 'dst\occupied') })
    $items = @($r.State.Jobs)
    Assert ($r.ExitCode -eq 0 -and $items[0].Status -eq 'Restored') 'backup restored' "exit=$($r.ExitCode) status=$($items[0].Status) error=$($items[0].Error)"
    Assert ([System.IO.File]::Exists((Join-Path $missing 'data.txt')) -and -not [System.IO.Directory]::Exists($missing + '_migration_backup')) 'data back at the original path'
    Assert ($items[1].Status -eq 'RestoreSkipped' -and [System.IO.File]::Exists((Join-Path $occupied 'current.txt')) -and [System.IO.Directory]::Exists($occupied + '_migration_backup')) 'occupied path left unchanged' $items[1].Status

    '[E16] The engine lock refuses a second migrating engine but not Analyze'
    $mutex = [System.Threading.Mutex]::new($false, 'Global\mklinktool-engine')
    $held = $false
    try {
        try { $held = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        Assert $held 'test holds the engine lock'
        $r = Invoke-EngineCase 'e16'
        Assert ($r.ExitCode -eq 1 -and (@($r.State.Errors) -join ' ').Contains('另一个迁移')) 'Migrate refused while locked' "exit=$($r.ExitCode) errors=$(@($r.State.Errors) -join ' | ')"
        Assert ((Test-NormalDirectory $r.Jobs[0].Source) -and -not [System.IO.Directory]::Exists($r.Jobs[0].Target)) 'nothing touched'
        $r = Invoke-EngineCase 'e16b' -Action 'Analyze'
        Assert ($r.ExitCode -eq 0) 'Analyze not blocked by the lock'
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }

    '[E17] Sources on a network location are refused at preflight, including a local-looking path through a link to a share'
    $caseDir = New-Case 'e17'
    $localSource = Join-Path $caseDir 'src\local'
    New-SourceTree $localSource
    New-TextFile (Join-Path $caseDir 'real\viaLink\data.txt') 'data'
    $caseUnc = Get-UncPathForLocal $caseDir
    if ([string]::IsNullOrEmpty($caseUnc)) {
        '  SKIP no \\localhost\Users share reaching the test directory'
    } else {
        $jobs = @(
            [pscustomobject]@{ Source = (Join-Path $caseUnc 'src\local'); Target = (Join-Path $caseDir 'dst\unc') },
            [pscustomobject]@{ Source = $localSource; Target = (Join-Path $caseDir 'dst\local') })
        # 目录符号链接指向共享：路径看起来在本机，GetVolumePathName 也会报告本机磁盘（已实测）。
        $null = & cmd.exe /c mklink /D (Join-Path $caseDir 'share-link') (Join-Path $caseUnc 'real')
        $linkedSource = Join-Path $caseDir 'share-link\viaLink'
        $haveLink = [System.IO.Directory]::Exists($linkedSource)
        if ($haveLink) { $jobs += [pscustomobject]@{ Source = $linkedSource; Target = (Join-Path $caseDir 'dst\linked') } } else { '  SKIP (link part) could not reach the share through a directory symbolic link' }
        $r = Invoke-Engine $caseDir 'Analyze' $jobs
        $items = @($r.State.Jobs)
        Assert ($r.ExitCode -eq 1 -and $items[0].Status -eq 'Error' -and $items[0].Error.Contains('网络位置')) 'UNC source refused' "exit=$($r.ExitCode) status=$($items[0].Status) error=$($items[0].Error)"
        Assert ($items[1].Status -eq 'Ready') 'local source in the same batch still passes' "$($items[1].Status) $($items[1].Error)"
        if ($haveLink) { Assert ($items[2].Status -eq 'Error' -and $items[2].Error.Contains('网络位置')) 'source reached through a link to a share refused' "$($items[2].Status) $($items[2].Error)" }
        Assert ([System.IO.File]::Exists((Join-Path $caseDir 'real\viaLink\data.txt'))) 'nothing touched'
    }

    '[E18] Volumes that cannot hold the link are refused before anything is copied (volume info injected: all local volumes here are NTFS)'
    $volumeAnchor = '$volume = Get-DirectoryVolumeInfo $parent'
    $r = Invoke-EngineCase 'e18a' -Anchor $volumeAnchor -Injection "`$volume = [pscustomobject]@{ IsRemote = `$false; FileSystem = 'FAT32'; Flags = [uint32]6 }" -Mode After
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 1 -and [string]$r.State.Phase -eq 'PreflightFailed' -and $job.Error.Contains('FAT32') -and $job.Error.Contains('不支持符号链接')) 'FAT32 refused with the reason' "exit=$($r.ExitCode) phase=$($r.State.Phase) error=$($job.Error)"
    Assert ((Test-NormalDirectory $r.Jobs[0].Source) -and -not [System.IO.Directory]::Exists($r.Jobs[0].Target)) 'Migrate stopped before copying'
    $r = Invoke-EngineCase 'e18b' -Action 'Analyze' -Anchor $volumeAnchor -Injection "`$volume = [pscustomobject]@{ IsRemote = `$false; FileSystem = 'NTFS'; Flags = [uint32]0x80080 }" -Mode After
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 1 -and $job.Status -eq 'Error' -and $job.Error.Contains('只读')) 'read-only volume refused' "exit=$($r.ExitCode) error=$($job.Error)"

    '[E19] KeepSourcePermissions: the target root takes the source root permissions instead of the target location'
    $caseDir = New-Case 'e19'
    $broadParent = Join-Path $caseDir 'dst'
    [void][System.IO.Directory]::CreateDirectory($broadParent)
    # 模拟非系统盘根下的目标位置：Users 获得可继承的修改权限（来源所在的 %TEMP% 没有这一条）。
    $null = & icacls.exe $broadParent /grant '*S-1-5-32-545:(OI)(CI)M'
    $keptSource = Join-Path $caseDir 'src\kept'
    $plainSource = Join-Path $caseDir 'src\plain'
    New-SourceTree $keptSource
    New-SourceTree $plainSource
    $sourceRootRules = Get-AccessRuleSet $keptSource
    $sourceFileRules = Get-AccessRuleSet (Join-Path $keptSource 'a.txt')
    $keptTarget = Join-Path $broadParent 'kept'
    $r = Invoke-Engine $caseDir 'Migrate' @([pscustomobject]@{ Source = $keptSource; Target = $keptTarget }) -KeepSourcePermissions
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 0 -and $job.Status -eq 'Complete') 'migration with the option succeeds' "exit=$($r.ExitCode) status=$($job.Status) error=$($job.Error)"
    $targetRootSecurity = [System.IO.Directory]::GetAccessControl($keptTarget)
    Assert ($targetRootSecurity.AreAccessRulesProtected -and (Get-AccessRuleSet $keptTarget) -eq $sourceRootRules) 'target root protected, same rules as the source root' "protected=$($targetRootSecurity.AreAccessRulesProtected)"
    Assert (-not (Get-AccessRuleSet $keptTarget).Contains('S-1-5-32-545|')) 'broad entry of the target location not inherited'
    $targetFileSecurity = [System.IO.File]::GetAccessControl((Join-Path $keptTarget 'a.txt'))
    Assert (-not $targetFileSecurity.AreAccessRulesProtected -and (Get-AccessRuleSet (Join-Path $keptTarget 'a.txt')) -eq $sourceFileRules) 'copied file inherits normally and matches a file of the source'
    $r = Invoke-Engine $caseDir 'Migrate' @([pscustomobject]@{ Source = $plainSource; Target = (Join-Path $broadParent 'plain') })
    Assert ($r.ExitCode -eq 0 -and (Get-AccessRuleSet (Join-Path $broadParent 'plain')).Contains('S-1-5-32-545|')) 'without the option the target inherits the target location as before' "exit=$($r.ExitCode)"

    '[E20] The target is checked on the volume it actually lands on, not by the drive letter of its path'
    $caseDir = New-Case 'e20'
    $caseUnc = Get-UncPathForLocal $caseDir
    if ([string]::IsNullOrEmpty($caseUnc)) {
        '  SKIP (network part) no \\localhost\Users share reaching the test directory'
    } else {
        $sources = @('unc', 'local', 'linked' | ForEach-Object { Join-Path $caseDir "src\$_" })
        foreach ($source in $sources) { New-SourceTree $source }
        [void][System.IO.Directory]::CreateDirectory((Join-Path $caseDir 'real'))
        $jobs = @(
            [pscustomobject]@{ Source = $sources[0]; Target = (Join-Path $caseUnc 'real\unc') },
            [pscustomobject]@{ Source = $sources[1]; Target = (Join-Path $caseDir 'dst\local') })
        # 目录符号链接指向共享：路径以本机固定磁盘的盘符开头，按盘符判断会被放行（修复前的行为）。
        $null = & cmd.exe /c mklink /D (Join-Path $caseDir 'share-link') (Join-Path $caseUnc 'real')
        $haveLink = [System.IO.Directory]::Exists((Join-Path $caseDir 'share-link'))
        if ($haveLink) { $jobs += [pscustomobject]@{ Source = $sources[2]; Target = (Join-Path $caseDir 'share-link\linked') } } else { '  SKIP (link part) could not reach the share through a directory symbolic link' }
        $r = Invoke-Engine $caseDir 'Analyze' $jobs
        $items = @($r.State.Jobs)
        Assert ($r.ExitCode -eq 1 -and $items[0].Status -eq 'Error' -and $items[0].Error.Contains('网络位置')) 'UNC target refused' "exit=$($r.ExitCode) status=$($items[0].Status) error=$($items[0].Error)"
        Assert ($items[1].Status -eq 'Ready') 'local target in the same batch still passes' "$($items[1].Status) $($items[1].Error)"
        if ($haveLink) { Assert ($items[2].Status -eq 'Error' -and $items[2].Error.Contains('网络位置')) 'target reached through a link to a share refused' "$($items[2].Status) $($items[2].Error)" }
    }

    $caseDir = New-Case 'e20-junction'
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $repoSerial = Get-VolumeSerial $repoRoot
    $tempSerial = Get-VolumeSerial $caseDir
    if ([string]::IsNullOrEmpty($repoSerial) -or [string]::IsNullOrEmpty($tempSerial) -or $repoSerial -eq $tempSerial) {
        '  SKIP (junction part) the repository is not on another volume than %TEMP%'
    } else {
        # Junction 指向仓库所在目录（只读使用：预检不创建目标）；引擎注入一行日志，记下它查询到的卷序列号。
        $toOtherVolume = Join-Path $caseDir 'to-repo-volume'
        New-Junction $toOtherVolume $repoRoot
        $source = Join-Path $caseDir 'src\data'
        New-SourceTree $source
        $target = Join-Path $toOtherVolume ('mkl-engine-test-' + [guid]::NewGuid().ToString('N') + '\data')
        $r = Invoke-Engine $caseDir 'Analyze' @([pscustomobject]@{ Source = $source; Target = $target }) -Anchor '$targetVolume = Get-TargetVolumeInfo $target' -Injection "Write-Log ('TEST target volume serial {0:X8}' -f `$targetVolume.SerialNumber)" -Mode After
        $queriedSerial = if ($r.Log -match 'TEST target volume serial ([0-9A-F]{8})') { $Matches[1] } else { '' }
        Assert ($r.ExitCode -eq 0 -and @($r.State.Jobs)[0].Status -eq 'Ready') 'target behind a junction to another volume passes preflight' "exit=$($r.ExitCode) error=$(@($r.State.Jobs)[0].Error)"
        Assert ($queriedSerial -eq $repoSerial) 'the volume queried is the one the junction leads to, not the drive of the path' "queried=$queriedSerial junction volume=$repoSerial path drive=$tempSerial"
        Assert (-not [System.IO.Directory]::Exists((Split-Path -Parent $target))) 'nothing created behind the junction'
    }

    $targetVolumeAnchor = '$volume = Get-DirectoryVolumeInfo $probe'
    $r = Invoke-EngineCase 'e20-removable' -Action 'Analyze' -Anchor $targetVolumeAnchor -Injection (New-TargetVolumeInjection -IsFixed '$false') -Mode After
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 1 -and $job.Status -eq 'Error' -and $job.Error.Contains('本地固定磁盘')) 'target on a volume that is not a fixed disk refused' "exit=$($r.ExitCode) error=$($job.Error)"
    $r = Invoke-EngineCase 'e20-space' -Action 'Analyze' -Anchor $targetVolumeAnchor -Injection (New-TargetVolumeInjection -AvailableBytes '1') -Mode After
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 1 -and $job.Error.Contains('可用空间不足') -and $job.Error.Contains('X:\injected')) 'free space taken from the queried volume, message names the queried directory' "exit=$($r.ExitCode) error=$($job.Error)"
    $r = Invoke-EngineCase 'e20-fat32' -Anchor $targetVolumeAnchor -Injection (New-TargetVolumeInjection -FileSystem 'FAT32') -Mode After
    $job = @($r.State.Jobs)[0]
    Assert ($r.ExitCode -eq 0 -and $job.Status -eq 'Complete' -and $r.Log.Contains('不比较修改时间')) 'time tolerance follows the queried volume (FAT32: not compared)' "exit=$($r.ExitCode) status=$($job.Status) error=$($job.Error)"
} catch {
    "TEST ERROR: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
    $script:TestFail++
} finally {
    Remove-TestTree $testRoot
}
Write-TestSummary
if ($script:TestFail -gt 0) { exit 1 }
exit 0
