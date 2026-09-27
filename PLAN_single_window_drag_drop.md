# 单窗口拖放与常驻提权 Worker 实施计划

## 状态

- 用户已确认方案三；实施完成，隔离验证已执行。
- 本计划取代“双窗口收件箱”和“每次操作单独提权”的方案。

## 故障定位

最近一次会话中，接收窗已在临时收件箱写入 JSON 路径消息，但没有管理员主窗口创建的 `main.ready` 标记，接收窗随后在 3 分钟启动超时后关闭。因此“发送”动作完成了，失败发生在主窗口没有接入收件箱之后；旧中转链路不应继续保留。

## 方案三：单窗口 + 常驻提权 Worker

### 主窗口与权限

- `migrate-local-folders.cmd` 以普通权限启动唯一的 Windows PowerShell 5.1 STA WinForms 主窗口，不提升 cmd，也不启动第二个可见窗口。
- 主窗口和来源表格直接启用 `FileDrop`，把拖入目录复用到 `Add-SourcePaths`。过滤非目录、去重、显示映射，并使旧预检失效。
- 首次点击“扫描并预检”时才请求 UAC 并启动隐藏的提权 Worker。Worker 在当前主窗口会话期间常驻，预检完成后继续等待；后续迁移复用它，不再次请求 UAC。主窗口关闭或空闲时崩溃会断开管道，Worker 退出；任务进行中若主窗口崩溃，Worker 等引擎完成后再退出，不中断复制或源目录切换。Worker 崩溃后重启可能再次出现 UAC。

### 命名管道

- 主窗口先创建随机名称的本地命名管道服务端，再通过 `Start-Process -Verb RunAs` 启动 Worker 客户端，避免启动与监听之间的竞态。
- 使用显式 PipeSecurity DACL，只授予当前用户 SID；主窗口核对管道客户端 PID 是本次启动的 Worker，Worker 核对服务端 PID 是本次主窗口。仅允许固定协议命令，不接受命令行或脚本内容。
- 消息采用带协议版本和请求 ID 的单行 JSON，协议只含 `Hello`/`HelloAck`、`Execute`、`Accepted`/`Error`、`Shutdown`/`Bye`；`Execute` 的动作仅允许 `Analyze`、`Migrate`。Worker 复用现有引擎和 `%TEMP%\mklinktool-<GUID>` 状态/日志目录；主 UI 继续通过现有状态文件刷新进度。
- 不使用 `PipeOptions.CurrentUserOnly`：微软文档说明 Windows 会校验客户端和服务端的用户及提升级别；中等完整性主窗口与高完整性 Worker 正是不同提升级别。使用用户 SID ACL 并双向校验对端 PID。
- Worker 同一时间只接受一个迁移任务；任务期间主界面继续按现有规则禁用列表编辑和关闭窗口。

### 暂停与取消范围

当前 UI 和引擎没有协作式暂停/取消协议。首版只实现启动、握手、运行任务、返回状态和退出；不通过 `Stop-Process` 强制中断 Robocopy 或引擎。强制中断可能落在源目录改名与建链之间，须另做安全的阶段化取消设计。

## 预计改动

1. 改造 `migrate-local-folders.cmd` 为普通权限单窗口启动器。
2. 在 `migrate-local-folders.ps1` 加入主窗口拖放事件与 Pipe 客户端生命周期，保留路径右键、多选、预检失效和当前状态轮询。
3. 新增 `migration-worker.ps1` 常驻提权服务端/任务调度器，校验管道 ACL、对端 PID、消息大小、版本和命令；复用 `migration-engine.ps1` 执行固定 Analyze/Migrate 操作。
4. 移除旧收件箱轮询与双窗口启动逻辑；删除上一方案专用的 `migrate-local-folders-drop-receiver.ps1`。
5. 更新 README、DESIGN 和计划记录，说明首次预检 UAC、单窗口拖放、Worker 生命周期和不支持取消的边界。
6. 不改现有复制、校验、备份恢复以及“只创建 SymbolicLink”的行为。

## 验收

- 双击启动器只有一个可见主窗口；Explorer 可一次拖入多个目录。
- 拖放列表支持去重和非目录过滤，正确预览目标；来源或目标菜单与 Ctrl/Shift 多选移除继续可用。
- 首次预检最多出现一次 UAC；预检成功后开始迁移不再弹 UAC；取消启动 UAC 后主界面恢复，不留假 Worker 状态。
- 同会话 Worker 重用、主窗口关闭退出、无效 PID/协议消息拒绝；主窗口保持现有进度与日志刷新。
- Windows PowerShell 5.1 语法与命名管道协议测试通过；迁移引擎只在 `%TEMP%` 新建的随机测试目录中验证，不接触真实迁移目录。

## 验证结果

- Windows PowerShell 5.1 已解析主窗口与 Worker 脚本；SID ACL 管道构造成功。
- 在 `%TEMP%` 假引擎会话中，Worker 握手、双向 PID 校验、连续执行 Analyze/Migrate 两项固定任务、逐项返回结果及 Shutdown 均通过。
- 在 `%TEMP%` 建立含空格路径及嵌套 Junction 的引擎迁移测试时，当前标准权限进程无法创建目录 SymbolicLink，预检按设计拒绝迁移，来源保持原位；没有触及真实迁移目录。提权后的完整引擎路径需在用户首次启动时由 UAC Worker 执行。
- 交互式 UAC 与 Explorer 拖放没有在当前自动化环境中模拟；主窗口直接绑定 WinForms `FileDrop`，用户可启动后验证。

暂停和取消仍不包含在本次实现中。
