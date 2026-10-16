param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Analyze', 'Migrate', 'Cleanup', 'Restore')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$StatePath,

    [Parameter(Mandatory = $true)]
    [string]$LogPath,

    [Parameter(Mandatory = $true)]
    [string]$RobocopyLogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Win32 API：长路径的 8.3 短名展开与目录符号链接创建。
# CreateSymbolicLinkW 返回 1 字节的 BOOLEAN，必须按 I1 封送：按默认 4 字节 BOOL 读取会混入 EAX 高位残值，
# 实测失败时返回值 0x00000500 被读成 TRUE（即曾被误认为“某些策略下返回 TRUE 但没有创建”）。
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class MklinkToolWin32 {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetLongPathNameW(string lpszShortPath, StringBuilder lpszLongPath, uint cchBuffer);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool CreateSymbolicLinkW(string lpSymlinkFileName, string lpTargetFileName, uint dwFlags);
}
'@
$script:State = [ordered]@{
    Action = $Action
    Phase = 'Starting'
    Success = $false
    LogIncomplete = $false
    # 主窗口没收到 Worker 的任务确认（其中带有引擎 PID）时，凭这两项判断引擎是否仍在运行。
    EnginePid = $PID
    EngineStartTime = [string]([System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToFileTime())
    Jobs = @()
    Errors = @()
    Warnings = @()
}
$script:EngineMutex = $null

function Test-EngineOutputPath([string]$Path) {
    if ([System.IO.File]::Exists($Path) -and
        (([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "引擎输出路径已变成重解析点，为避免提权写入被重定向而停止：$Path"
    }
}

function Write-Log([string]$Message) {
    # 日志只是辅助通道：写入失败（GUI 读取或杀毒扫描造成的短暂占用、磁盘写满、输出路径变成重解析点）
    # 绝不能向上抛出，否则会中断迁移，甚至在提交点之后触发回滚。有限重试后仍失败则丢弃该行并标记日志不完整。
    $line = '[{0}] {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message, [Environment]::NewLine
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Test-EngineOutputPath $LogPath
            [System.IO.File]::AppendAllText($LogPath, $line, $script:Utf8NoBom)
            return
        } catch {
            if ($attempt -lt 3) { Start-Sleep -Milliseconds 50 }
        }
    }
    $script:State.LogIncomplete = $true
}

function Write-State {
    $temporaryPath = $StatePath + '.tmp'
    Test-EngineOutputPath $temporaryPath
    Test-EngineOutputPath $StatePath
    $json = $script:State | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($temporaryPath, $json, $script:Utf8NoBom)

    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        try {
            if ([System.IO.File]::Exists($StatePath)) {
                $backupPath = $StatePath + '.' + [guid]::NewGuid().ToString('N') + '.bak'
                [System.IO.File]::Replace($temporaryPath, $StatePath, $backupPath)
                if ([System.IO.File]::Exists($backupPath)) {
                    try { [System.IO.File]::Delete($backupPath) } catch { }
                }
            } else {
                [System.IO.File]::Move($temporaryPath, $StatePath)
            }
            return
        } catch [System.IO.IOException] {
            if ($attempt -ge 7) { throw }
            Start-Sleep -Milliseconds 50
        } catch [System.UnauthorizedAccessException] {
            if ($attempt -ge 7) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Expand-ShortNamesWithLongPath([string]$ExtendedPath) {
    # $ExtendedPath 必须已带 \\?\ 前缀。展开其中的 8.3 短名（如 ADMINI~1）。
    # 对不存在的路径返回原样——不存在的路径不可能持有磁盘短名别名，无需展开。
    $buffer = New-Object System.Text.StringBuilder 520
    $length = [MklinkToolWin32]::GetLongPathNameW($ExtendedPath, $buffer, [uint32]$buffer.Capacity)
    if ($length -gt [uint32]$buffer.Capacity) {
        $buffer = New-Object System.Text.StringBuilder ([int]$length)
        $length = [MklinkToolWin32]::GetLongPathNameW($ExtendedPath, $buffer, [uint32]$buffer.Capacity)
    }
    if ($length -eq 0) {
        $lastError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ([System.IO.Directory]::Exists($ExtendedPath) -or [System.IO.File]::Exists($ExtendedPath)) {
            throw "无法展开包含 8.3 短名的路径（GetLongPathName 失败，Win32 错误码 $lastError）：$ExtendedPath"
        }
        return $ExtendedPath
    }
    return $buffer.ToString()
}

function ConvertTo-FullPath([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    $normalized = $Path.Replace('/', '\')
    try {
        $fullPath = [System.IO.Path]::GetFullPath($normalized)
    } catch [System.IO.PathTooLongException] {
        # 超长路径无法走 GetFullPath 归并 '..' 段，为避免边界检查被字符串把戏绕过，直接拒绝。
        if ($normalized -match '(?:^|\\)\.\.(?:\\|$)') {
            throw "路径过长且包含 '..' 段，无法安全规范化，已拒绝：$Path"
        }
        $fullPath = $normalized
    }
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $root.Length) {
        $fullPath = $fullPath.TrimEnd('\')
    }
    if ($fullPath -match '~[0-9]') {
        return ConvertFrom-ExtendedLengthPath (Expand-ShortNamesWithLongPath (Get-ExtendedLengthPath $fullPath))
    }
    return $fullPath
}

function Test-PathContains([string]$ParentPath, [string]$ChildPath) {
    $parent = (ConvertTo-FullPath (ConvertFrom-ExtendedLengthPath $ParentPath)).TrimEnd('\')
    $child = (ConvertTo-FullPath (ConvertFrom-ExtendedLengthPath $ChildPath)).TrimEnd('\')
    if ([string]::Equals($parent, $child, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $child.StartsWith($parent + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-FullyQualifiedWindowsPath([string]$Path) {
    return ($Path -match '^[a-zA-Z]:\\' -or $Path.StartsWith('\\', [System.StringComparison]::Ordinal))
}

function Get-ExtendedLengthPath([string]$Path) {
    if ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal)) { return $Path }
    $normalized = $Path.Replace('/', '\')
    try {
        $fullPath = [System.IO.Path]::GetFullPath($normalized)
    } catch [System.IO.PathTooLongException] {
        # 超过 260 字符的路径在 .NET Framework 下会抛 PathTooLongException，跳过归一直接加前缀。
        if ($normalized.StartsWith('\\', [System.StringComparison]::Ordinal)) {
            return '\\?\UNC\' + $normalized.Substring(2)
        }
        return '\\?\' + $normalized
    }
    if ($fullPath.StartsWith('\\?\', [System.StringComparison]::Ordinal)) { return $fullPath }
    if ($fullPath.StartsWith('\\', [System.StringComparison]::Ordinal)) {
        return '\\?\UNC\' + $fullPath.Substring(2)
    }
    return '\\?\' + $fullPath
}

function ConvertFrom-ExtendedLengthPath([string]$Path) {
    if ($Path.StartsWith('\\?\UNC\', [System.StringComparison]::Ordinal)) {
        return '\\' + $Path.Substring(8)
    }
    if ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
        return $Path.Substring(4)
    }
    return $Path
}

function Normalize-LinkTarget([string]$Target) {
    if (Test-FullyQualifiedWindowsPath $Target) {
        return (ConvertTo-FullPath $Target).TrimEnd('\')
    }
    return $Target.Replace('/', '\').TrimEnd('\')
}

function Test-PathEntryExists([string]$Path) {
    $extendedPath = Get-ExtendedLengthPath $Path
    try {
        if ([System.IO.Directory]::Exists($extendedPath) -or [System.IO.File]::Exists($extendedPath)) {
            return $true
        }
    } catch {
        # 系统调用失败时回退到过滤枚举，兼容悬空重解析点等特殊条目。
    }
    try {
        # GetDirectoryName 对超过 260 字符的普通路径会抛 PathTooLongException，
        # 因此先加扩展前缀（设备路径跳过长度检查），再取父目录与文件名。
        $extendedInput = Get-ExtendedLengthPath $Path
        $parentPath = [System.IO.Path]::GetDirectoryName($extendedInput)
        $leafName = [System.IO.Path]::GetFileName($extendedInput)
    } catch {
        throw "无法确认路径是否存在：$Path - $($_.Exception.Message)"
    }
    if ([string]::IsNullOrEmpty($parentPath) -or -not [System.IO.Directory]::Exists($parentPath)) {
        return $false
    }
    try {
        foreach ($entry in [System.IO.DirectoryInfo]::new($parentPath).GetFileSystemInfos()) {
            if ([string]::Equals($entry.Name, $leafName, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    } catch {
        throw "无法确认路径是否存在（父目录不可访问）：$Path - $($_.Exception.Message)"
    }
    return $false
}

function New-DirectorySymbolicLink([string]$LinkPath, [string]$TargetPath) {
    # $LinkPath 须已带 \\?\ 前缀；$TargetPath 保持常规形态（与重解析点存储内容一致）。
    # 优先 SYMBOLIC_LINK_FLAG_DIRECTORY(1) | ALLOW_UNPRIVILEGED_CREATE(2)：
    # 开发者模式或系统策略允许时无需管理员特权；旧系统不认识 flag 2（错误码 87）时回退 flag 1。
    foreach ($flags in 3, 1) {
        if ([MklinkToolWin32]::CreateSymbolicLinkW($LinkPath, $TargetPath, [uint32]$flags)) {
            return
        }
        $lastError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($lastError -ne 87) {
            throw "创建目录符号链接失败（Win32 错误码 $lastError）：$TargetPath"
        }
    }
    throw '创建目录符号链接失败：当前系统不支持非特权符号链接，且进程缺少 SeCreateSymbolicLinkPrivilege 特权。'
}

function Test-SymbolicLinkCreation {
    $probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('.mklinktool-link-probe-' + [guid]::NewGuid().ToString('N'))
    $probeTarget = Join-Path $probeRoot 'target'
    $probeLink = Join-Path $probeRoot 'link'
    try {
        [void][System.IO.Directory]::CreateDirectory($probeTarget)
        # 探针必须与真实建链使用同一 API 与参数，否则会产生假阴性/假阳性。
        New-DirectorySymbolicLink (Get-ExtendedLengthPath $probeLink) $probeTarget
        $created = [System.IO.DirectoryInfo]::new((Get-ExtendedLengthPath $probeLink))
        if ([string]$created.LinkType -ne 'SymbolicLink' -or -not [System.IO.Directory]::Exists((Get-ExtendedLengthPath $probeLink))) {
            throw 'Windows 未能创建可访问的目录符号链接。'
        }
        return $true
    } catch {
        throw "当前进程无法创建目录符号链接。请从管理员 CMD 启动、启用开发者模式，或以管理员身份运行。$($_.Exception.Message)"
    } finally {
        try {
            if ([System.IO.Directory]::Exists($probeLink)) { [System.IO.Directory]::Delete($probeLink) }
        } catch { }
        try {
            if ([System.IO.Directory]::Exists($probeRoot)) { [System.IO.Directory]::Delete($probeRoot, $true) }
        } catch { }
    }
}

function Get-ContainedDirectoryLinkInfo($Entry, [string]$RootPath, [string]$AbsoluteLinkRoot, [bool]$RequireTargetExists = $true) {
    $Path = ConvertFrom-ExtendedLengthPath $Entry.FullName
    $attributes = $Entry.Attributes
    if (($attributes -band [System.IO.FileAttributes]::Directory) -eq 0) {
        throw "不支持文件链接或非目录重解析点：$Path"
    }

    $linkType = [string]$Entry.LinkType
    if ($linkType -notin @('Junction', 'SymbolicLink')) {
        throw "不支持的重解析点类型 '$linkType'：$Path"
    }

    $linkTarget = $Entry.Target
    if ($linkTarget -is [array]) {
        if ($linkTarget.Count -ne 1) { throw "链接包含多个目标，无法安全迁移：$Path" }
        $linkTarget = $linkTarget[0]
    }
    $linkTarget = [string]$linkTarget
    if ([string]::IsNullOrWhiteSpace($linkTarget)) {
        throw "无法读取链接目标，无法安全迁移：$Path"
    }

    $isFullyQualified = Test-FullyQualifiedWindowsPath $linkTarget
    if ([System.IO.Path]::IsPathRooted($linkTarget) -and -not $isFullyQualified) {
        throw "链接目标不是完整路径：$Path -> $linkTarget"
    }
    $isRelative = -not $isFullyQualified
    if ($linkType -eq 'Junction' -and $isRelative) {
        throw "Junction 目标不是绝对路径：$Path -> $linkTarget"
    }
    if ($isRelative) {
        # 父目录可能超过 260 字符：先加扩展前缀再取父目录（设备路径跳过长度检查），随后去前缀保持 ResolvedTarget 为普通路径。
        $targetBase = ConvertFrom-ExtendedLengthPath ([System.IO.Path]::GetDirectoryName((Get-ExtendedLengthPath (ConvertTo-FullPath $Path))))
        $resolvedTarget = ConvertTo-FullPath ([System.IO.Path]::Combine($targetBase, $linkTarget))
        $targetBoundary = $RootPath
    } else {
        $resolvedTarget = ConvertTo-FullPath $linkTarget
        $targetBoundary = if ([string]::IsNullOrWhiteSpace($AbsoluteLinkRoot)) { $RootPath } else { ConvertTo-FullPath $AbsoluteLinkRoot }
    }
    if (-not (Test-PathContains $targetBoundary $resolvedTarget)) {
        throw "链接目标位于来源目录之外，拒绝迁移：$Path -> $linkTarget"
    }
    if ($RequireTargetExists -and -not [System.IO.Directory]::Exists((Get-ExtendedLengthPath $resolvedTarget))) {
        throw "链接目标不存在或不可访问：$Path -> $linkTarget"
    }

    return [pscustomobject]@{
        Type = $linkType
        Target = $linkTarget
        ResolvedTarget = $resolvedTarget
        IsRelative = $isRelative
    }
}

function Get-Sha256Hex([string]$Path) {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $hashBytes = $sha256.ComputeHash($stream)
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha256.Dispose()
    }
    return [System.BitConverter]::ToString($hashBytes).Replace('-', '')
}

function Get-TreeSnapshot([string]$Path, [bool]$IncludeHash, [string]$AbsoluteLinkRoot, [bool]$RequireLinkTargets = $true) {
    $rootPath = ConvertTo-FullPath $Path
    if ([string]::IsNullOrWhiteSpace($AbsoluteLinkRoot)) { $AbsoluteLinkRoot = $rootPath }
    $extendedRootPath = Get-ExtendedLengthPath $rootPath
    if (-not [System.IO.Directory]::Exists($extendedRootPath)) {
        throw "来源不是目录：$rootPath"
    }
    $rootAttributes = [System.IO.File]::GetAttributes($extendedRootPath)
    if (($rootAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "不支持迁移本身是重解析点的来源目录：$rootPath"
    }

    $files = @{}
    $links = @{}
    $rootPrefix = $rootPath.TrimEnd('\')
    $directories = New-Object 'System.Collections.Generic.Queue[System.IO.DirectoryInfo]'
    $directories.Enqueue([System.IO.DirectoryInfo]::new((Get-ExtendedLengthPath $rootPath)))
    [long]$totalBytes = 0

    while ($directories.Count -gt 0) {
        $directory = $directories.Dequeue()
        foreach ($entry in $directory.GetFileSystemInfos()) {
            $relativePath = (ConvertFrom-ExtendedLengthPath $entry.FullName).Substring($rootPrefix.Length).TrimStart('\')
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $links[$relativePath] = Get-ContainedDirectoryLinkInfo -Entry $entry -RootPath $rootPath -AbsoluteLinkRoot $AbsoluteLinkRoot -RequireTargetExists $RequireLinkTargets
                continue
            }
            if (($entry.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $directories.Enqueue([System.IO.DirectoryInfo]::new($entry.FullName))
                continue
            }

            # 单独读取一次元数据，不用枚举结果自带的值：NTFS 目录项里缓存的大小与时间在文件仍被写入时会滞后，
            # 而快照比较要发现的恰恰是这类写入。
            $fileInfo = [System.IO.FileInfo]::new($entry.FullName)
            $item = [ordered]@{ Length = [long]$fileInfo.Length; LastWriteTicks = $fileInfo.LastWriteTimeUtc.Ticks }
            if ($IncludeHash) {
                $item.Hash = Get-Sha256Hex $fileInfo.FullName
            }
            $files[$relativePath] = [pscustomobject]$item
            $totalBytes += [long]$fileInfo.Length
        }
    }

    return [pscustomobject]@{
        FileCount = $files.Count
        TotalBytes = $totalBytes
        Files = $files
        LinkCount = $links.Count
        JunctionCount = @($links.Values | Where-Object { $_.Type -eq 'Junction' }).Count
        SymbolicLinkCount = @($links.Values | Where-Object { $_.Type -eq 'SymbolicLink' }).Count
        AbsoluteLinkCount = @($links.Values | Where-Object { -not $_.IsRelative }).Count
        Links = $links
    }
}

function Clear-ReadOnlyAttribute([string]$Path) {
    # 只读文件会阻断 Directory.Delete(recursive)，只读目录与只读链接连单体删除也会被拒绝（已实测）。
    # SetAttributes 作用于链接本身而不是其目标（已实测），不会改动链接指向的数据。返回清除前的属性。
    $attributes = [System.IO.File]::GetAttributes($Path)
    if (($attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
        [System.IO.File]::SetAttributes($Path, $attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly))
    }
    return $attributes
}

function Remove-TreeSafely([string]$Path, [ref]$ModificationStarted) {
    # 先逐个解除树中的重解析点本身，确认不再有链接后才递归删除，避免删除动作穿过链接触及链接目标。
    # .NET 的递归删除遇错会继续删除其余条目，因此失败时目录往往已接近删空：调用方必须依据
    # $ModificationStarted 区分“未作任何改动”与“可能已部分删除”，不能一律声称数据仍完整保留。
    $rootPath = ConvertTo-FullPath $Path
    $extendedRoot = Get-ExtendedLengthPath $rootPath
    $rootAttributes = [System.IO.File]::GetAttributes($extendedRoot)
    if (($rootAttributes -band [System.IO.FileAttributes]::Directory) -eq 0 -or
        ($rootAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "待删除的根目录不是普通目录，为避免误删而停止清理：$rootPath"
    }

    $links = New-Object System.Collections.ArrayList
    $readOnlyEntries = New-Object System.Collections.ArrayList
    if (($rootAttributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) { [void]$readOnlyEntries.Add($extendedRoot) }
    $directories = New-Object 'System.Collections.Generic.Queue[System.IO.DirectoryInfo]'
    $directories.Enqueue([System.IO.DirectoryInfo]::new($extendedRoot))
    while ($directories.Count -gt 0) {
        $directory = $directories.Dequeue()
        foreach ($entry in $directory.GetFileSystemInfos()) {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                [void]$links.Add($entry.FullName)
                continue
            }
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) { [void]$readOnlyEntries.Add($entry.FullName) }
            if (($entry.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $directories.Enqueue([System.IO.DirectoryInfo]::new($entry.FullName))
            }
        }
    }

    $ModificationStarted.Value = $true
    foreach ($linkPath in $links) {
        $attributes = Clear-ReadOnlyAttribute ([string]$linkPath)
        if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
            [System.IO.Directory]::Delete([string]$linkPath)
        } else {
            [System.IO.File]::Delete([string]$linkPath)
        }
    }
    foreach ($entryPath in $readOnlyEntries) {
        [void](Clear-ReadOnlyAttribute ([string]$entryPath))
    }

    [System.IO.Directory]::Delete($extendedRoot, $true)
    return $links.Count
}

function Get-DriveInfoForPath([string]$Path) {
    $root = [System.IO.Path]::GetPathRoot((ConvertTo-FullPath $Path))
    if ([string]::IsNullOrEmpty($root)) {
        throw "无法识别目标所在卷：$Path"
    }
    $drive = [System.IO.DriveInfo]::new($root)
    if (-not $drive.IsReady) {
        throw "目标所在卷不可用：$root"
    }
    if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) {
        throw "目标必须位于本地固定磁盘：$root"
    }
    return $drive
}

function Resolve-JobPaths([string]$SourceInput, [string]$TargetInput) {
    # 校验并规范化一项作业的来源与目标；备份路径的命名只在此处定义，预检、清理与恢复共用。
    if ([string]::IsNullOrWhiteSpace($SourceInput)) { throw '来源路径不能为空。' }
    if ([string]::IsNullOrWhiteSpace($TargetInput)) { throw '目标路径不能为空。' }
    if (-not (Test-FullyQualifiedWindowsPath $SourceInput.Replace('/', '\'))) { throw "来源路径必须是完整绝对路径（不接受 \目录 或 C:目录 形式）：$SourceInput" }
    if (-not (Test-FullyQualifiedWindowsPath $TargetInput.Replace('/', '\'))) { throw "目标路径必须是完整绝对路径（不接受 \目录 或 C:目录 形式）：$TargetInput" }
    $source = ConvertTo-FullPath $SourceInput
    $target = ConvertTo-FullPath $TargetInput
    if ([string]::Equals($source.TrimEnd('\'), ([System.IO.Path]::GetPathRoot($source)).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "不能迁移磁盘根目录：$source"
    }
    if ([string]::Equals($target.TrimEnd('\'), ([System.IO.Path]::GetPathRoot($target)).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "不能把磁盘根目录作为目标：$target"
    }
    return [pscustomobject]@{
        Source = $source
        Target = $target
        Backup = $source + '_migration_backup'
    }
}

function Add-AnalysisError($Analysis, [string]$Message) {
    # 跨任务冲突、空间不足、建链能力等错误也写回到相关作业，界面才能在对应行显示原因，而不只出现在日志里。
    $Analysis.Status = 'Error'
    $existing = [string]$Analysis.Error
    if ([string]::IsNullOrEmpty($existing)) {
        $Analysis.Error = $Message
    } elseif (-not $existing.Contains($Message)) {
        $Analysis.Error = $existing + '；' + $Message
    }
}

function Get-MigrationAnalysis($Config) {
    $analyses = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    # 下列四个列表按同一下标对应通过单项检查的作业；$checkedIndices 记录该作业在 $analyses 中的位置。
    $sourcePaths = New-Object 'System.Collections.Generic.List[string]'
    $targetPaths = New-Object 'System.Collections.Generic.List[string]'
    $backupPaths = New-Object 'System.Collections.Generic.List[string]'
    $checkedIndices = New-Object 'System.Collections.Generic.List[int]'
    $requiredByDrive = @{}
    [long]$reserveBytes = 1GB

    $globalError = ''
    if ([string]$Config.LinkType -ne 'SymbolicLink') {
        $globalError = "不支持的链接类型：$($Config.LinkType)。本工具只创建 SymbolicLink。"
    } else {
        try { [void](Test-SymbolicLinkCreation) } catch { $globalError = $_.Exception.Message }
    }
    if (-not [string]::IsNullOrEmpty($globalError)) { [void]$errors.Add($globalError) }
    if (@($Config.Jobs).Count -eq 0) {
        [void]$errors.Add('尚未添加来源目录。')
    }

    foreach ($job in $Config.Jobs) {
        $analysis = [ordered]@{
            # 按 job.json 的顺序回写序号，GUI 据此匹配行，不依赖两侧路径规范化的形态一致。
            Index = $analyses.Count
            Source = [string]$job.Source
            Target = [string]$job.Target
            Backup = ''
            FileCount = 0
            TotalBytes = 0L
            JunctionCount = 0
            SymbolicLinkCount = 0
            AbsoluteLinkCount = 0
            Warning = ''
            Status = 'Checking'
            Error = ''
        }
        try {
            $paths = Resolve-JobPaths ([string]$job.Source) ([string]$job.Target)
            $source = $paths.Source
            $target = $paths.Target
            $backup = $paths.Backup
            if (-not [System.IO.Directory]::Exists((Get-ExtendedLengthPath $source))) {
                throw "来源目录不存在：$source"
            }
            if (Test-PathEntryExists $target) {
                throw "目标路径已经存在：$target"
            }
            if (Test-PathEntryExists $backup) {
                throw "备份路径已经存在，请先处理该备份：$backup"
            }
            $targetDrive = Get-DriveInfoForPath $target

            [void]$sourcePaths.Add($source)
            [void]$targetPaths.Add($target)
            [void]$backupPaths.Add($backup)
            $checkedIndices.Add($analyses.Count)
            $analysis.Source = $source
            $analysis.Target = $target
            $analysis.Backup = $backup

            $analysis.Status = 'Scanning'
            $script:State.Jobs = @($analyses.ToArray()) + @([pscustomobject]$analysis)
            $script:State.Errors = @($errors.ToArray())
            $script:State.Warnings = @($warnings.ToArray())
            $script:State.Phase = 'Analyzing'
            Write-State
            Write-Log "正在扫描：$source"
            $snapshot = Get-TreeSnapshot -Path $source -IncludeHash:$false
            $analysis.FileCount = [int]$snapshot.FileCount
            $analysis.TotalBytes = [long]$snapshot.TotalBytes
            $analysis.JunctionCount = [int]$snapshot.JunctionCount
            $analysis.SymbolicLinkCount = [int]$snapshot.SymbolicLinkCount
            $analysis.AbsoluteLinkCount = [int]$snapshot.AbsoluteLinkCount
            if ([int]$snapshot.LinkCount -gt 0) {
                $analysis.Warning = "包含 $($snapshot.JunctionCount) 个 Junction、$($snapshot.SymbolicLinkCount) 个目录 SymbolicLink；链接本身会保留，不展开其目标内容。"
                if ([int]$snapshot.AbsoluteLinkCount -gt 0) {
                    $analysis.Warning += ' 其中绝对目标链接依赖原来源路径继续保留为顶层 SymbolicLink。'
                }
                [void]$warnings.Add("$source：$($analysis.Warning)")
                Write-Log "预检警告：$source：$($analysis.Warning)"
            }
            $analysis.Status = 'Ready'

            $driveKey = $targetDrive.Name.ToUpperInvariant()
            if (-not $requiredByDrive.ContainsKey($driveKey)) {
                $requiredByDrive[$driveKey] = [ordered]@{ Drive = $targetDrive; Bytes = 0L; Indices = (New-Object 'System.Collections.Generic.List[int]') }
            }
            $requiredByDrive[$driveKey].Bytes += [long]$snapshot.TotalBytes
            $requiredByDrive[$driveKey].Indices.Add($analyses.Count)
        } catch {
            $analysis.Status = 'Error'
            $analysis.Error = $_.Exception.Message
            [void]$errors.Add($analysis.Error)
        }
        [void]$analyses.Add([pscustomobject]$analysis)
        $script:State.Jobs = @($analyses.ToArray())
        $script:State.Errors = @($errors.ToArray())
        $script:State.Warnings = @($warnings.ToArray())
        $script:State.Phase = 'Analyzing'
        Write-State
    }

    function Add-ConflictError([int]$First, [int]$Second, [string]$Message) {
        # $First/$Second 是路径列表下标；冲突双方都标出错误。
        [void]$errors.Add($Message)
        Add-AnalysisError $analyses[$checkedIndices[$First]] $Message
        Add-AnalysisError $analyses[$checkedIndices[$Second]] $Message
    }

    for ($i = 0; $i -lt $sourcePaths.Count; $i++) {
        for ($j = $i + 1; $j -lt $sourcePaths.Count; $j++) {
            if ((Test-PathContains $sourcePaths[$i] $sourcePaths[$j]) -or (Test-PathContains $sourcePaths[$j] $sourcePaths[$i])) {
                Add-ConflictError $i $j "来源目录互相包含，拒绝批量迁移：$($sourcePaths[$i]) / $($sourcePaths[$j])"
            }
            if ((Test-PathContains $targetPaths[$i] $targetPaths[$j]) -or (Test-PathContains $targetPaths[$j] $targetPaths[$i])) {
                Add-ConflictError $i $j "目标目录互相包含，拒绝批量迁移：$($targetPaths[$i]) / $($targetPaths[$j])"
            }
        }
        for ($j = 0; $j -lt $sourcePaths.Count; $j++) {
            if ((Test-PathContains $sourcePaths[$j] $targetPaths[$i]) -or (Test-PathContains $targetPaths[$i] $sourcePaths[$j])) {
                Add-ConflictError $j $i "来源与目标路径互相包含：$($sourcePaths[$j]) / $($targetPaths[$i])"
            }
        }
    }

    for ($i = 0; $i -lt $backupPaths.Count; $i++) {
        for ($j = 0; $j -lt $sourcePaths.Count; $j++) {
            if ($j -ne $i -and ((Test-PathContains $backupPaths[$i] $sourcePaths[$j]) -or (Test-PathContains $sourcePaths[$j] $backupPaths[$i]))) {
                Add-ConflictError $i $j "备份路径与其他来源目录互相包含，拒绝批量迁移：$($backupPaths[$i]) / $($sourcePaths[$j])"
            }
            if ((Test-PathContains $backupPaths[$i] $targetPaths[$j]) -or (Test-PathContains $targetPaths[$j] $backupPaths[$i])) {
                Add-ConflictError $i $j "备份路径与目标目录互相包含，拒绝批量迁移：$($backupPaths[$i]) / $($targetPaths[$j])"
            }
        }
        for ($j = $i + 1; $j -lt $backupPaths.Count; $j++) {
            if ((Test-PathContains $backupPaths[$i] $backupPaths[$j]) -or (Test-PathContains $backupPaths[$j] $backupPaths[$i])) {
                Add-ConflictError $i $j "备份路径互相包含，拒绝批量迁移：$($backupPaths[$i]) / $($backupPaths[$j])"
            }
        }
    }

    foreach ($driveEntry in $requiredByDrive.Values) {
        [long]$required = [long]$driveEntry.Bytes + $reserveBytes
        if ([long]$driveEntry.Drive.AvailableFreeSpace -lt $required) {
            $spaceError = "$($driveEntry.Drive.Name): 可用空间不足。需要约 $($driveEntry.Bytes) 字节并保留 1 GB，当前可用 $($driveEntry.Drive.AvailableFreeSpace) 字节。"
            [void]$errors.Add($spaceError)
            foreach ($analysisIndex in $driveEntry.Indices) { Add-AnalysisError $analyses[$analysisIndex] $spaceError }
        }
    }
    if (-not [string]::IsNullOrEmpty($globalError)) {
        # 链接类型不受支持或无法创建符号链接时，任何一项都无法迁移，逐行标出原因。
        foreach ($analysisObject in $analyses) { Add-AnalysisError $analysisObject $globalError }
    }

    return [pscustomobject]@{
        Jobs = @($analyses.ToArray())
        Errors = @($errors.ToArray())
        Warnings = @($warnings.ToArray())
    }
}

function Compare-TreeSnapshots($SourceSnapshot, $TargetSnapshot, [bool]$IncludeHash, [long]$TimeToleranceTicks = -1) {
    # $TimeToleranceTicks 为负数时不比较修改时间，0 表示必须完全一致。
    if ($SourceSnapshot.FileCount -ne $TargetSnapshot.FileCount) {
        return "文件数不一致：源 $($SourceSnapshot.FileCount)，目标 $($TargetSnapshot.FileCount)"
    }
    if ($SourceSnapshot.TotalBytes -ne $TargetSnapshot.TotalBytes) {
        return "总字节数不一致：源 $($SourceSnapshot.TotalBytes)，目标 $($TargetSnapshot.TotalBytes)"
    }
    if ($SourceSnapshot.LinkCount -ne $TargetSnapshot.LinkCount) {
        return "嵌套链接数不一致：源 $($SourceSnapshot.LinkCount)，目标 $($TargetSnapshot.LinkCount)"
    }
    foreach ($relativePath in $SourceSnapshot.Files.Keys) {
        if (-not $TargetSnapshot.Files.ContainsKey($relativePath)) {
            return "目标缺少文件：$relativePath"
        }
        $sourceFile = $SourceSnapshot.Files[$relativePath]
        $targetFile = $TargetSnapshot.Files[$relativePath]
        if ($sourceFile.Length -ne $targetFile.Length) {
            return "文件大小不一致：$relativePath"
        }
        if ($TimeToleranceTicks -ge 0 -and [Math]::Abs([long]$sourceFile.LastWriteTicks - [long]$targetFile.LastWriteTicks) -gt $TimeToleranceTicks) {
            return "文件修改时间不一致：$relativePath"
        }
        if ($IncludeHash -and $sourceFile.Hash -ne $targetFile.Hash) {
            return "SHA-256 不一致：$relativePath"
        }
    }
    foreach ($relativePath in $SourceSnapshot.Links.Keys) {
        if (-not $TargetSnapshot.Links.ContainsKey($relativePath)) {
            return "目标缺少嵌套链接：$relativePath"
        }
        $sourceLink = $SourceSnapshot.Links[$relativePath]
        $targetLink = $TargetSnapshot.Links[$relativePath]
        if ($sourceLink.Type -ne $targetLink.Type) {
            return "嵌套链接类型不一致：$relativePath（源 $($sourceLink.Type)，目标 $($targetLink.Type)）"
        }
        if ($sourceLink.IsRelative -ne $targetLink.IsRelative -or
            -not [string]::Equals((Normalize-LinkTarget ([string]$sourceLink.Target)), (Normalize-LinkTarget ([string]$targetLink.Target)), [System.StringComparison]::OrdinalIgnoreCase)) {
            return "嵌套链接目标不一致：$relativePath（源 $($sourceLink.Target)，目标 $($targetLink.Target)）"
        }
    }
    return ''
}

function Get-TimestampToleranceTicks([string]$TargetPath) {
    # 目标卷保存修改时间的精度：NTFS/ReFS 与来源完全一致；exFAT 为 10 ms；FAT32 以本地时间保存，
    # 跨夏令时会差整小时，因此不比较（返回 -1）。
    switch ([string](Get-DriveInfoForPath $TargetPath).DriveFormat) {
        'NTFS' { return 0L }
        'ReFS' { return 0L }
        'exFAT' { return [TimeSpan]::FromSeconds(2).Ticks }
    }
    return -1L
}

function Get-SourceChangeSince($SourceSnapshot, [string]$CurrentPath, [string]$OriginalSource) {
    # 按元数据（相对路径、文件大小与修改时间、嵌套链接）比较 $CurrentPath 与早先的来源快照，返回差异描述，无差异返回空串。
    # 用于改名后的备份：同一卷上时间戳必须完全一致；备份中的绝对链接仍指向原来源路径，不要求链接目标存在。
    $currentSnapshot = Get-TreeSnapshot -Path $CurrentPath -IncludeHash:$false -AbsoluteLinkRoot:$OriginalSource -RequireLinkTargets:$false
    return Compare-TreeSnapshots -SourceSnapshot $SourceSnapshot -TargetSnapshot $currentSnapshot -IncludeHash:$false -TimeToleranceTicks 0
}

function Test-CreatedLink([string]$Path, [string]$Target, [string]$LinkType) {
    $link = [System.IO.DirectoryInfo]::new((Get-ExtendedLengthPath $Path))
    if ([string]$link.LinkType -ne $LinkType) {
        throw "链接类型校验失败：预期 $LinkType，实际 $($link.LinkType)"
    }
    $actualTarget = $link.Target
    if ($actualTarget -is [array]) { $actualTarget = $actualTarget[0] }
    if (-not [string]::Equals((ConvertTo-FullPath ([string]$actualTarget)), (ConvertTo-FullPath $Target), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "链接目标校验失败：预期 $Target，实际 $actualTarget"
    }
    if (-not [System.IO.Directory]::Exists((Get-ExtendedLengthPath $Target))) {
        throw "链接目标目录不可访问：$Target"
    }
    foreach ($child in [System.IO.Directory]::EnumerateFileSystemEntries((Get-ExtendedLengthPath $Path))) { break }
}

function Test-NestedLinksAccessible([string]$SourceRoot, [string]$TargetRoot, $Snapshot) {
    $sourceRootPath = ConvertTo-FullPath $SourceRoot
    $targetRootPath = ConvertTo-FullPath $TargetRoot
    foreach ($relativePath in $Snapshot.Links.Keys) {
        $linkInfo = $Snapshot.Links[$relativePath]
        $sourceViewPath = Join-Path $sourceRootPath $relativePath
        $targetLinkPath = Join-Path $targetRootPath $relativePath
        $extendedTargetLinkPath = Get-ExtendedLengthPath $targetLinkPath
        if (-not [System.IO.Directory]::Exists($extendedTargetLinkPath)) {
            throw "建链后嵌套链接缺失：$relativePath"
        }
        $targetLink = [System.IO.DirectoryInfo]::new($extendedTargetLinkPath)
        if ([string]$targetLink.LinkType -ne [string]$linkInfo.Type) {
            throw "建链后嵌套链接类型异常：$relativePath"
        }
        $actualTarget = $targetLink.Target
        if ($actualTarget -is [array]) { $actualTarget = $actualTarget[0] }
        if ((-not (Test-FullyQualifiedWindowsPath ([string]$actualTarget))) -ne [bool]$linkInfo.IsRelative -or
            -not [string]::Equals((Normalize-LinkTarget ([string]$actualTarget)), (Normalize-LinkTarget ([string]$linkInfo.Target)), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "建链后嵌套链接目标异常：$relativePath"
        }

        $relativeTarget = ''
        if (-not [string]::Equals($linkInfo.ResolvedTarget.TrimEnd('\'), $sourceRootPath.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            $relativeTarget = $linkInfo.ResolvedTarget.Substring($sourceRootPath.TrimEnd('\').Length).TrimStart('\')
        }
        $mappedTarget = if ([string]::IsNullOrEmpty($relativeTarget)) { $targetRootPath } else { Join-Path $targetRootPath $relativeTarget }
        if (-not [System.IO.Directory]::Exists((Get-ExtendedLengthPath $mappedTarget))) {
            throw "嵌套链接对应的目标目录不可访问：$relativePath -> $mappedTarget"
        }
        if (-not [System.IO.Directory]::Exists((Get-ExtendedLengthPath $sourceViewPath)) -or -not [System.IO.Directory]::Exists($extendedTargetLinkPath)) {
            throw "顶层 SymbolicLink 创建后，嵌套链接不可访问：$relativePath"
        }
        foreach ($child in [System.IO.Directory]::EnumerateFileSystemEntries((Get-ExtendedLengthPath $sourceViewPath))) { break }
    }
}

function Remove-VerifiedLink([string]$Path, [string]$Target, [string]$LinkType) {
    $link = [System.IO.DirectoryInfo]::new((Get-ExtendedLengthPath $Path))
    $actualTarget = $link.Target
    if ($actualTarget -is [array]) { $actualTarget = $actualTarget[0] }
    if ([string]$link.LinkType -ne $LinkType -or -not [string]::Equals((ConvertTo-FullPath ([string]$actualTarget)), (ConvertTo-FullPath $Target), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "源路径上出现非本次创建的对象，为避免误删而停止回滚：$Path"
    }
    [System.IO.Directory]::Delete((Get-ExtendedLengthPath $Path))
}

function Invoke-Migration($Config) {
    $analysisResult = Get-MigrationAnalysis -Config $Config
    $jobs = @($analysisResult.Jobs)
    $script:State.Jobs = $jobs
    $script:State.Errors = @($analysisResult.Errors)
    $script:State.Warnings = @($analysisResult.Warnings)
    if ($analysisResult.Errors.Count -gt 0) {
        $script:State.Phase = 'PreflightFailed'
        Write-Log '预检未通过，尚未迁移任何来源目录。'
        Write-State
        return $false
    }

    for ($jobIndex = 0; $jobIndex -lt $jobs.Count; $jobIndex++) {
        $analysis = $jobs[$jobIndex]
        $source = [string]$analysis.Source
        $target = [string]$analysis.Target
        $backup = [string]$analysis.Backup
        $linkCreated = $false
        $backupCreated = $false
        $jobSucceeded = $false

        try {
            $analysis.Status = 'Copying'
            $script:State.Phase = 'Copying'
            Write-State
            Write-Log "复制：$source -> $target"
            $extendedTarget = Get-ExtendedLengthPath $target
            $targetParent = [System.IO.Path]::GetDirectoryName($extendedTarget)
            [void][System.IO.Directory]::CreateDirectory($targetParent)

            $robocopy = Join-Path $env:WINDIR 'System32\robocopy.exe'
            if (-not (Test-Path -LiteralPath $robocopy -PathType Leaf)) {
                throw '找不到 Windows Robocopy。'
            }
            # Robocopy 的输出已通过 /UNILOG+ 写入日志文件；临时关闭 Stop 偏好，
            # 避免 PS 5.1 把 stderr 输出升级为终止错误而丢失真实退出码。
            # /NFL /NDL：不逐条记录正常复制的文件与目录，日志只剩出错项（实测仍带完整路径与原因）和汇总，
            # 避免大目录的日志随文件数线性膨胀；复制是否完整由下面的快照比较负责。
            $previousErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & $robocopy $source $target /E /COPY:DAT /DCOPY:DAT /SJ /SL /R:1 /W:1 /NP /NFL /NDL ("/UNILOG+:$RobocopyLogPath") 2>&1 | Out-Null
            } finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
            $copyResult = $LASTEXITCODE
            if ($null -eq $copyResult -or $copyResult -lt 0 -or $copyResult -ge 8) {
                throw "Robocopy 失败，退出码 $copyResult；源目录保留在原处，目标副本保留。"
            }
            Write-Log "Robocopy 结束，退出码 $copyResult（0 到 7 均为成功状态）。"

            $analysis.Status = 'Verifying'
            $script:State.Phase = 'Verifying'
            Write-State
            $timeToleranceTicks = Get-TimestampToleranceTicks $target
            if ($timeToleranceTicks -lt 0) {
                Write-Log '比较相对路径、文件数和文件大小（目标卷不能精确保存修改时间，不比较修改时间）。'
            } else {
                Write-Log '比较相对路径、文件数、文件大小和修改时间。'
            }
            $sourceSnapshot = Get-TreeSnapshot -Path $source -IncludeHash:([bool]$Config.VerifySha256)
            $targetSnapshot = Get-TreeSnapshot -Path $target -IncludeHash:([bool]$Config.VerifySha256) -AbsoluteLinkRoot:$source
            $difference = Compare-TreeSnapshots -SourceSnapshot $sourceSnapshot -TargetSnapshot $targetSnapshot -IncludeHash:([bool]$Config.VerifySha256) -TimeToleranceTicks $timeToleranceTicks
            if (-not [string]::IsNullOrEmpty($difference)) {
                throw "复制校验失败：$difference；源目录保留在原处，目标副本保留。"
            }
            Write-Log ("复制校验通过：{0} 个文件，{1} 字节，{2} 个 Junction，{3} 个目录 SymbolicLink。" -f $sourceSnapshot.FileCount, $sourceSnapshot.TotalBytes, $sourceSnapshot.JunctionCount, $sourceSnapshot.SymbolicLinkCount)
            if ([bool]$Config.VerifySha256) { Write-Log '附加 SHA-256 比较通过。' }

            $analysis.Status = 'RenamingSource'
            $script:State.Phase = 'RenamingSource'
            Write-State
            if (Test-PathEntryExists $backup) {
                throw "备份路径已被创建，拒绝覆盖：$backup"
            }
            Write-Log "将源目录改名为同目录备份：$backup"
            [System.IO.Directory]::Move((Get-ExtendedLengthPath $source), (Get-ExtendedLengthPath $backup))
            $backupCreated = $true

            $analysis.Status = 'CreatingLink'
            $script:State.Phase = 'CreatingLink'
            Write-State
            Write-Log "创建 $($Config.LinkType)：$source -> $target"
            # PowerShell 5.1 的 New-Item 不支持超过 260 字符的路径；改用 Win32 API 创建。
            # 目标路径不加深前缀，使重解析点中存储的目标与常规输入一致，便于校验比较。
            New-DirectorySymbolicLink (Get-ExtendedLengthPath $source) $target
            if (-not [System.IO.Directory]::Exists((Get-ExtendedLengthPath $source))) {
                throw "符号链接创建调用返回成功，但路径未实际生成：$source"
            }
            $linkCreated = $true
            Test-CreatedLink -Path $source -Target $target -LinkType ([string]$Config.LinkType)
            Test-NestedLinksAccessible -SourceRoot $source -TargetRoot $target -Snapshot $sourceSnapshot
            # 快照之后、改名之前写入来源的内容不在目标副本中，删除备份就会丢失：提交前用改名后的备份复核一次，
            # 有变化就按建链失败处理（删除本次创建的链接、改回原名）。放在建链之后做，原路径缺失的时间不会因复核而延长。
            $sourceChange = Get-SourceChangeSince -SourceSnapshot $sourceSnapshot -CurrentPath $backup -OriginalSource $source
            if (-not [string]::IsNullOrEmpty($sourceChange)) {
                throw "来源在复制校验之后仍被写入（$sourceChange），这些改动不在目标副本中。请关闭使用该目录的应用后重试。"
            }
            # 提交点：链接已建立并通过验证，备份也与复制校验时的来源一致。此后任何异常都只能记录，不得回滚（见下方 catch）。
            $jobSucceeded = $true
            Write-Log '顶层 SymbolicLink 与嵌套链接的类型、目标及目录访问验证通过；改名后的备份与复制校验时的来源一致。'

            if ([bool]$Config.DeleteBackup) {
                $backupModified = $false
                try {
                    Write-Log "删除已验证的源备份：$backup"
                    $removedLinkCount = Remove-TreeSafely -Path $backup -ModificationStarted ([ref]$backupModified)
                    Write-Log "备份安全清理完成：先解除 $removedLinkCount 个重解析点，再删除普通目录树。"
                    $analysis.Backup = ''
                    $analysis.Status = 'Complete'
                } catch {
                    $backupState = if ($backupModified) { '备份清理中途失败，剩余内容可能已不完整' } else { '备份未作改动，完整保留' }
                    $analysis.Status = 'CompleteBackupRetained'
                    $analysis.Error = "链接已正常工作，完整数据位于目标副本：$target。$backupState：$backup。原因：$($_.Exception.Message)"
                    $script:State.Warnings = @($script:State.Warnings) + @($analysis.Error)
                    Write-Log "警告：$($analysis.Error)"
                }
            } else {
                $analysis.Status = 'CompleteBackupRetained'
                Write-Log "迁移完成；按设置保留备份：$backup"
            }
        } catch {
            $operationError = $_.Exception.Message
            if ($jobSucceeded) {
                # 提交点之后回滚会删除正在工作的链接；若备份已被部分删除，还会把残缺目录改回原路径。只记录警告。
                if ($analysis.Status -ne 'Complete') { $analysis.Status = 'CompleteBackupRetained' }
                $analysis.Error = "链接已正常工作，但收尾步骤出错：$operationError"
                $script:State.Warnings = @($script:State.Warnings) + @("$source：$($analysis.Error)")
                Write-Log "警告：$source 收尾步骤出错，链接保持不变：$operationError"
            } else {
                $analysis.Error = $operationError
                $analysis.Status = 'Failed'
                $script:State.Phase = 'Failed'
                Write-Log "错误：$operationError"
                if ($backupCreated) {
                    try {
                        if (Test-PathEntryExists $source) {
                            if (-not $linkCreated) {
                                # Get-Item 不支持长路径，统一用扩展路径的 DirectoryInfo 读取链接类型。
                                $possibleLink = [System.IO.DirectoryInfo]::new((Get-ExtendedLengthPath $source))
                                if ([string]$possibleLink.LinkType -eq [string]$Config.LinkType) {
                                    Remove-VerifiedLink -Path $source -Target $target -LinkType ([string]$Config.LinkType)
                                } else {
                                    throw "源路径已被其他对象占用，未覆盖；原数据仍在备份路径：$backup"
                                }
                            } else {
                                Remove-VerifiedLink -Path $source -Target $target -LinkType ([string]$Config.LinkType)
                            }
                        }
                        if (Test-PathEntryExists $source) {
                            throw "恢复目标路径仍被占用；原数据仍在：$backup"
                        }
                        [System.IO.Directory]::Move((Get-ExtendedLengthPath $backup), (Get-ExtendedLengthPath $source))
                        $analysis.Backup = ''
                        $analysis.Status = 'RolledBack'
                        $script:State.Errors = @($script:State.Errors) + @("迁移失败，已自动回滚恢复原源目录。来源：$source；目标副本保留：$target。原因：$operationError")
                        Write-Log '链接步骤失败；已通过同目录改名恢复原源路径，目标副本保留。'
                    } catch {
                        $analysis.Status = 'RecoveryRequired'
                        $analysis.Error = "$operationError；自动恢复也失败：$($_.Exception.Message)"
                        $script:State.Errors = @($script:State.Errors) + @("需要人工恢复。备份：$backup；目标副本：$target。$($analysis.Error)")
                        Write-Log "严重错误：自动恢复未完成。备份数据仍在 $backup；目标副本仍在 $target。$($_.Exception.Message)"
                    }
                } else {
                    $script:State.Errors = @($script:State.Errors) + @($operationError)
                }
            }
        }

        Write-State
        if (-not $jobSucceeded) {
            # 本项失败即停止；把尚未执行的作业明确标为“未执行”，避免界面残留“预检通过”。
            for ($remainingIndex = $jobIndex + 1; $remainingIndex -lt $jobs.Count; $remainingIndex++) {
                $jobs[$remainingIndex].Status = 'NotStarted'
            }
            Write-State
            return $false
        }
    }

    $script:State.Success = $true
    $script:State.Phase = 'Complete'
    Write-Log '所有目录均已完成迁移。'
    Write-State
    return $true
}

function Enter-EngineLock {
    # 迁移、清理、恢复都会改动来源或目标：同一时间只允许一个此类引擎运行，防止在“改名后、建链前”的
    # 窗口里恢复备份、在复制进行中清理目标，或两个窗口并发迁移同一来源。锁在引擎退出时释放。
    try {
        $script:EngineMutex = [System.Threading.Mutex]::new($false, 'Global\mklinktool-engine')
    } catch [System.UnauthorizedAccessException] {
        throw '另一个迁移、清理或恢复任务正在运行（无法访问其互斥锁），请等待它结束后再试。'
    }
    $acquired = $false
    try {
        $acquired = $script:EngineMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        # 上一个持有者异常退出：互斥锁已转归当前进程。
        $acquired = $true
    }
    if (-not $acquired) {
        $script:EngineMutex.Dispose()
        $script:EngineMutex = $null
        throw '另一个迁移、清理或恢复任务正在运行，请等待它结束后再试。'
    }
}

function ConvertTo-ActionItems($Config) {
    $index = 0
    foreach ($job in @($Config.Jobs)) {
        [pscustomobject][ordered]@{ Index = $index; Source = [string]$job.Source; Target = [string]$job.Target; Status = 'Waiting'; Error = ''; Warning = '' }
        $index++
    }
}

function Invoke-ItemAction($Config, [string]$Phase, [string]$RunningStatus, [string]$FailedStatus, [scriptblock]$Operation) {
    # 清理与恢复共用：逐项校验路径后执行 $Operation，单项失败不影响其余项，状态逐项写回供界面显示。
    $items = @(ConvertTo-ActionItems $Config)
    $script:State.Jobs = $items
    $script:State.Phase = $Phase
    Write-State
    foreach ($item in $items) {
        $item.Status = $RunningStatus
        Write-State
        try {
            $paths = Resolve-JobPaths $item.Source $item.Target
            $null = & $Operation $item $paths
        } catch {
            $item.Status = $FailedStatus
            $item.Error = $_.Exception.Message
            $script:State.Errors = @($script:State.Errors) + @("$($item.Source)：$($item.Error)")
            Write-Log "失败：$($item.Source)：$($item.Error)"
        }
        Write-State
    }
    $script:State.Success = (@($items | Where-Object { $_.Status -eq $FailedStatus }).Count -eq 0)
    $script:State.Phase = if ($script:State.Success) { 'Complete' } else { 'Failed' }
    Write-State
    return $script:State.Success
}

function Invoke-TargetCleanup($Config) {
    # 清理迁移在改名前失败或已回滚后遗留的目标副本。只在来源仍以普通目录完好保留在原路径、且不存在
    # 迁移备份时删除，确保被删除的副本不可能是数据唯一的完整拷贝。
    return Invoke-ItemAction $Config 'Cleaning' 'Cleaning' 'CleanupFailed' {
        param($Item, $Paths)
        if (-not (Test-PathEntryExists $Paths.Target)) {
            $Item.Status = 'Cleaned'
            $Item.Warning = '目标副本已不存在，无需清理。'
            return
        }
        $extendedSource = Get-ExtendedLengthPath $Paths.Source
        if (-not [System.IO.Directory]::Exists($extendedSource) -or
            ([System.IO.File]::GetAttributes($extendedSource) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "来源不是原路径上的普通目录，目标副本可能是唯一的完整数据，拒绝清理：$($Paths.Source)"
        }
        if (Test-PathEntryExists $Paths.Backup) {
            throw "存在迁移备份，状态不明确，拒绝清理：$($Paths.Backup)"
        }
        if ((Test-PathContains $Paths.Source $Paths.Target) -or (Test-PathContains $Paths.Target $Paths.Source)) {
            throw "来源与目标互相包含，拒绝清理：$($Paths.Source) / $($Paths.Target)"
        }
        $targetModified = $false
        try {
            [void](Remove-TreeSafely -Path $Paths.Target -ModificationStarted ([ref]$targetModified))
        } catch {
            if ($targetModified) { throw "目标副本未能完全删除（可能已部分删除）：$($Paths.Target)。原因：$($_.Exception.Message)" }
            throw
        }
        $Item.Status = 'Cleaned'
        Write-Log "已删除失败遗留的目标副本：$($Paths.Target)"
    }
}

function Invoke-BackupRestore($Config) {
    # 恢复在“源目录已改名为备份、尚未建立链接”时中断的迁移：仅当原路径上确实没有任何对象、
    # 且备份是普通目录时，把备份改回原名；原路径已有对象则不做任何改动。
    return Invoke-ItemAction $Config 'Restoring' 'Restoring' 'RestoreFailed' {
        param($Item, $Paths)
        if (Test-PathEntryExists $Paths.Source) {
            $Item.Status = 'RestoreSkipped'
            $Item.Warning = '原路径上已有对象（迁移可能已完成或已手动恢复），未做改动。'
            return
        }
        $extendedBackup = Get-ExtendedLengthPath $Paths.Backup
        if (-not [System.IO.Directory]::Exists($extendedBackup)) {
            throw "找不到迁移备份：$($Paths.Backup)"
        }
        if (([System.IO.File]::GetAttributes($extendedBackup) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "迁移备份路径是链接而不是目录，拒绝恢复：$($Paths.Backup)"
        }
        [System.IO.Directory]::Move($extendedBackup, (Get-ExtendedLengthPath $Paths.Source))
        $Item.Status = 'Restored'
        Write-Log "已把迁移备份改回原路径：$($Paths.Backup) -> $($Paths.Source)"
    }
}

try {
    if (-not [System.IO.File]::Exists($ConfigPath)) {
        throw "找不到工作配置：$ConfigPath"
    }
    Test-EngineOutputPath $LogPath
    Test-EngineOutputPath $RobocopyLogPath
    [System.IO.File]::WriteAllText($LogPath, '', $script:Utf8NoBom)
    # 注意：RobocopyLogPath 不做 UTF-8 预写。/UNILOG+ 以 UTF-16 追加写入，
    # 预先写 UTF-8 空文件会造成编码混合；文件不存在时由 Robocopy 首写并自带 BOM。
    # job.json 由 GUI 以 UTF-8（无 BOM）写入；PS 5.1 的 Get-Content 默认按 ANSI 解码，
    # 中文路径会乱码，必须显式指定编码。
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    Write-State
    Write-Log "开始 $Action。"

    if ($Action -eq 'Analyze') {
        $analysisResult = Get-MigrationAnalysis -Config $config
        $script:State.Jobs = @($analysisResult.Jobs)
        $script:State.Errors = @($analysisResult.Errors)
        $script:State.Warnings = @($analysisResult.Warnings)
        $script:State.Success = ($analysisResult.Errors.Count -eq 0)
        $script:State.Phase = if ($script:State.Success) { 'Ready' } else { 'PreflightFailed' }
        if ($script:State.Success) {
            Write-Log '预检通过。'
        } else {
            foreach ($message in $analysisResult.Errors) { Write-Log "预检错误：$message" }
        }
        Write-State
        if (-not $script:State.Success) { exit 1 }
    } else {
        Enter-EngineLock
        $success = switch ($Action) {
            'Migrate' { Invoke-Migration -Config $config }
            'Cleanup' { Invoke-TargetCleanup -Config $config }
            'Restore' { Invoke-BackupRestore -Config $config }
        }
        if (-not $success) { exit 1 }
    }
    exit 0
} catch {
    $script:State.Success = $false
    $script:State.Phase = 'Failed'
    $script:State.Errors = @($script:State.Errors) + @($_.Exception.Message)
    Write-Log "引擎异常：$($_.Exception.Message)"
    try { Write-State } catch { }
    exit 1
} finally {
    # exit 时 finally 仍会执行（已实测）；进程退出本身也会释放互斥锁，此处只是尽早释放。
    if ($null -ne $script:EngineMutex) {
        try { $script:EngineMutex.ReleaseMutex() } catch { }
        $script:EngineMutex.Dispose()
    }
}
