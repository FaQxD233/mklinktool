# 迁移时保留内部 Junction 计划

## 目标

允许迁移来源目录中指向该来源内部位置的目录 Junction，以及内部目录 SymbolicLink。复制时保留链接本身，不展开它指向的内容；预检将其作为警告展示。迁移完成后，原来源根仍是 `SymbolicLink`，嵌套链接保留原类型。

## 调研结论

- `migration-engine.ps1` 的 `Get-TreeSnapshot` 已经使用 `Queue[DirectoryInfo]` 手动扫描普通目录，不依赖 `Get-ChildItem -Recurse`；目前遇到任何嵌套重解析点都会报错。后续保留该非穿透遍历方式并扩展链接清单。
- Robocopy 使用 `/XJ` 排除 Junction。
- 内容校验当前只比较普通文件相对路径、文件数、总字节数和可选 SHA-256。
- 成功建链后，备份通过 `Remove-Item -Recurse -Force` 清理；在支持嵌套 Junction/SymbolicLink 后，清理流程必须显式先移除链接指针，再清除普通目录树。
- `State.Warnings` 已存在，但预检没有使用；WinForms 网格当前展示来源、目标、文件数、大小和状态。
- Robocopy 的 `/SJ` 用于复制 Junction 本身；`/SL` 用于复制 SymbolicLink 本身；`/XJ` 会排除 Junction，不能与“保留 Junction”目标同时使用。

## 范围与安全边界

- 来源根目录只要是重解析点，仍然作为错误拦截。
- 只放行嵌套目录 Junction 与目录 SymbolicLink。绝对目标必须位于来源根目录内；相对 SymbolicLink 目标先以链接所在目录为基准解析，再要求解析结果位于来源根目录内。外部/损坏链接、文件链接及无法识别的重解析点仍报错，不自动忽略。
- 沿用 `Get-TreeSnapshot` 中的队列遍历：遇到重解析点时分类、校验并记录，绝不把它加入待遍历队列；只将普通目录加入队列。这样不会读取链接目标的内容。
- Robocopy 使用 `/SJ /SL` 并移除 `/XJ`。`/SJ` 与 `/SL` 分别复制 Junction 与 SymbolicLink 本身；若扫描后出现未支持链接，复制后快照仍会拒绝它。
- 普通文件清单校验之外，比较来源与目标的嵌套链接相对路径、类型和链接目标。顶层 `SymbolicLink` 创建后，再验证嵌套链接能经来源路径访问目标树内的对应目录。
- 删除备份采用两阶段流程：先用同样的非穿透队列扫描收集所有重解析点，并逐个用单项删除移除链接本身；确认不存在重解析点后，再递归删除剩余普通树。任何一步失败均保留备份并报告确切路径。
- 明确记录绝对内部链接依赖原来源路径持续保留为顶层 SymbolicLink：若该根链接被移除，目标树中的绝对链接会失效；相对链接在目标树内按原相对结构解析。

## 实施步骤

1. 扩展引擎快照：识别并分类内部目录 Junction 与目录 SymbolicLink，保存链接相对路径、类型、原始目标及解析目标；对不在允许范围内的重解析点保留清晰错误信息。
2. 扩展快照比较与分析状态：比较链接清单，返回 Junction/SymbolicLink 数量和警告；把预检警告写入状态与日志。
3. 调整 Robocopy 参数为 `/SJ /SL`，保留现有有限重试与普通文件复制参数。
4. 在顶层 SymbolicLink 创建后验证链接类型、目标、目录访问及嵌套链接清单/可访问性；若失败，移除本次创建的根链接并通过同级改名恢复源目录。
5. 将备份删除改为“先逐项解除重解析点，再递归删除普通树”；保留备份选项和删除失败提示保持有效。
6. 更新 WinForms：分别显示每项内部 Junction/SymbolicLink 数量；预检日志和开始迁移确认框说明链接会保留原类型，且不会复制链接目标的重复内容；提示绝对内部链接依赖顶层根链接。
7. 更新 README 与 DESIGN 的支持范围、警告行为、Robocopy 参数、校验/回滚流程和绝对链接依赖限制。

## 验收与隔离验证

只在工作区内新建的专用临时目录验证，不接触 Starward、Steam、bililive、cherrystudio-updater 或此前已迁移目录。

- 普通目录迁移行为和现有文件校验不回归。
- 带空格路径下，内部 Junction 和相对目录 SymbolicLink 均按原类型复制；目标数据不会因展开链接而重复复制。
- 内部绝对目录 SymbolicLink/Junction 与相对目录 SymbolicLink 按目标边界规则通过预检；外部或损坏链接拒绝。
- 外层来源路径切换为 SymbolicLink 后，嵌套链接仍可访问预期目标目录；移除测试根链接时确认绝对内部链接变为不可用这一限制被文档说明。
- 两阶段清理只移除测试链接对象，不删除其指向目录中的哨兵文件。
- 来源根重解析点、外部/损坏链接、文件链接、无法识别的重解析点仍被预检拦截。
- 注入建链/验链失败时，根链接按目标匹配后移除，源备份同盘改名恢复，目标副本保留。
- GUI 预检、警告数量和确认提示与引擎结果一致。

## 影响文件

- `migration-engine.ps1`
- `migrate-local-folders.ps1`
- `README.md`
- `DESIGN.md`

## 执行前确认

按仓库 `AGENTS.md` 的复杂任务流程，计划确认后才开始以上代码与文档修改。

## 参考文档

- [Robocopy 命令文档](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy)：`/SJ`、`/SL` 与 `/XJ` 参数定义。
- [System.IO.Directory.Delete (.NET Framework) 文档](https://learn.microsoft.com/en-us/previous-versions/windows/embedded/fxeahc5f%28v%3Dvs.102%29)：递归删除不会穿透目录重解析点；实现仍会采用显式两阶段清理。
- [PowerShell Get-ChildItem 文档](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/get-childitem?view=powershell-5.1)：PowerShell 5.1 的链接属性与目录扫描接口。当前引擎已采用手动队列遍历，避免将链接目标纳入树快照。
