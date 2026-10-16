# agents.md — mklinktool 开发与踩坑笔记

本文件面向后续维护者与 AI 代理，记录本项目特有的约定、Windows PowerShell 5.1 陷阱与实际踩过的坑。改动前请先阅读。

## 项目架构速览

- `migrate-local-folders.cmd`：启动器，必须是纯 ASCII。脚本路径经环境变量 `MKLINKTOOL_GUI_SCRIPT` 交给 `powershell -Command "try { & $env:... } catch { MessageBox }"`：路径里的任何字符都不会被当作代码解析；脚本根本无法运行（语法错误、组策略强制的执行策略）时由这个 catch 弹框（只能写英文）。改用 `-File` 会让这些错误只打印到被隐藏的控制台。
- `migrate-local-folders.ps1`：GUI（WinForms，STA，非提权）。命名管道服务端，轮询 `state.json` 刷新界面。首行之后的脚本级 `trap` 弹框显示启动阶段（窗口出现前）的异常；它不拦截窗口显示后事件处理程序中的异常（那些仍由 WinForms 的异常对话框处理，2026-10-17 实测）。启动时检查工具目录权限（可被其他账户修改则红色警告，并给出修复命令）与中断恢复记录。请求已发出却没收到 Worker 的任务确认（超时、断开、回复无法解析）时进入**跟踪模式**：断开管道、保留 Worker 进程对象，界面保持锁定，凭结果文件、Worker 与引擎进程是否还在判断任务何时结束。
- `migration-worker.ps1`：经 UAC 启动的提权 Worker。校验父进程 PID 后连接命名管道，按 `Execute{RequestId, Action, SessionPath, SessionTempRoot}` 拉起引擎子进程，结束后写 `result-<RequestId>.json`。Action 白名单：Analyze / Migrate / Cleanup / Restore。主窗口等不到确认就会断开管道（但 Worker 仍能读到断开前已写入管道的请求，2026-10-16 实测），所以"已接受"回复发送失败时 Worker 仍须等引擎结束、写出结果文件后再退出，否则主窗口只能报告"没有返回结果"。同理，会话目录与请求编号校验通过之后、启动引擎之前的失败，也先写一份结果（`ExitCode` 与 `EnginePid` 为 null，附 `ErrorMessage`）再回复 `Error`；主窗口收到回复会删除会话目录，结果在回复之前就已写完，不存在竞争。结果统一经 `Write-RequestResult` 写出（临时文件 + 改名，拒绝重解析点，IO 错误有限重试）。
- `migration-engine.ps1`：Analyze（预检，含来源所在卷能否承载链接的检查 `Assert-SourceVolumeCanHoldLink`，以及按目标实际所在的卷检查本机固定磁盘与可用空间的 `Get-TargetVolumeInfo`）、Migrate（robocopy 复制 + `Copy-TreeOwners` 沿用来源的所有者 + 校验 + 源目录改名备份 + 建顶层 SymbolicLink + 删除备份；job.json 带 `KeepSourcePermissions` 时先由 `New-TargetRootWithSourceAccess` 按来源根目录的权限创建目标根目录）、Cleanup（删除改名前失败或已回滚遗留的目标副本）、Restore（把中断迁移的备份改回原路径）。后三者持有 `Global\mklinktool-engine` 互斥锁。
- **提交点**：Migrate 中链接建立并验证通过、且改名后的备份与复制校验时的来源快照一致（路径、大小、修改时间、嵌套链接）后即视为提交（`$jobSucceeded`）；复核发现差异说明来源在校验后仍被写入，按建链失败回滚。提交点之后的任何异常只能记警告、不得回滚——回滚会删掉正在工作的链接，若备份已被部分删除还会把残缺目录改回原路径（2026-10-14 故障注入实测）。
- 会话目录：`%TEMP%\mklinktool-<guid>\`（job.json / state.json / engine.log / robocopy.log / result-*.json），每个任务一个。主窗口显示时由 `Remove-StaleSessionDirectories` 删除超过 7 天（`$script:SessionRetentionDays`）的会话：只删名称严格匹配、只含普通文件、本身不是链接的目录，按其中最晚的修改时间计算。中断恢复记录：`%LOCALAPPDATA%\mklinktool\pending\<会话名>.json`，迁移前写入，全部成功后删除，启动时按文件系统实际状态复查。
- 安全模型：管道名含 128 位 GUID；GUI 校验 client PID、Worker 校验 server PID；管道 ACL 授予当前用户 + `BUILTIN\Administrators`（后者是为了"另一个管理员账号"OTS 提权场景）。
- UI 与引擎之间唯一的进度通道是 `state.json`（引擎 tmp+Replace 原子写，UI 每 500ms 轮询）。每项结果带 `Index`（job.json 中的顺序），GUI 按序号匹配，不按路径文本匹配。作业的 `Status` 只存状态码，显示时由 `Convert-StatusText` 转中文。state.json 还带引擎自己的 `EnginePid`/`EngineStartTime`，供跟踪模式判断引擎是否仍在运行。
- **轮询顺序**：每次先判定任务是否结束（结果文件、Worker 与引擎进程），再读日志和 state.json。Worker 只在引擎退出后才写结果、才退出，所以先确认结束、后读取，读到的必是最终状态；反过来，引擎的最后一次写入可能恰好落在两步之间而被永久漏掉（2026-10-15 用测试桩复现）。

## 文件编码规则（重要）

**历史由来（已核实，见 operation-notes.md）**：早期脚本曾被较新的 PowerShell 以无 BOM 的 UTF-8 写出，而 Windows PowerShell 5.1 把无 BOM 文件按本机 ANSI（中文系统 = GBK）解码，中文乱码并破坏解析——当时的修复是把 .ps1 存成 UTF-16LE 带 BOM。所以 **UTF-16LE 是为了 PowerShell，与 cmd 无关**；cmd 恰恰相反，批处理绝不能是 UTF-16。

**现行约定**：

| 文件类型 | 编码 | 原因 |
|---|---|---|
| `.ps1` | UTF-8 **带 BOM** | PS 5.1 尊重 BOM 正确解码中文；PowerShell 7 默认 UTF-8；grep/diff/常见工具链友好。UTF-16LE 虽然也能被 PS 5.1 识别，但会让文本工具看到 NUL 字节、体积翻倍（2026-10 的编码损坏事故即因此难以排查）。 |
| `.cmd` / `.bat` | 纯 ASCII | cmd 无法解析 UTF-16；UTF-8 BOM 在部分 cmd 版本会破坏首行 `@echo off`。因此启动器里的兜底提示与注释只能写英文。 |
| 数据文件（job.json / state.json / engine.log） | UTF-8 无 BOM，**读写两侧都必须显式指定编码** | GUI 写入用 `UTF8Encoding($false)`；引擎/ GUI 读取必须带 `-Encoding UTF8` 或 `Encoding.UTF8`，否则 PS 5.1 默认按 ANSI 解码。 |
| robocopy.log | **绝不预写** | 由 `/UNILOG+` 独占创建/追加，编码随 robocopy 版本而定（新版本实测为单字节/UTF-8，旧版本为 UTF-16 LE）。预写其他编码会造成编码混合。引擎带 `/NFL /NDL` 运行 robocopy：日志只有出错项与汇总，实测出错行仍带完整路径与原因。 |

**换行**：仓库内统一存 LF；`.gitattributes` 让 `.ps1`、`.cmd` 检出为 CRLF，不受各人 `core.autocrlf` 设置与 GitHub ZIP 下载方式影响。

**编码事故取证技巧**（2026-10 实战）：
- 症状：脚本报大量语法错误、`git diff` 显示二进制、行数虚增。先看文件头字节：`FF FE` = UTF-16LE BOM；`EF BB BF` = UTF-8 BOM；`FF FE FD FF FD FF` 开头 + 每字符 4 字节 = 双重编码损坏（UTF-16LE 字节流被误当 UTF-8 解码后又存回 UTF-16LE）。
- 体积指纹：UTF-16LE 文件字节数 ≈ 2×字符数，UTF-32 式 ≈ 4×。git blob 大小（`git cat-file -s`）可无损对比 HEAD 与工作区。
- 把非 ASCII 连续段折叠成单个 `?` 再 diff，可快速判断损坏文件里是否还有独有代码（本次结论：没有，ASCII 代码行全部完好，可放心 `git checkout` 恢复）。
- 中文区乱码会散落真实的 CR/LF 字符（如 U+4E0A 的 UTF-16LE 字节 `0A 4E`），导致行数虚增——行数差不代表内容差异。

## Windows PowerShell 5.1 / .NET Framework 陷阱

**长路径（>260 字符）**：
- Windows PowerShell 5.1 启动时自己关掉了 .NET Framework 的旧式路径处理：`Switch.System.IO.UseLegacyPathHandling` 与 `Switch.System.IO.BlockLongPaths` 均为 false，开关名写在 `System.Management.Automation.dll` 里，`powershell.exe.config` 与注册表 `HKLM\SOFTWARE\Microsoft\.NETFramework\AppContext` 都没有设置。因此 `GetFullPath`、`GetDirectoryName`、`GetPathRoot` 处理总长超过 260 字符的路径不会抛异常，每台装有 5.1 的电脑都一样，与系统的 `LongPathsEnabled` 无关（2026-10-17 实测：由 36 字符的段组成、共 298 字符的路径均正常）。单段名字超过 255 个字符时这三个方法仍抛 `PathTooLongException`（这是 NTFS 本身的上限，枚举得到的真实路径不会出现）；`GetPathRoot` 也会先规范化路径，不是纯字符串操作，只有 `GetFileName` 不做检查。PowerShell 7 对这四个方法都不检查。此前这里写的“只在未启用 `LongPathsEnabled` 时抛异常、开发机启用了它所以不抛、相关分支在本机测不到”是错的。
- `LongPathsEnabled`（`HKLM\SYSTEM\CurrentControlSet\Control\FileSystem`）只影响把不带 `\\?\` 前缀的长路径直接交给 Win32 的调用，而且只对清单声明了 `longPathAware` 的程序生效：`powershell.exe` 声明了，`robocopy.exe` 没有（Robocopy 自己处理长路径）。引擎调用 Win32 时都自己加 `\\?\`，不依赖这个开关。开发机上它从 2023-06-20 装系统当天起就开着（该注册表键此后没有改动过；当天还装了 Python 3.9.13，其安装程序的 “Disable path length limit” 改的就是这一项，最可能是它）。Windows 默认关闭；开关关闭时的情况没有实测过。
- 深层目录实测（2026-10-17，真实引擎，非提权，在 `%TEMP%` 下）：两个来源的最深文件路径都是 351 字符，其中一个在同样深的位置含相对目录符号链接，预检都通过；只含深层文件的那个随后迁移成功，经新链接能读到最深的文件。长路径目前没有自动测试覆盖。
- `GetFullPath` 本身会展开 8.3 短名，末段不存在时也会展开已存在的前缀（实测 `C:\PROGRA~1\nonexistent\sub` → `C:\Program Files\nonexistent\sub`）；只有 `PathTooLongException` 分支需要手工 `GetLongPathNameW`。
- 设备路径（`\\?\C:\...`、UNC 用 `\\?\UNC\`）跳过长度检查，且 .NET Fx 对其原样返回不做归并——`\\?\` 路径必须用反斜杠。
- PS 5.1 cmdlet（`Get-Item`/`Rename-Item`/`New-Item`/`Get-ChildItem`）不支持长路径；用 .NET + `\\?\` 替代：改名用 `[IO.Directory]::Move`，枚举用 `[IO.Directory]::EnumerateFileSystemEntries`。
- robocopy 自身支持长路径，保持传普通路径（不要加 `\\?\`）。
- 注意方法归属：`EnumerateFileSystemInfos` 是 `DirectoryInfo` 的实例方法，`[IO.Directory]` 上只有 `EnumerateFileSystemEntries`（返回字符串）——想当然会编译期不报错、运行期才炸。
- 超长路径无法归并 `..` 段时必须 fail-closed 拒绝，否则路径包含检查可被字符串把戏绕过。

**符号链接**：
- PS 5.1 的 `New-Item -ItemType SymbolicLink` 走旧 API，需要 `SeCreateSymbolicLinkPrivilege`，且不支持长路径。用 P/Invoke `CreateSymbolicLinkW`：先传 flags 3（DIRECTORY 1 | ALLOW_UNPRIVILEGED_CREATE 2，开发者模式无需特权），错误码 87（旧系统不认识 flag 2）再回退 flags 1。
- **`CreateSymbolicLinkW` 返回 1 字节的 `BOOLEAN`，声明必须加 `[return: MarshalAs(UnmanagedType.I1)]`**。按默认 4 字节 BOOL 封送会读入 EAX 高位残值：实测非提权 flags=1 失败时原始返回值为 `0x00000500`，被读成 TRUE。早先记录的"某些安全策略让 flags 1 返回 TRUE 但什么都没创建"就是这个封送错误，并非策略或沙箱所致。建链后的存在性验证仍保留作纵深防御。
- 声明 P/Invoke 前先查返回类型：返回 `BOOLEAN`（1 字节）的 API 都要按 I1 封送；返回 `BOOL`（4 字节）的，如 `CreateHardLinkW`、`GetNamedPipeClientProcessId`，用默认 `bool` 即可。
- 预检探针必须与真实建链用同一 API 与参数，否则产生假阴性/假阳性。
- `LinkType`/`Target` 是 PowerShell 扩展类型数据（不是 .NET Fx 原生属性），但**直接 `[System.IO.DirectoryInfo]::new()` 的实例同样可用**，且 `Target` 返回的是去掉 `\\?\` 前缀的形态。

**文件系统**：
- `[IO.Directory]::Delete($path, $true)` 遇只读文件抛 `UnauthorizedAccessException`；只读目录、只读 Junction/符号链接连单体 `Directory.Delete` 都会被拒绝——删除前对根、目录、链接、文件统一清 `ReadOnly`（desktop.ini 自定义图标的文件夹就是只读目录）。
- 对链接调用 `[IO.File]::SetAttributes` 改的是链接本身，不影响链接目标（已实测），清只读不会改动目标数据。
- `[IO.Directory]::Exists`/`[IO.File]::Exists` 同样不跟随路径末段的链接（底层 `GetFileAttributesEx` 返回链接自身的属性）：悬空的 Junction 与目录符号链接，`Directory.Exists` 返回 True，普通路径与 `\\?\` 路径相同（2026-10-17 实测）。所以主窗口的 `Test-InterruptedMigration` 与引擎的 `Test-PathEntryExists` 对悬空链接的判断一致，都算“原路径上有对象”（第五轮评审的 L2 不成立）。要判断目录能否真正进入，得打开它（例如 `Get-DirectoryVolumeInfo` 对悬空链接打不开句柄）。
- .NET Framework 的递归删除遇错**会继续删除其余条目**，最后才抛出第一个异常：失败时目录往往已接近删空，提示文案不能写"备份仍保留"。`Remove-TreeSafely` 用 `[ref]$ModificationStarted` 区分"未作改动"与"可能已部分删除"。
- 计算哈希/校验时用 `FileShare::ReadWrite`，`FileShare::Read` 会因其他进程持有写句柄而炸。
- `GetFileSystemInfos()`/`FindFirstFile` 返回的大小与时间来自 NTFS 目录项，文件仍被写入时可能滞后（微软文档有说明）。快照要发现写入，所以对每个文件另建 `FileInfo` 重新读取，不要为省一次 stat 改用枚举结果。另外，文件仍被打开写入时，修改时间可能要到句柄关闭才更新：同一大小的原地改写在关闭前查不出来，这类情况只能靠“迁移前关闭应用”与目录改名失败来拦截。
- `GetFileSystemInfos()` 按名称通配匹配会把 `[` 当通配符；需要精确匹配时全量枚举后自行比较。
- PS 5.1 `Set-Content -PassThru` 返回的是字符串不是 FileInfo（写测试脚本时容易踩）。

**卷与网络位置**（2026-10-17 实测）：
- 判断一个目录实际在哪个卷，要打开它的句柄（`CreateFileW` + `FILE_FLAG_BACKUP_SEMANTICS`，会跟随路径中的挂载文件夹、Junction 与符号链接）再查询。按路径判断会漏判：C: 上指向网络共享的目录符号链接，`GetVolumePathNameW` 返回 `C:\`、`GetDriveType` 报固定磁盘（指向另一本地卷的 Junction 它倒能正确解析）。
- 经 SMB 访问的目录，`GetVolumeInformationByHandleW` 报告的是服务器端的文件系统（NTFS）和标志（含 `FILE_SUPPORTS_REPARSE_POINTS`），只看文件系统标志拦不住网络共享。是否远程要看 `NtQueryVolumeInformationFile(FileFsDeviceInformation)` 的 `FILE_REMOTE_DEVICE`（0x10），这也是 `GetDriveType` 内部的依据；本机卷与经本机共享回环访问的同一目录，结果分别为 0x20020 与 0x10。
- 目标一侧同样要按句柄判断（第五轮评审 M1）：`%TEMP%` 下指向 `E:\testcode1` 的 Junction，经它访问的路径 `GetPathRoot` 为 `C:\`，`DriveInfo` 给出 C: 的约 7.0 GB 可用空间，按句柄查询 `FileFsFullSizeInformation`（与 `GetDiskFreeSpaceEx` 一致）得到 E: 的约 77.4 GB；指向共享的符号链接，`DriveInfo` 报 `Fixed`。目标在预检时还不存在，`Get-TargetVolumeInfo` 从最近的已存在上级目录查询。
- `FileFsDeviceInformation` 的 `DeviceType`：本机 NTFS 卷与经 SMB 访问的目录都报告 0x7（`FILE_DEVICE_DISK`），区别只在 `FILE_REMOTE_DEVICE`。“本机固定磁盘”按 `GetDriveType` 的依据判断：`DeviceType` 为 7 或 8，不是远程设备，也不带 `FILE_REMOVABLE_MEDIA`（0x1）。
- 本机的 `\\localhost\Users` 共享可用来在测试中得到网络路径（引擎用例 [E17]、[E20]），不需要提权，也不改动系统设置。

**访问控制（ACL）**（2026-10-17 实测）：
- Robocopy `/COPY:S` 把来源的规则原样带到目标：规则仍标记为“继承”，DACL 却未受保护，而目标的父目录里并没有这些规则；一旦父目录重新传播继承，它们就会被父目录的规则取代。要让目标根目录保持来源权限，应先按来源根目录的规则创建受保护的目标根目录，再用 `/COPY:DAT` 复制（`New-TargetRootWithSourceAccess`）。
- `FileSystemAccessRule` 的构造函数拒绝通用权限位：仅供继承的 ACE 常带 `GENERIC_ALL`（268435456）等，逐条重建规则会抛 `ArgumentOutOfRangeException`。复制 DACL 应改写 `RawSecurityDescriptor` 中原始 ACE 的标志；实测 ACE 的顺序（包括不规范的顺序）原样保留。
- `AceFlags` 以 byte 为底层类型：`$ace.AceFlags -band (-bnot [AceFlags]::Inherited)` 报“指定的转换无效”，要先转 int：`[AceFlags]([int]$ace.AceFlags -band (-bnot [int][AceFlags]::Inherited))`。
- `[IO.Directory]::CreateDirectory($path, $security)` 创建的 DACL 缺少“自动继承”（SE_DACL_AUTO_INHERITED）标志：其中新建的文件会按旧式继承得到受保护的显式副本，以后在根目录上改权限不会传播下去。创建后再用同一描述符 `SetAccessControl` 一次即可补上（`D:P` 变为 `D:PAI`），之后新建的文件与来源中新建的文件得到的规则完全一致。
- `icacls` 遇到本机无法解析的 SID（例如沙箱工具添加的条目），在 `/remove`、`/grant` 中会报错 1332，且**整条命令都不生效**（“Successfully processed 0 files”）。要把权限整个换掉，用 PowerShell 新建 `DirectorySecurity`（`SetAccessRuleProtection($true, $false)` 后只加需要的规则）再 `Set-Acl`，对任何 SID 都有效，子项随之继承。
- **所有者**：提权进程新建的目录与文件归 `BUILTIN\Administrators`（提权令牌的默认所有者），不归用户本人；非提权时归用户本人。不需要额外特权就能指定为所有者的，只有令牌自身的用户 SID 和带“可作为所有者”属性的组（提权令牌中的 Administrators）；SYSTEM、TrustedInstaller、其他账户需要额外特权。
- Robocopy `/COPY:O` 不可靠：所有者指定不了时报 `ERROR 1307`，实测还跳过了该目录的内容、退出码却是 0；官方文档也没写它需要的特权。所以改为复制后由引擎逐项设置（`Copy-TreeOwners`）。
- Git for Windows 2.41 在普通权限下打开所有者为 Administrators 组的仓库，报 `detected dubious ownership` 并以 128 退出；它会解析链接，检查的是目标目录的所有者，链接本身的所有者无关（均为 2026-10-17 提权实测）。测试 Git 默认行为时用 `GIT_CONFIG_NOSYSTEM=1` 与 `GIT_CONFIG_GLOBAL=<空文件>` 隔离配置：开发机的全局配置里有 `safe.directory = *`，会把问题掩盖掉。
- PowerShell 7 中 `DirectoryInfo` 没有 `GetAccessControl()` 实例方法（.NET Core 改成了扩展方法），PS 5.1 有；在 PS 7 里查看权限用 `Get-Acl`。Claude Code 的 PowerShell 工具运行的是 PowerShell 7，实测代码一律用 `powershell.exe -File` 跑在 5.1 上。

**GUI（WinForms）**：
- `RowHeadersVisible=$false` 时行级 `ErrorText` 图标不可见，错误提示必须挂在单元格（如 Status 列）上。
- DataGridView 开双缓冲需反射：`GetProperty('DoubleBuffered', 'Instance,NonPublic').SetValue($grid, $true, $null)`。
- 若表格行与外部列表严格按序 1:1 对应，必须把所有列设 `SortMode='NotSortable'`，否则用户点表头排序即错位。
- 就地刷新时 `ErrorText`/`ToolTipText` 要无条件赋值（含空串），否则旧错误残留。
- `CellEndEdit` 在进入编辑后未改动、甚至按 Esc 取消时也会触发（已实测）：处理程序必须先比较新旧值。
- `CellMouseDown` 的 `e.X/e.Y` 相对于单元格；弹出菜单用 `ContextMenuStrip.Show([Cursor]::Position)`。
- 运行期间不要 `$grid.Enabled = $false`（禁用后无法滚动、看不到下方行的进度与错误）；只锁可编辑列，并在 DragEnter 中显式拒绝拖放。
- 命名管道 ACL：OTS 提权 Worker 的用户 SID 与主窗口不同，但其令牌组含已启用的 `BUILTIN\Administrators`（SID `S-1-5-32-544`，用 SecurityIdentifier 构造避免本地化名称问题）。
- **非提权的 GUI 按完整性级别无法终止任何提权进程**（同一账户 UAC 提权的也不行）：`taskkill /T /F` 与 `Process.Kill()` 都会被拒绝。不要把"结束 Worker/引擎"当作清理手段；并发安全由引擎互斥锁保证。`Stop-WorkerProcess` 只用于空闲或尚未接手任务的 Worker，且不带 `/T`。
- 判断提权引擎是否还在：`Get-Process -Id`（只列出仍在运行的进程，即使别处还持有句柄）+ 进程名 + 启动时间，必要时 `WaitForExit(0)`（只需 SYNCHRONIZE）。**对 `Get-Process` 得到的提权进程不要读 `HasExited`**：这种对象不带句柄，.NET Framework 读它时用 `OpenProcess` 申请 `PROCESS_QUERY_INFORMATION`，会被完整性级别拒绝；而 PowerShell 又会把这个异常吞成 `$null`（见下一节），判断结果全凭碰巧。判断不了时按“仍在运行”处理。
- Worker 不同：主窗口的 `$script:Worker` 是经 UAC 启动时 `Start-Process -PassThru` 返回的对象，持有启动时得到的句柄，.NET 直接用这个句柄查询，只需 `PROCESS_QUERY_LIMITED_INFORMATION`，所以对它读 `HasExited` 是可靠的：提权实测 [X5] 断言 Worker 退出后读到 True（2026-10-16、10-17 两次通过）。2026-10-17 用受限句柄模拟（反射调用 `Process.SetProcessHandle`）：句柄只有 `SYNCHRONIZE` 时，退出后 `HasExited` 确实变成 `$null`，但这时 `Id` 也读不出来，`Connect-ElevatedWorker` 的 PID 校验会先失败，进不了跟踪模式（第五轮评审的 M2 因此不成立）。
- 连接 Worker（含提权 PowerShell 的启动）、握手与等待任务确认都在界面线程上同步进行，各以 30 秒为上限。Worker 回复确认之前只做 JSON 解析、会话路径校验和 `Start-Process`，正常不到 1 秒；Worker 断开时读取立即返回，不会等满 30 秒。不要为了“Worker 挂起”缩短确认等待（第五轮评审 M3）：正常但稍慢的回复会被误判为确认丢失而进入跟踪模式，状态栏提示“未收到任务确认”，任务结束后 Worker 随之退出，下次操作要再点一次 UAC。
- 用 UI Automation 读取 MessageBox 的正文时不要按 `ControlType.Text` 筛选：实测正文是类名为 `Static` 的控件，被报告为 `Pane`。取全部后代的 `Name` 拼起来即可（`tests\Test-Startup.ps1`）。

**PowerShell 语言细节**：
- 中文弯引号 `“ ”` 在 PowerShell 中等同于双引号：写在双引号字符串里会提前截断字符串（解析报 Unexpected token）。含弯引号的文本用单引号字符串，配合 `-f` 格式化。
- 逗号运算符优先级高于 `+`：`@($a, '\\?\' + $b)` 会被解析成三个元素，要写成 `@($a, ('\\?\' + $b))`。
- 调用 .NET 方法时，PowerShell 会把 `$null` 转成空串传给 `string` 参数（实测 `[IO.File]::Replace($a, $b, $null)` 抛"路径格式非法"）；要传真正的 null 用 `[System.Management.Automation.Language.NullString]::Value`。
- `Join-Path` 会解析 PowerShell 驱动器：基路径是不存在的盘符（如 `Q:\`）时直接抛 `DriveNotFoundException`。处理用户输入的路径时用字符串拼接或 `[IO.Path]::Combine`。
- `-band` 等位运算的优先级低于比较运算：一律写成 `(($x -band $flag) -ne 0)`。
- **属性 getter 抛出的异常会被静默吞掉**：表达式里的 `$obj.Prop` 若 getter 抛异常，结果是 `$null`，既进不了 `catch`，也不记入 `$Error`（PS 5.1 实测，`Set-StrictMode -Version 2.0` 下相同）。所以 `try { $p.HasExited } catch {}` 永远捕获不到“拒绝访问”，`-not $p.HasExited` 反而得到 `$true`。需要拿到异常时调用方法形式 `$obj.get_Prop()`，或换用本身就是方法的 API。
- 脚本级 `trap` 只处理脚本主体（及其调用的函数）抛出的异常；WinForms 事件处理程序中的异常不经过它，仍交给 `Application.ThreadException`（2026-10-17 实测）。`trap` 里 `exit` 只结束脚本：经 `& 脚本` 调用时回到调用方，不会再触发调用方的 catch。
- 用 `-Command` 运行脚本时，把路径放进环境变量再 `& $env:X`，路径中的空格、单引号等都不会被解析成代码（实测）；`$PSScriptRoot`、`$PSCommandPath` 与 `-File` 时相同。脚本的语法错误、执行策略拦截在 `& $env:X` 处以 `ParseException`、`PSSecurityException` 抛出，能被 `try/catch` 捕获；`-File` 下它们只打印到控制台。

## 工具链与测试心得

- 涉及符号链接/特权的测试要用真实文件系统状态（而非仅 API 返回值）做断言。早先记录的"沙箱内 flags 1 假成功"实为 P/Invoke 封送错误（见"符号链接"一节）。
- 复杂 PowerShell 测试一律写成 `.ps1` 文件用 `powershell.exe -File` 执行；内联 `-Command` 的多层引号转义几乎必炸。
- 含中文的测试脚本同样必须存成 UTF-8 带 BOM，否则 PS 5.1 按 GBK 解码，中文注释可能吞掉换行、破坏代码。典型症状是不报语法错误，注释下一行的语句却像没执行一样（变量为 `$null`）。文件写入工具通常写出无 BOM 的 UTF-8，写完记得转换。通过 Bash heredoc 生成文件时 `\\` 会被吞成 `\`（`\\?\` 前缀被破坏），这类内容改用文件写入工具或 PowerShell 写出。
- **测试必须跑在产品目标运行时上**：Windows PowerShell 5.1（powershell.exe）与 PowerShell 7（pwsh）在编码默认值、长路径、API 表面上行为不同；本项目目标是 PS 5.1。
- 非提权运行引擎做端到端测试时（开发者模式下顶层建链可成功），Robocopy `/SL` 无法创建**嵌套符号链接**（需要 `SeCreateSymbolicLinkPrivilege`），复制校验会报"嵌套链接数不一致"。嵌套链接用 Junction 测，嵌套符号链接需提权测试。
- **测试在 `tests/` 中**（2026-10-16 入库）：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-AllTests.ps1` 依次运行 `Test-Static.ps1`（所有 `.ps1` 语法与 BOM、`.cmd` 纯 ASCII）、`Test-Engine.ps1`（引擎端到端与故障注入）、`Test-Gui.ps1`（假 Worker）、`Test-Gui.ps1 -Mode RealWorker`（真实 Worker 与引擎以普通权限运行）与 `Test-Startup.ps1`（经启动器副本启动，检查启动失败提示），按各自的 `SUMMARY pass= fail=` 行汇总，有失败时退出码为 1，约 70 秒（2026-10-17：202 项；提权模式另有 30 项）。加 `-IncludeElevated` 再跑 `Test-Gui.ps1 -Mode Elevated`：仓库里原样的 Worker 经 UAC 提权，需要有人点一次“是”。发起请求的进程不在前台时，UAC 提示可能不直接切到安全桌面，只在任务栏闪烁，要点开才出现；约 2 分钟无人响应会自动取消，测试随即失败、不做任何改动。共用函数在 `TestHelpers.ps1`（断言、摘要、安全删除测试目录、在脚本副本中替换唯一匹配文本的 `Set-UniqueText`、`ConvertTo-Literal`）与 `gui\GuiHarness.ps1`。需要开发者模式（或管理员身份）与桌面会话；只在 `%TEMP%` 下的临时目录里工作并自行清理。改动三个脚本后都应跑一遍；新增行为同时补用例。实现方法如下：
  - 引擎：复制一份引擎，用"正则匹配唯一一行并插入或替换为测试代码"的方式注入故障，再以 `-File` 运行。覆盖：正常迁移（删除/保留备份）、N5 的三个写入时机、建链失败回滚与后续项 NotStarted、提交点后异常不回滚、备份删除中途失败与删除前枚举失败的提示、跨任务冲突写回各行、Cleanup（不跟随链接、三种拒绝情形）、Restore、引擎互斥锁、来源位于网络位置（经 `\\localhost\Users` 共享与指向它的目录符号链接；没有该共享时输出 SKIP）、不能承载链接的卷（本机都是 NTFS，注入卷信息模拟 FAT32 与只读卷）、目标沿用来源权限（勾选与不勾选各一次，比较规则集合）、目标按实际所在的卷检查（UNC 目标与经指向共享的符号链接的目标被拒绝；经 Junction 指向仓库所在的另一块卷时，注入的日志行记下查询到的卷序列号，与 `vol` 的结果对照，两者在同一卷上时输出 SKIP；注入卷信息模拟非固定磁盘、空间不足与 FAT32）。注意 GUI 测试会在副本里替换 `-Verb RunAs`、等待连接的循环等文本并要求唯一匹配，产品代码的注释里不要原样重复这些文本。
  - 引擎辅助函数：用 `[Parser]::ParseFile` 取 AST，把 `Add-Type` 与所需函数的 `Extent.Text` 点调用进测试会话。
  - GUI：把 GUI 脚本副本末尾的 `[void]$form.ShowDialog()` 替换为点调用测试主体（在 GUI 作用域内运行），窗体移到屏幕外 `Show()`，伪造 state.json / engine.log / result 文件后调用 `Update-WorkerView`。注意：点调用脚本里的 `exit` 退出码传不出 `-File` 进程，按输出摘要判断成败；会弹 MessageBox 的函数需在测试主体里重定义为桩。
  - 轮询时序：在测试主体里重定义 `Refresh-Grid`（它位于一次轮询的中间），第一次调用时写入最终 state.json 与结果文件，即可确定性地复现“结束发生在两步之间”。
  - Worker 协议与跟踪模式：把 `Connect-ElevatedWorker` 重定义为空函数，测试主体自建 `NamedPipeServerStream`，另起一个 PowerShell 进程扮演 Worker（读请求后按模式：正常接受 / 不回复但照样写结果 / 回复 Error / 直接退出 / 留下仍在运行的“引擎”后退出），把它的 `Process` 对象赋给 `$script:Worker`。`$script:RecoveryJournalRoot` 指到临时目录，避免写入真实的中断恢复记录。
  - 完整性级别的模拟：非提权测试里，用 `SetSecurityInfo` 给替身进程加拒绝 `PROCESS_QUERY_INFORMATION`（0x400）与 `SYNCHRONIZE`（0x100000）的 ACE，即可重现主窗口访问提权引擎时拿不到的权限。
  - 会话目录清理：测试主体先保存 `${function:Remove-StaleSessionDirectories}` 再把它换成桩（窗口显示时会调用它，不能让测试清理真实的 `%TEMP%`），然后对临时根目录调用保存的原函数。
  - 真实 Worker（`gui\WorkerTests.Body.ps1`）：不桩 `Connect-ElevatedWorker`，走真实的管道、PID 校验、握手与引擎。普通权限模式由启动器复制一份去掉提权检查的 Worker（与引擎放在同一目录），并去掉 GUI 副本里的 `-Verb RunAs`；提权模式用仓库原样的 Worker，并把副本里等待连接的 30 秒放宽到 120 秒。让来源改名失败的做法：用 `FileShare.Read`（不含 Delete）打开来源里的一个文件，目录改名会报“访问被拒绝”，但文件仍能被 Robocopy 读取复制。模拟确认丢失：把 `$script:WorkerReadTimeoutMs` 设为 1。[X9] 迁移一个 Git 仓库，比较迁移前后根目录、`.git` 与文件的所有者，并以隔离配置的 Git 经原路径（链接）与目标路径各运行一次 `git status`；它排在 X5 之前，因为 X5 结束时 Worker 会退出，提权模式下再迁移就要多点一次 UAC。Worker 自身的故障（[X6]–[X8]）由测试主体把 Worker 副本注入后另存到同一目录、改指 `$script:WorkerPath` 再重连；只在普通权限模式下运行（提权模式下要再点一次 UAC）。注入的失败若立即发生，Worker 的回复可能抢在主窗口 1 毫秒的等待超时之前到达，跟踪模式就不会出现：注入代码先 `Start-Sleep` 1.5 秒（2026-10-17 实测踩到）。
  - 启动失败提示（`Test-Startup.ps1`）：把启动器与 GUI 副本放进名称含空格和单引号的临时目录，经 `cmd /c` 运行启动器副本；启动器用 `start` 拉起的 PowerShell 是 cmd 的子进程，按父进程号找到它，等标题为 mklinktool 的窗口出现后用 UI Automation 读出正文，再 `CloseMainWindow()` 关闭并确认进程退出（若弹出第二个对话框，进程就不会退出）。这些对话框会在屏幕上短暂出现。
  - GUI 测试的启动 trap：`Test-Gui.ps1` 在 GUI 副本中把 trap 里的 MessageBox 换成控制台输出，否则测试主体之外的异常会弹框、一直等人点击。
- 修改三个脚本后最低限度回归：`tests\Test-Static.ps1`（语法 + BOM）；能跑全套时跑 `tests\Invoke-AllTests.ps1`。

## 已知边界

- 引擎仅支持顶层 SymbolicLink（Junction 只作为来源内部的嵌套链接由 robocopy 保留）。
- 相对路径、盘符根目录在预检/添加阶段即被明确拒绝。
- 非提权 GUI 无法终止任何提权 Worker/引擎（taskkill 会失败并提示等待其自行退出）；请求已发出但确认丢失时进入跟踪模式，等任务确实结束才解锁；引擎互斥锁保证不会出现第二个并发的迁移引擎。
- 写入检测（N5）覆盖“复制后、校验快照前”与“校验后、提交前”两个窗口；检测不到的是：在改名后仍持有句柄（以 FILE_SHARE_DELETE 打开）的应用在复核之后的写入，以及修改时间推迟到句柄关闭才更新的同大小原地改写。
- 目标卷为 FAT32 时不比较修改时间（以本地时间保存，跨夏令时会差整小时），exFAT 允许 2 秒误差，NTFS/ReFS 精确比较。
- 来源必须位于能承载符号链接的本机卷（支持重解析点、不是只读）；网络位置一律拒绝；可移动磁盘上的 NTFS 卷允许。
- 目标必须位于本机固定磁盘，按实际所在的卷判断（目标路径经挂载文件夹、Junction、目录符号链接时看它们指向的卷）；网络位置与可移动磁盘拒绝。可用空间与修改时间容差同样按实际的卷。
- 默认不复制源目录 ACL，目标副本继承目标位置权限，预检只提示、不阻断；勾选“目标沿用来源的访问权限”时，目标根目录沿用来源根目录当前生效的权限，来源子项上单独设置的权限仍不复制。所有者在复制后逐项改回来源的所有者，但引擎无权指定的除外：来源中归 SYSTEM、TrustedInstaller 或其他账户所有的项，以及以另一个管理员账号提权（OTS）时归主窗口用户所有的项，仍归 `BUILTIN\Administrators`；后一种情况下，Git 在普通权限下会拒绝打开迁移后的仓库（dubious ownership）。
- 工具目录权限检查只警告并给出修复办法，不阻断：检查代码与被保护的脚本在同一目录，挡不住已经发生的篡改，真正的防线是安装位置。
- 受约束语言模式（AppLocker/WDAC）下 Add-Type 与 WinForms 都不可用，启动失败时无法弹出提示。
