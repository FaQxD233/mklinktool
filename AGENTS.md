# agents.md — mklinktool 开发与踩坑笔记

本文件面向后续维护者与 AI 代理，记录本项目特有的约定、Windows PowerShell 5.1 陷阱与实际踩过的坑。改动前请先阅读。

## 项目架构速览

- `migrate-local-folders.ps1`：GUI（WinForms，STA，非提权）。命名管道服务端，轮询 `state.json` 刷新界面。启动时检查工具目录权限（可被其他账户修改则红色警告）与中断恢复记录。请求已发出却没收到 Worker 的任务确认（超时、断开、回复无法解析）时进入**跟踪模式**：断开管道、保留 Worker 进程对象，界面保持锁定，凭结果文件、Worker 与引擎进程是否还在判断任务何时结束。
- `migration-worker.ps1`：经 UAC 启动的提权 Worker。校验父进程 PID 后连接命名管道，按 `Execute{RequestId, Action, SessionPath, SessionTempRoot}` 拉起引擎子进程，结束后写 `result-<RequestId>.json`。Action 白名单：Analyze / Migrate / Cleanup / Restore。主窗口等不到确认就会断开管道（但 Worker 仍能读到断开前已写入管道的请求，2026-10-16 实测），所以"已接受"回复发送失败时 Worker 仍须等引擎结束、写出结果文件后再退出，否则主窗口只能报告"没有返回结果"。
- `migration-engine.ps1`：Analyze（预检）、Migrate（robocopy 复制 + 校验 + 源目录改名备份 + 建顶层 SymbolicLink + 删除备份）、Cleanup（删除改名前失败或已回滚遗留的目标副本）、Restore（把中断迁移的备份改回原路径）。后三者持有 `Global\mklinktool-engine` 互斥锁。
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
| `.cmd` / `.bat` | 纯 ASCII | cmd 无法解析 UTF-16；UTF-8 BOM 在部分 cmd 版本会破坏首行 `@echo off`。 |
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
- `[IO.Path]::GetFullPath`、`GetDirectoryName` 会抛 `PathTooLongException`；`GetPathRoot`/`GetFileName` 是纯字符串操作，安全。**仅在系统未启用 `LongPathsEnabled` 时如此**（Windows 默认未启用）；当前开发机启用了它，长路径不抛异常，相关分支在本机测试中不会被触发。
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
- .NET Framework 的递归删除遇错**会继续删除其余条目**，最后才抛出第一个异常：失败时目录往往已接近删空，提示文案不能写"备份仍保留"。`Remove-TreeSafely` 用 `[ref]$ModificationStarted` 区分"未作改动"与"可能已部分删除"。
- 计算哈希/校验时用 `FileShare::ReadWrite`，`FileShare::Read` 会因其他进程持有写句柄而炸。
- `GetFileSystemInfos()`/`FindFirstFile` 返回的大小与时间来自 NTFS 目录项，文件仍被写入时可能滞后（微软文档有说明）。快照要发现写入，所以对每个文件另建 `FileInfo` 重新读取，不要为省一次 stat 改用枚举结果。另外，文件仍被打开写入时，修改时间可能要到句柄关闭才更新：同一大小的原地改写在关闭前查不出来，这类情况只能靠“迁移前关闭应用”与目录改名失败来拦截。
- `GetFileSystemInfos()` 按名称通配匹配会把 `[` 当通配符；需要精确匹配时全量枚举后自行比较。
- PS 5.1 `Set-Content -PassThru` 返回的是字符串不是 FileInfo（写测试脚本时容易踩）。

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
- 判断提权引擎是否还在：`Get-Process -Id`（只列出仍在运行的进程，即使别处还持有句柄）+ 进程名 + 启动时间，必要时 `WaitForExit(0)`（只需 SYNCHRONIZE）。**不要读 `HasExited`**：.NET Framework 为它申请 `PROCESS_QUERY_INFORMATION`，会被完整性级别拒绝；而 PowerShell 又会把这个异常吞成 `$null`（见下一节），判断结果全凭碰巧。判断不了时按“仍在运行”处理。

**PowerShell 语言细节**：
- 中文弯引号 `“ ”` 在 PowerShell 中等同于双引号：写在双引号字符串里会提前截断字符串（解析报 Unexpected token）。含弯引号的文本用单引号字符串，配合 `-f` 格式化。
- 逗号运算符优先级高于 `+`：`@($a, '\\?\' + $b)` 会被解析成三个元素，要写成 `@($a, ('\\?\' + $b))`。
- 调用 .NET 方法时，PowerShell 会把 `$null` 转成空串传给 `string` 参数（实测 `[IO.File]::Replace($a, $b, $null)` 抛"路径格式非法"）；要传真正的 null 用 `[System.Management.Automation.Language.NullString]::Value`。
- `Join-Path` 会解析 PowerShell 驱动器：基路径是不存在的盘符（如 `Q:\`）时直接抛 `DriveNotFoundException`。处理用户输入的路径时用字符串拼接或 `[IO.Path]::Combine`。
- `-band` 等位运算的优先级低于比较运算：一律写成 `(($x -band $flag) -ne 0)`。
- **属性 getter 抛出的异常会被静默吞掉**：表达式里的 `$obj.Prop` 若 getter 抛异常，结果是 `$null`，既进不了 `catch`，也不记入 `$Error`（PS 5.1 实测，`Set-StrictMode -Version 2.0` 下相同）。所以 `try { $p.HasExited } catch {}` 永远捕获不到“拒绝访问”，`-not $p.HasExited` 反而得到 `$true`。需要拿到异常时调用方法形式 `$obj.get_Prop()`，或换用本身就是方法的 API。

## 工具链与测试心得

- 涉及符号链接/特权的测试要用真实文件系统状态（而非仅 API 返回值）做断言。早先记录的"沙箱内 flags 1 假成功"实为 P/Invoke 封送错误（见"符号链接"一节）。
- 复杂 PowerShell 测试一律写成 `.ps1` 文件用 `powershell.exe -File` 执行；内联 `-Command` 的多层引号转义几乎必炸。
- 含中文的测试脚本同样必须存成 UTF-8 带 BOM，否则 PS 5.1 按 GBK 解码，中文注释可能吞掉换行、破坏代码。典型症状是不报语法错误，注释下一行的语句却像没执行一样（变量为 `$null`）。文件写入工具通常写出无 BOM 的 UTF-8，写完记得转换。通过 Bash heredoc 生成文件时 `\\` 会被吞成 `\`（`\\?\` 前缀被破坏），这类内容改用文件写入工具或 PowerShell 写出。
- **测试必须跑在产品目标运行时上**：Windows PowerShell 5.1（powershell.exe）与 PowerShell 7（pwsh）在编码默认值、长路径、API 表面上行为不同；本项目目标是 PS 5.1。
- 非提权运行引擎做端到端测试时（开发者模式下顶层建链可成功），Robocopy `/SL` 无法创建**嵌套符号链接**（需要 `SeCreateSymbolicLinkPrivilege`），复制校验会报"嵌套链接数不一致"。嵌套链接用 Junction 测，嵌套符号链接需提权测试。
- **测试在 `tests/` 中**（2026-10-16 入库）：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-AllTests.ps1` 依次运行 `Test-Static.ps1`（所有 `.ps1` 语法与 BOM、`.cmd` 纯 ASCII）、`Test-Engine.ps1`（引擎端到端与故障注入）、`Test-Gui.ps1`（假 Worker）与 `Test-Gui.ps1 -Mode RealWorker`（真实 Worker 与引擎以普通权限运行），按各自的 `SUMMARY pass= fail=` 行汇总，有失败时退出码为 1，约 50 秒。加 `-IncludeElevated` 再跑 `Test-Gui.ps1 -Mode Elevated`：仓库里原样的 Worker 经 UAC 提权，需要有人点一次“是”。发起请求的进程不在前台时，UAC 提示可能不直接切到安全桌面，只在任务栏闪烁，要点开才出现；约 2 分钟无人响应会自动取消，测试随即失败、不做任何改动。共用函数在 `TestHelpers.ps1`（断言、摘要、安全删除测试目录）与 `gui\GuiHarness.ps1`。需要开发者模式（或管理员身份）与桌面会话；只在 `%TEMP%` 下的临时目录里工作并自行清理。改动三个脚本后都应跑一遍；新增行为同时补用例。实现方法如下：
  - 引擎：复制一份引擎，用"正则匹配唯一一行并插入或替换为测试代码"的方式注入故障，再以 `-File` 运行。覆盖：正常迁移（删除/保留备份）、N5 的三个写入时机、建链失败回滚与后续项 NotStarted、提交点后异常不回滚、备份删除中途失败与删除前枚举失败的提示、跨任务冲突写回各行、Cleanup（不跟随链接、三种拒绝情形）、Restore、引擎互斥锁。
  - 引擎辅助函数：用 `[Parser]::ParseFile` 取 AST，把 `Add-Type` 与所需函数的 `Extent.Text` 点调用进测试会话。
  - GUI：把 GUI 脚本副本末尾的 `[void]$form.ShowDialog()` 替换为点调用测试主体（在 GUI 作用域内运行），窗体移到屏幕外 `Show()`，伪造 state.json / engine.log / result 文件后调用 `Update-WorkerView`。注意：点调用脚本里的 `exit` 退出码传不出 `-File` 进程，按输出摘要判断成败；会弹 MessageBox 的函数需在测试主体里重定义为桩。
  - 轮询时序：在测试主体里重定义 `Refresh-Grid`（它位于一次轮询的中间），第一次调用时写入最终 state.json 与结果文件，即可确定性地复现“结束发生在两步之间”。
  - Worker 协议与跟踪模式：把 `Connect-ElevatedWorker` 重定义为空函数，测试主体自建 `NamedPipeServerStream`，另起一个 PowerShell 进程扮演 Worker（读请求后按模式：正常接受 / 不回复但照样写结果 / 回复 Error / 直接退出 / 留下仍在运行的“引擎”后退出），把它的 `Process` 对象赋给 `$script:Worker`。`$script:RecoveryJournalRoot` 指到临时目录，避免写入真实的中断恢复记录。
  - 完整性级别的模拟：非提权测试里，用 `SetSecurityInfo` 给替身进程加拒绝 `PROCESS_QUERY_INFORMATION`（0x400）与 `SYNCHRONIZE`（0x100000）的 ACE，即可重现主窗口访问提权引擎时拿不到的权限。
  - 会话目录清理：测试主体先保存 `${function:Remove-StaleSessionDirectories}` 再把它换成桩（窗口显示时会调用它，不能让测试清理真实的 `%TEMP%`），然后对临时根目录调用保存的原函数。
  - 真实 Worker（`gui\WorkerTests.Body.ps1`）：不桩 `Connect-ElevatedWorker`，走真实的管道、PID 校验、握手与引擎。普通权限模式由启动器复制一份去掉提权检查的 Worker（与引擎放在同一目录），并去掉 GUI 副本里的 `-Verb RunAs`；提权模式用仓库原样的 Worker，并把副本里等待连接的 30 秒放宽到 120 秒。让来源改名失败的做法：用 `FileShare.Read`（不含 Delete）打开来源里的一个文件，目录改名会报“访问被拒绝”，但文件仍能被 Robocopy 读取复制。模拟确认丢失：把 `$script:WorkerReadTimeoutMs` 设为 1。
- 修改三个脚本后最低限度回归：`tests\Test-Static.ps1`（语法 + BOM）；能跑全套时跑 `tests\Invoke-AllTests.ps1`。

## 已知边界

- 引擎仅支持顶层 SymbolicLink（Junction 只作为来源内部的嵌套链接由 robocopy 保留）。
- 相对路径、盘符根目录在预检/添加阶段即被明确拒绝。
- 非提权 GUI 无法终止任何提权 Worker/引擎（taskkill 会失败并提示等待其自行退出）；请求已发出但确认丢失时进入跟踪模式，等任务确实结束才解锁；引擎互斥锁保证不会出现第二个并发的迁移引擎。
- 写入检测（N5）覆盖“复制后、校验快照前”与“校验后、提交前”两个窗口；检测不到的是：在改名后仍持有句柄（以 FILE_SHARE_DELETE 打开）的应用在复核之后的写入，以及修改时间推迟到句柄关闭才更新的同大小原地改写。
- 目标卷为 FAT32 时不比较修改时间（以本地时间保存，跨夏令时会差整小时），exFAT 允许 2 秒误差，NTFS/ReFS 精确比较。
- 工具不复制源目录 ACL，目标副本继承目标位置权限；预检只提示、不阻断。
