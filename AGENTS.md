# agents.md — mklinktool 开发与踩坑笔记

本文件面向后续维护者与 AI 代理，记录本项目特有的约定、Windows PowerShell 5.1 陷阱与实际踩过的坑。改动前请先阅读。

## 项目架构速览

- `migrate-local-folders.ps1`：GUI（WinForms，STA，非提权）。命名管道服务端，轮询 `state.json` 刷新界面。
- `migration-worker.ps1`：经 UAC 启动的提权 Worker。校验父进程 PID 后连接命名管道，按 `Execute{RequestId, Action, SessionPath, SessionTempRoot}` 拉起引擎子进程，结束后写 `result-<RequestId>.json`。
- `migration-engine.ps1`：实际执行预检（robocopy 复制 + 校验 + 源目录改名备份 + 建顶层 SymbolicLink）。
- 会话目录：`%TEMP%\mklinktool-<guid>\`（job.json / state.json / engine.log / robocopy.log）。
- 安全模型：管道名含 128 位 GUID；GUI 校验 client PID、Worker 校验 server PID；管道 ACL 授予当前用户 + `BUILTIN\Administrators`（后者是为了"另一个管理员账号"OTS 提权场景）。
- UI 与引擎之间唯一的进度通道是 `state.json`（引擎 tmp+Replace 原子写，UI 每 500ms 轮询）。

## 文件编码规则（重要）

**历史由来（已核实，见 operation-notes.md）**：早期脚本曾被较新的 PowerShell 以无 BOM 的 UTF-8 写出，而 Windows PowerShell 5.1 把无 BOM 文件按本机 ANSI（中文系统 = GBK）解码，中文乱码并破坏解析——当时的修复是把 .ps1 存成 UTF-16LE 带 BOM。所以 **UTF-16LE 是为了 PowerShell，与 cmd 无关**；cmd 恰恰相反，批处理绝不能是 UTF-16。

**现行约定**：

| 文件类型 | 编码 | 原因 |
|---|---|---|
| `.ps1` | UTF-8 **带 BOM** | PS 5.1 尊重 BOM 正确解码中文；PowerShell 7 默认 UTF-8；grep/diff/常见工具链友好。UTF-16LE 虽然也能被 PS 5.1 识别，但会让文本工具看到 NUL 字节、体积翻倍（2026-10 的编码损坏事故即因此难以排查）。 |
| `.cmd` / `.bat` | 纯 ASCII | cmd 无法解析 UTF-16；UTF-8 BOM 在部分 cmd 版本会破坏首行 `@echo off`。 |
| 数据文件（job.json / state.json / engine.log） | UTF-8 无 BOM，**读写两侧都必须显式指定编码** | GUI 写入用 `UTF8Encoding($false)`；引擎/ GUI 读取必须带 `-Encoding UTF8` 或 `Encoding.UTF8`，否则 PS 5.1 默认按 ANSI 解码。 |
| robocopy.log | **绝不预写** | 由 `/UNILOG+` 独占创建/追加，编码随 robocopy 版本而定（新版本实测为单字节/UTF-8，旧版本为 UTF-16 LE）。预写其他编码会造成编码混合。 |

**编码事故取证技巧**（2026-10 实战）：
- 症状：脚本报大量语法错误、`git diff` 显示二进制、行数虚增。先看文件头字节：`FF FE` = UTF-16LE BOM；`EF BB BF` = UTF-8 BOM；`FF FE FD FF FD FF` 开头 + 每字符 4 字节 = 双重编码损坏（UTF-16LE 字节流被误当 UTF-8 解码后又存回 UTF-16LE）。
- 体积指纹：UTF-16LE 文件字节数 ≈ 2×字符数，UTF-32 式 ≈ 4×。git blob 大小（`git cat-file -s`）可无损对比 HEAD 与工作区。
- 把非 ASCII 连续段折叠成单个 `?` 再 diff，可快速判断损坏文件里是否还有独有代码（本次结论：没有，ASCII 代码行全部完好，可放心 `git checkout` 恢复）。
- 中文区乱码会散落真实的 CR/LF 字符（如 U+4E0A 的 UTF-16LE 字节 `0A 4E`），导致行数虚增——行数差不代表内容差异。

## Windows PowerShell 5.1 / .NET Framework 陷阱

**长路径（>260 字符）**：
- `[IO.Path]::GetFullPath`、`GetDirectoryName` 会抛 `PathTooLongException`；`GetPathRoot`/`GetFileName` 是纯字符串操作，安全。
- 设备路径（`\\?\C:\...`、UNC 用 `\\?\UNC\`）跳过长度检查，且 .NET Fx 对其原样返回不做归并——`\\?\` 路径必须用反斜杠。
- PS 5.1 cmdlet（`Get-Item`/`Rename-Item`/`New-Item`/`Get-ChildItem`）不支持长路径；用 .NET + `\\?\` 替代：改名用 `[IO.Directory]::Move`，枚举用 `[IO.Directory]::EnumerateFileSystemEntries`。
- robocopy 自身支持长路径，保持传普通路径（不要加 `\\?\`）。
- 注意方法归属：`EnumerateFileSystemInfos` 是 `DirectoryInfo` 的实例方法，`[IO.Directory]` 上只有 `EnumerateFileSystemEntries`（返回字符串）——想当然会编译期不报错、运行期才炸。
- 超长路径无法归并 `..` 段时必须 fail-closed 拒绝，否则路径包含检查可被字符串把戏绕过。

**符号链接**：
- PS 5.1 的 `New-Item -ItemType SymbolicLink` 走旧 API，需要 `SeCreateSymbolicLinkPrivilege`，且不支持长路径。用 P/Invoke `CreateSymbolicLinkW`：先传 flags 3（DIRECTORY 1 | ALLOW_UNPRIVILEGED_CREATE 2，开发者模式无需特权），错误码 87（旧系统不认识 flag 2）再回退 flags 1。
- **必须在建链后验证路径真实存在**：某些安全策略会让 flags 1 "返回 TRUE 但什么都没创建"。
- 预检探针必须与真实建链用同一 API 与参数，否则产生假阴性/假阳性。
- `LinkType`/`Target` 是 PowerShell 扩展类型数据（不是 .NET Fx 原生属性），但**直接 `[System.IO.DirectoryInfo]::new()` 的实例同样可用**，且 `Target` 返回的是去掉 `\\?\` 前缀的形态。

**文件系统**：
- `[IO.Directory]::Delete($path, $true)` 遇只读文件抛 `UnauthorizedAccessException`——先清 `ReadOnly` 属性再删。
- 计算哈希/校验时用 `FileShare::ReadWrite`，`FileShare::Read` 会因其他进程持有写句柄而炸。
- `GetFileSystemInfos()` 按名称通配匹配会把 `[` 当通配符；需要精确匹配时全量枚举后自行比较。
- PS 5.1 `Set-Content -PassThru` 返回的是字符串不是 FileInfo（写测试脚本时容易踩）。

**GUI（WinForms）**：
- `RowHeadersVisible=$false` 时行级 `ErrorText` 图标不可见，错误提示必须挂在单元格（如 Status 列）上。
- DataGridView 开双缓冲需反射：`GetProperty('DoubleBuffered', 'Instance,NonPublic').SetValue($grid, $true, $null)`。
- 若表格行与外部列表严格按序 1:1 对应，必须把所有列设 `SortMode='NotSortable'`，否则用户点表头排序即错位。
- 就地刷新时 `ErrorText`/`ToolTipText` 要无条件赋值（含空串），否则旧错误残留。
- 命名管道 ACL：OTS 提权 Worker 的用户 SID 与主窗口不同，但其令牌组含已启用的 `BUILTIN\Administrators`（SID `S-1-5-32-544`，用 SecurityIdentifier 构造避免本地化名称问题）。杀提权进程树用 `taskkill /PID <pid> /T /F`，普通 `Process.Kill()` 会留下孤儿引擎。

## 工具链与测试心得

- **沙箱会扭曲文件系统语义**：本次实测沙箱内 `CreateSymbolicLinkW(flags 3)` 被拒（err 87）、flags 1 假成功；涉及符号链接/特权的测试必须脱离沙箱跑，且用真实文件系统状态（而非仅 API 返回值）做断言。
- 复杂 PowerShell 测试一律写成 `.ps1` 文件用 `powershell.exe -File` 执行；内联 `-Command` 的多层引号转义几乎必炸。
- **测试必须跑在产品目标运行时上**：Windows PowerShell 5.1（powershell.exe）与 PowerShell 7（pwsh）在编码默认值、长路径、API 表面上行为不同；本项目目标是 PS 5.1。
- 验证套件覆盖（可复跑）：Worker 会话校验两分支、长路径/8.3/`..` 防绕过、写锁文件哈希、端到端 Analyze+Migrate（嵌套 Junction + 8.3 目标 + 只读文件 + SHA-256 + >260 来源）、强制失败的回滚链路（RolledBack + Errors 可见 + 源目录完整恢复）、GUI 启动冒烟。
- 回滚链路的确定性测试方法：把引擎副本中的建链调用替换为 `throw` 后以 Migrate 运行——能完整覆盖"备份已改名→回滚改名→状态与错误记录"路径，无需真实制造提权失败。
- 修改三个脚本后最低限度回归：`[System.Management.Automation.Language.Parser]::ParseFile()` 三个文件 0 语法错误 + 文件头 BOM 检查。

## 已知边界

- 引擎仅支持顶层 SymbolicLink（Junction 只作为来源内部的嵌套链接由 robocopy 保留）。
- 相对路径、盘符根目录在预检/添加阶段即被明确拒绝。
- GUI 非提权时无法强杀另一管理员账号的提权 Worker（taskkill 会失败并提示等待其自行退出）。
