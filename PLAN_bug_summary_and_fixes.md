# mklinktool 问题总结与修复计划

日期：2026-10-12
范围：`migrate-local-folders.ps1`（GUI）、`migration-worker.ps1`（提权 Worker）、`migration-engine.ps1`（迁移引擎）、`migrate-local-folders.cmd`（启动器）
性质：静态审查 + 定向实测；**本阶段未改动任何代码**。

---

## 1. 验证方法

- 三个 `.ps1` 均通过 `[System.Management.Automation.Language.Parser]::ParseFile()`（0 语法错误），文件头为 UTF-8 BOM，`.cmd` 纯 ASCII——符合 AGENTS.md 编码约定。
- 对存在争议的结论做了定向实测（Windows PowerShell 5.1 / .NET Framework，涉及重解析点的用例按 AGENTS.md 要求脱离沙箱运行）：
  - 只读子目录 / 只读 Junction 对 `Directory.Delete` 的影响；
  - `GetLongPathNameW` 对不存在末段路径的返回语义；
  - `DataGridView` CellMouseDown 事件坐标的参照系（用可公开调用 `OnMouseDown` 的子类注入合成鼠标事件实测）；
  - `CreateSymbolicLinkW` flags 3 / 1 的真实返回与错误码。
- 实测中还复现了 AGENTS.md 记载的“flags=1 假成功”（返回 TRUE 但未创建链接），确认引擎的建链后存在性验证（`migration-engine.ps1` L770-772、L236）是必要兜底，不要移除。

---

## 2. 对第三方 AI 结论（10 条）的逐条核实

| # | 结论 | 判定 | 依据 |
|---|---|---|---|
| 1 | 只读子目录/只读链接导致备份删除失败抛错 | **成立（实测确认）** | 实测：只读子目录使 `Directory.Delete($p,$true)` 抛 `UnauthorizedAccessException`；只读 Junction 连单体 `Directory.Delete` 也拒绝（"Access to the path ... is denied"）。现有代码只清普通文件的 ReadOnly（`migration-engine.ps1` L395-398），目录与链接均未处理。影响描述基本准确，见 F1。 |
| 2 | 长路径回滚 `Get-Item` 必然失败 | **成立** | 与独立分析一致。`Get-Item -LiteralPath` 不支持 >260 字符路径（AGENTS.md 明示），`-ErrorAction SilentlyContinue` 使其静默变 `$null` → 误抛“源路径已被其他对象占用” → `RecoveryRequired`（`migration-engine.ps1` L806-812）。同函数内 `Remove-VerifiedLink` 已用长路径安全 API，前后不一致。 |
| 3 | 8.3 短名导致 UI 状态永久卡死 | **成立** | 与独立分析一致。引擎 `ConvertTo-FullPath` 展开 8.3 后写入 state.json（L123-125），UI `Get-PathCompareKey` 不展开（`migrate-local-folders.ps1` L64-68），`Update-WorkerView` 双键匹配（L598-609）恒失败。同一根因还波及手改目标含 `.`/`..` 的情形（UI 故意不做 GetFullPath，L960-963）。 |
| 4 | 未创建的目标路径无法展开父级短名，绕过包含性检查 | **成立（前提实测确认）** | 实测 `GetLongPathNameW` 对不存在末段返回 `ret=0, err=2`（ERROR_FILE_NOT_FOUND），`Expand-ShortNamesWithLongPath` 随即原样返回（L97-103）。而引擎规定目标路径必须**不存在**，故目标上的短名永远无法展开 → `Test-PathContains`（L129-136）的字符串包含比较可被 `D:\DATA~1\new` 这类别名绕过，安全互斥检查失效。 |
| 5 | flags 回退条件过窄，1314 不会回退到 flags=1 | **部分成立（防御性加固项）** | 代码脆弱点属实：`if ($lastError -ne 87) { throw }`（L215-223）对 1314 等错误码不回退。但“以管理员运行仍失败”未获证实——提权调用者持有 `SeCreateSymbolicLinkPrivilege` 时 flag 2 不构成限制；本机（开发者模式开启）实测 flags=3 直接成功。结论：放宽回退条件是廉价加固，但当前不构成提权 Worker 场景的现实故障；另实测 flags=1 可能“假成功”，需保留建链后存在性验证。 |
| 6 | CellMouseDown 坐标是单元格相对坐标，右键菜单弹在左上角 | **成立（实测确认）** | 实测：控制坐标 (102,36)、单元格原点 (42,24) 时，事件 `e.X/e.Y = (60,12)`，恰为单元格相对偏移。`$pathContextMenu.Show($grid, Point($e.X, $e.Y))`（`migrate-local-folders.ps1` L952）会把偏移量当控件客户区坐标，菜单固定弹在表格左上部。 |
| 7 | Worker 异常后切断管道且不写结果文件 | **成立** | 与独立分析一致（`migration-worker.ps1` L198-206：有引擎进程时直接 `break`，不发 Error、不写 `result-<RequestId>.json`）。 |
| 8 | `File.ReadAllText` 读日志缺共享写标志 | **成立，但影响方向需更正** | 共享冲突属实，但失败方是**引擎**：GUI 读句柄为 `FileShare.Read`，引擎 `File.AppendAllText`（写打开）被拒（实测复现）。GUI 读取侧反而不会失败（引擎句柄允许读共享）。因此影响不是“UI 日志跳帧”，而是引擎 `Write-Log` 抛 `IOException` 被 `Invoke-Migration` 的任务级 catch 当作任务失败 → **可能触发误回滚**（详见 F6）。 |
| 9 | 日志双重换行导致空行堆积 | **成立** | 引擎 `Write-Log` 已带换行（`migration-engine.ps1` L55），UI 又 `AppendText($delta + NewLine)`（`migrate-local-folders.ps1` L571）。纯外观问题。 |
| 10 | Start-Worker 异常后 UI 状态未复位 | **部分成立** | 任务状态残留“等待扫描”属实（L979-994 catch 未复位）；但“未复位 PlanValid”不应算缺陷——启动失败时保留 PlanValid 以允许直接重试是合理行为，复位反而强迫用户重跑预检。 |

---

## 3. 合并问题清单（含本次新增发现）

严重度定义：**高** = 数据恢复/安全边界/并发损坏风险；**中** = 功能失败或状态失步但有兜底；**低** = 外观与状态卫生。

| 编号 | 问题 | 严重度 | 来源 |
|---|---|---|---|
| F1 | 备份清理不处理只读目录/只读链接 → 删除必失败；失败后提示误导（部分删除仍称“备份保留”） | 高 | 外部#1 + 本次 |
| F2 | 长路径回滚用 `Get-Item` → 误报占用，自动回滚降级人工恢复 | 高 | 外部#2 |
| F3 | UI/引擎路径形态失配（8.3、`.`/`..`）→ 表格状态、警告、错误永久失步 | 高 | 外部#3 |
| F4 | 目标路径短名无法展开 → `Test-PathContains` 互斥检查可被绕过 | 高 | 外部#4 |
| F5 | 请求已发出但确认消息丢失时 `ActiveJob` 未置位 → 可并发启动第二次迁移 | 高 | 本次新增 |
| F6 | 日志共享冲突使引擎 `Write-Log` 抛错 → 任务误判失败/误回滚 | 中 | 外部#8（影响更正）|
| F7 | job.json 提权读取存在 TOCTOU；工具脚本目录可写即等于提权执行面 | 中 | 本次新增 |
| F8 | `CreateSymbolicLinkW` 回退条件过窄（仅认 87）；flags=1 “假成功”依赖调用方验证 | 中 | 外部#5（部分成立）|
| F9 | 右键菜单坐标为单元格相对 → 菜单固定弹在表格左上角 | 低 | 外部#6 |
| F10 | Worker 异常退出不写 result、不发 Error → GUI 只能猜测退出码 | 低 | 外部#7 |
| F11 | 日志文本框双换行空行堆积 | 低 | 外部#9 |
| F12 | Start-Worker 失败后状态残留“等待扫描”；迁移中途中止后未处理任务仍显示 Ready | 低 | 外部#10（部分成立）+ 本次 |
| F13 | `ExitCode` 为 null 时 `[int]$null = 0` → 误判成功 | 低 | 本次新增 |
| F14 | 引擎存活判定（`Get-Process`/`StartTime`）异常被吞 → 误解锁 UI | 低 | 本次新增 |
| F15 | 来源去重只比对字符串 → 同一目录的短名/长名两种写法可重复添加 | 低 | 本次新增 |

**已知边界（不列为缺陷）**：来源内含文件符号链接或云占位等非目录重解析点时预检直接报错（保守拒绝，建议在 README 写明）；盘符根与相对路径在添加/预检阶段拒绝；GUI 非提权无法强杀另一管理员账号的提权 Worker（AGENTS.md 已记载）。

---

## 4. 逐项修复方案与回归点

### F1 备份清理对只读目录/链接失败（高）
- **位置**：`migration-engine.ps1` `Remove-BackupTreeSafely`（L375-414）。
- **修复**：BFS 遍历时对**目录、链接、文件**统一清 `ReadOnly`（含备份根本身）；链接删除前同样清属性。L395 的注释“只有只读文件会阻断递归删除”与实测不符，需更正。失败提示区分两种状态：备份完整保留 vs 备份已部分清理（当前 L789 一律称“备份仍保留”，与实际不符）。
- **回归**：构造来源含只读子目录、只读 Junction、只读文件、desktop.ini 自定义图标文件夹；`DeleteBackup=true` 跑通并确认备份被删净；再人为制造中途失败，确认提示文案与实际残留一致。

### F2 长路径回滚误报（高）
- **位置**：`migration-engine.ps1` L807。
- **修复**：用 `[System.IO.DirectoryInfo]::new((Get-ExtendedLengthPath $source))` 读 `LinkType`/`Target`，与 `Remove-VerifiedLink` 同一 API 体系；删除 `Get-Item` 调用。
- **回归**：>260 字符来源，按 AGENTS.md 的“建链调用替换为 throw”注入法强制失败（以及“假成功但未建链”分支）→ 期望 `RolledBack` 而非 `RecoveryRequired`，源目录完整恢复。

### F3 路径形态失配导致 UI 失步（高）
- **位置**：`migrate-local-folders.ps1` `Get-PathCompareKey`（L64-68）、`Update-WorkerView`（L598-609）、`CellEndEdit`（L955-968）。
- **修复**：匹配前对两侧施加与引擎一致的规范化（`GetFullPath` + 8.3 展开）。最小改法：UI 侧复制引擎的 `ConvertTo-FullPath`/`Expand-ShortNamesWithLongPath` 逻辑（P/Invoke `GetLongPathNameW`），仅用于比较键，不改变用户输入的显示值。注意引擎写 state.json 的形态是权威值，匹配键必须与其一致。
- **回归**：来源用 `C:\PROGRA~1\...` 形式、目标手改含 `.\`、`..\` 段——预检后状态、文件数、警告/错误图标正常同步；正常路径（无短名）不回归。

### F4 短名绕过互斥检查（高）
- **位置**：`migration-engine.ps1` `Expand-ShortNamesWithLongPath`（L88-105）、`Test-PathContains`（L129-136）。
- **修复**：对不存在的路径，向上找到**最长存在的祖先目录**，用 `GetLongPathNameW` 展开该祖先后拼回不存在的尾段；展开动作放在 `ConvertTo-FullPath` 的 `~[0-9]` 分支内，保证所有包含性比较都在展开后的形态上进行。
- **回归**：目标 `D:\DATA~1\new`（等价于来源长名所在树内）+ 来源长名——预检必须报“来源与目标互相包含”；备份与目标、目标与目标的互斥检查同样覆盖；同时验证 F3 的匹配在短名目标下恢复正常。

### F5 确认丢失后的并发迁移窗口（高）
- **位置**：`migrate-local-folders.ps1` `Start-Worker`（L499-L563）、`Read-WorkerMessage`（L275-296）、`Complete-WorkerAction`。
- **修复**：`$requestSent = $true` 之后的任何异常都必须进入“任务可能已在运行”的收尾：置 `ActiveJob`/忙碌态（或至少禁用开始、添加、移除按钮），轮询 `result-*.json` 与引擎 PID 存活，确认无引擎后才解锁。`Stop-WorkerProcess` 杀不掉提权 Worker 时的提示要明确“引擎可能仍在运行，请勿再次开始迁移”。
- **回归**：把 `WorkerReadTimeoutMs` 调小并注入握手超时/断管，确认 UI 不出现可再次点击“开始迁移”的状态；再验证引擎实际结束后 UI 自动解锁。

### F6 日志共享冲突（中）
- **位置**：`migrate-local-folders.ps1` L566-577；`migration-engine.ps1` `Write-Log`（L53-57）。
- **修复**（双管齐下，重点是第二条）：
  1. UI 读日志改用 `FileStream(Open, Read, FileShare.ReadWrite -bor Delete)`（与 state.json 的读法一致）；
  2. 引擎 `Write-Log` 失败**不应升级为任务失败**：捕获 `IOException` 做有限重试，仍失败则丢弃该条日志并记入 `Warnings`，绝不让日志问题触发回滚。
- **回归**：脚本并发“循环读 + 循环写”engine.log 压测不抛错；人为让日志目录写失败，确认迁移照常完成且状态有警告。

### F7 job.json TOCTOU 与脚本目录信任（中，安全）
- **位置**：`migration-worker.ps1` L147-159；`migration-engine.ps1` L848-859。
- **修复**：Worker 校验 job.json 后计算 SHA-256 并随 Execute 参数传给引擎；引擎读取前复核非重解析点 + 大小 + 哈希，不一致即拒绝。文档明确：工具目录与三个脚本必须仅管理员可写（否则提权执行面等于对所有本地用户开放）。
- **回归**：在校验与读取之间改写 job.json（测试钩子注入）→ 引擎拒绝执行并写明原因。

### F8 建链回退条件（中）
- **位置**：`migration-engine.ps1` L215-224。
- **修复**：错误码 87/1314/5 均继续尝试 flags=1；保留现有“建链后验证路径真实存在”（L770-772、L236）作为 flags=1 假成功的兜底，探针与真实建链继续共用同一函数。
- **回归**：现有“探针与建链同 API”用例不回归；在无开发者模式的 Windows 10/11 与 Windows Server 各验证一次（提权与开发者模式两种启动方式）。

### F9 右键菜单位置（低）
- **位置**：`migrate-local-folders.ps1` L952。
- **修复**：`$pathContextMenu.Show([System.Windows.Forms.Cursor]::Position)`（或 `$grid.PointToScreen(Point($e.X, $e.Y))`，但需自行换算单元格偏移，故推荐光标位置）。
- **回归**：GUI 冒烟——右键任意行的来源/目标单元格，菜单出现在光标处。

### F10 Worker 静默退出（低）
- **位置**：`migration-worker.ps1` L198-206。
- **修复**：catch 分支即使有引擎进程在跑，也先尽力写 `result-<RequestId>.json`（`ExitCode=$null` + `ErrorMessage` 字段）并尝试发 `Error` 消息，再退出；`break` 前不要吞掉具体异常文本。
- **回归**：注入结果写入失败路径，确认 result 文件含错误文本，GUI 能显示具体原因（配合 F13）。

### F11 日志空行（低）
- **位置**：`migrate-local-folders.ps1` L571。
- **修复**：`AppendText($delta.TrimEnd("`r","`n") + [Environment]::NewLine)`（或不补换行，取决于显示偏好）。
- **回归**：GUI 冒烟——运行日志行距正常。

### F12 状态卫生（低）
- **位置**：`migrate-local-folders.ps1` L979-994、L1023-1027；`migration-engine.ps1` L838。
- **修复**：`Start-Worker` catch 中把任务状态从“等待扫描”复位为“待预检”（或保留旧值）；迁移中途 `return $false` 后，把未处理任务显式标为“未执行”而不是残留 Ready。**不要**复位 `PlanValid`（允许重试）。
- **回归**：取消 UAC 后表格状态与提示一致；注入迁移中途失败，确认后续任务状态为“未执行”。

### F13 ExitCode null 误判成功（低）
- **位置**：`migrate-local-folders.ps1` L622。
- **修复**：`$exitCode = if ($null -eq $result.ExitCode) { 1 } else { [int]$result.ExitCode }`，配合 F10 的 `ErrorMessage` 显示。
- **回归**：构造 result 中 `ExitCode:null` 的情形 → 显示“未完成/失败”而非“迁移完成”。

### F14 引擎存活判定（低）
- **位置**：`migrate-local-folders.ps1` L628-L648。
- **修复**：`Get-Process`/`StartTime` 失败时保守处理——视为“可能仍在运行”，保持锁定并提示用户确认；只有明确判定引擎已结束才解锁。
- **回归**：跨管理员账号（OTS）场景下 Worker 意外退出，确认 UI 不会在引擎仍在跑时解锁。

### F15 来源去重（低）
- **位置**：`migrate-local-folders.ps1` L180-L190。
- **修复**：去重比较与 F3 使用同一规范化比较键。
- **回归**：同一目录以短名、长名、末尾反斜杠三种写法添加 → 只入列一次。

---

## 5. 修复顺序建议

1. **批次 1（数据安全与安全边界）**：F1 → F2 → F4 → F3。F1/F2 直接影响备份删除与回滚可靠性；F4 是安全检查绕过；F3 与 F4 共享“统一路径规范化”基础设施，一起做省工。
2. **批次 2（健壮性）**：F5 → F6 → F7 → F8。F5 防并发损坏，F6 防误回滚，二者建议同批。
3. **批次 3（体验与状态卫生）**：F9–F15，均为小改，可一次提交。

每批完成后按第 6 节回归，不要跨批累积后一次性验证。

---

## 6. 回归验证清单

**最低限度（每次改动三个脚本后必跑，AGENTS.md 约定）**
- `[System.Management.Automation.Language.Parser]::ParseFile()` 三个文件 0 语法错误；
- 文件头 BOM 检查：`.ps1` = UTF-8 BOM，`.cmd` 纯 ASCII。

**必须在产品目标运行时（Windows PowerShell 5.1）执行**，涉及符号链接/特权的用例脱离沙箱，并以真实文件系统状态（而非仅 API 返回值）断言。

**复跑现有验证套件**：Worker 会话校验两分支；长路径/8.3/`..` 防绕过；写锁文件哈希；端到端 Analyze + Migrate（嵌套 Junction + 8.3 目标 + 只读文件 + SHA-256 + >260 来源）；强制失败回滚链路（RolledBack + Errors 可见 + 源目录完整恢复）；GUI 启动冒烟。

**本次新增用例**（对应修复项）：
- 只读目录树/只读 Junction 的备份删除（F1）；
- >260 字符来源的建链失败回滚（F2）；
- 短名来源与短名目标的状态同步、互斥检查（F3、F4）；
- 握手超时后 UI 不可再次开始迁移（F5）；
- 日志并发读写压测、日志写失败不影响迁移结果（F6）；
- job.json 篡改检测（F7）；
- 右键菜单位置、日志空行、状态复位等 GUI 冒烟项（F9–F12）。

---

## 7. 附：实测记录摘要（2026-10-12，Windows PowerShell 5.1）

| 用例 | 结果 |
|---|---|
| 只读子目录 + `Directory.Delete($p,$true)` | 抛 `UnauthorizedAccessException`（确认 F1） |
| 只读 Junction + `Directory.Delete`（单体/递归） | 均抛 `UnauthorizedAccessException`（确认 F1） |
| 只读文件 + 递归删除 | 抛错（证明现有清文件只读的代码必要，保留） |
| `GetLongPathNameW` 不存在末段（含短名父级下） | `ret=0, err=2`，原样返回未展开路径（确认 F4 前提） |
| `GetLongPathNameW` 存在路径 | 正常展开（引擎来源侧逻辑有效） |
| `DataGridView.CellMouseDown` 坐标 | 控制坐标 (102,36)、单元格原点 (42,24) → 事件值 (60,12)，单元格相对（确认 F9） |
| `CreateSymbolicLinkW` flags=3（非提权，开发者模式开） | 成功并真实建链 |
| `CreateSymbolicLinkW` flags=1（非提权） | 返回 TRUE 但**未创建**（AGENTS.md 的“假成功”，确认 F8 兜底必要） |
| `File.ReadAllText` 句柄存在时 `File.AppendAllText` | 抛共享冲突异常（确认 F6，失败方为写入侧） |
