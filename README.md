# Codex Task Pointer

`codex-task-pointer` 是一个独立、可移植的本地任务指针运行时。它把当前任务的最小恢复指针保存为一个受 schema 约束的 `state.json`，再通过根 Hook 在新会话、压缩和用户提示之间恢复上下文。

仓库二可以脱离其他配置仓库单独安装、测试和回滚。核心运行时与安装器不要求复制宿主的配置、会话、记忆或数据库，也不会主动发起网络请求；可选 app-server E2E 是否联网取决于宿主配置。

## 能力

- state schema v3：固定字段、`CLEAN`/`DIRTY`/`CLEARED` 状态，以及 `generation` + `revision` 双字段 CAS。
- 三个生命周期事件：`PreCompact`、`SessionStart`、`UserPromptSubmit`。
- publisher 只从严格 UTF-8 stdin 接收 schema v3 JSON；不会从命令行传递指针正文。
- v1 记录迁移到 v3；默认只扫描，`-Apply` 才写入。
- Windows 安装器：合并 Hook、备份 owned 文件、失败自动恢复和显式回滚。
- PowerShell 单元/边界测试与可选 app-server E2E harness。

## 快速开始（Windows）

要求：PowerShell 7.5 或更高版本。Node.js 18 或更高版本仅在运行 Node harness 时需要。

以下示例使用公开占位路径；请把 `$repoRoot` 和 `$codexHome` 改为本机绝对路径：

```powershell
$repoRoot = 'C:\Work\codex-task-pointer'
$codexHome = 'C:\CodexHome\example'

# 只显示 PowerShell WhatIf 预览，不写入目标目录
pwsh -NoProfile -File "$repoRoot\scripts\install.ps1" `
  -CodexHome $codexHome -Apply -WhatIf

# 应用安装；输出 JSON receipt，其中包含 backup 路径
pwsh -NoProfile -File "$repoRoot\scripts\install.ps1" `
  -CodexHome $codexHome -Apply -Confirm:$false
```

安装器复制运行时与 schema 到 `<CODEX_HOME>\task-pointer\`，并在 `<CODEX_HOME>\hooks.json` 中合并三个事件。已有的非 Task Pointer Hook 会保留。首次使用时，在宿主的 Hook 管理界面审阅并信任新增命令，然后重新启动或恢复会话。

安装器默认不修改 `config.toml`、项目设置、会话、记忆和 state；这些路径也不属于本仓库的安装 owned 集合。详细步骤见 [Windows 安装](docs/installation-windows.md)。

## 最小验证

在仓库根目录执行：

```powershell
pwsh -NonInteractive -NoProfile -File .\tests\Test-TaskPointerLifecycle.ps1
pwsh -NonInteractive -NoProfile -File .\tests\install-smoke.ps1
```

也可以用统一入口跑静态解析、核心测试、安装 smoke 与公开树脱敏门（`-SkipAppServer` 跳过依赖宿主与认证的 app-server 检查）：

```powershell
pwsh -NonInteractive -NoProfile -File .\tests\run-all.ps1 -SkipAppServer
```

两条命令都应以 `SUMMARY ... failed=0` 或 `verdict : PASS` 结束。若只想检查安装计划，可运行：

```powershell
pwsh -NonInteractive -NoProfile -File .\scripts\install.ps1 `
  -CodexHome 'C:\CodexHome\example' -Apply -WhatIf
```

可选的 app-server 探针需要一个隔离的 `CODEX_HOME`、绝对输出路径，以及一个可直接启动的 Codex app-server 命令。当 Codex 通过 npm shim 安装时，默认的 `codex.exe` 无法被子进程直接启动，需要用 `--app-server-command`（或环境变量 `CODEX_APP_SERVER_COMMAND`）指向真实的 `codex.exe`：

```powershell
node .\tests\app-server-hooks-list.mjs `
  --cwd 'C:\Work\sample-project' `
  --codex-home 'C:\CodexHome\example' `
  --output 'C:\Temp\task-pointer-hooks-list.json' `
  --app-server-command '"C:\Path\To\codex.exe" app-server --listen stdio://'
```

`app-server-hooks-list.mjs` 是只读探针：安装后它应发现三个 Task Pointer Hook 定义且无诊断。完整 E2E（`app-server-task-pointer-e2e.mjs`）还会产生真实模型回合，因此要求目标 `CODEX_HOME` 中的 Hook 已在宿主 `/hooks` 界面完成信任审阅，并具备可用的模型认证；全新安装的 Hook 在信任前只会被发现，不会执行。

完整参数与事件断言见 [协议](docs/protocol.md) 和 [架构](docs/architecture.md)。

## 目录

| 路径 | 用途 |
| --- | --- |
| `src/` | store、lifecycle hook、publisher |
| `hooks/hooks.example.json` | 可移植 Hook 定义模板 |
| `schemas/` | state v3 与 publisher request schema |
| `scripts/install.ps1` | 安装、备份、合并、回滚 |
| `scripts/migrate-v1-to-v3.ps1` | v1 到 v3 迁移 |
| `tests/` | PowerShell、安装 smoke、Node harness |
| `docs/architecture.md` | 组件与数据流 |
| `docs/protocol.md` | JSON、CAS、Hook 输入输出 |
| `docs/installation-windows.md` | Windows 操作步骤 |
| `docs/migration.md` | v1 迁移说明 |
| `docs/security.md` | 安全边界与限制 |

## 设计边界

Task Pointer 只保存用户明确发布的短指针，不负责任务生命周期、对话压缩语义或宿主的信任策略。`PreCompact` 事件是观察点；当前 state 已在 publish/prompt 时持久化，Hook 不在压缩前复制或改写 state。`SessionStart` 负责恢复或清除，`UserPromptSubmit` 负责把现有指针标为 `DIRTY` 并发出下一次发布所需的 CAS 基础。

state 根必须是默认 `<CODEX_HOME>\state\task-pointers\v2`、`CODEX_HOME` 下的其他显式路径或系统临时目录；重解析点、路径逃逸、重复字段、非法 UTF-8 和超限输入都会被拒绝。更多边界见 [安全说明](docs/security.md)。

## 许可

源码、schema、测试、示例和文档按 [MIT License](LICENSE) 发布；来源和运行时责任见 [NOTICE](NOTICE.md)。
