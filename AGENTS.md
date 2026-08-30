# AGENTS.md — Task Pointer 部署与调试提示词

本文件服务两类 agent 会话：

- **部署会话**（默认）：用户要求安装、配置或调试 Task Pointer 时，把本文件当作执行手册，按第 1–8 节顺序推进；只在第 9 节列出的情形询问用户，其余决定自主做出并说明依据。
- **开发会话**：在本仓库改代码时忽略第 1–8 节，遵守第 10 节。

所有命令默认在仓库根目录、PowerShell 7（pwsh）中执行。占位符：`<REPO_URL>` 是仓库克隆地址，`<HOME>` 是用户 `CODEX_HOME` 的绝对路径，`<SCRATCH>` 是系统临时目录下的工作目录。

## 1. 你要部署什么

Task Pointer 是独立的本地任务指针运行时：把当前任务的最小恢复指针存为受 schema 约束的 `state.json`，再通过根 Hook 在新会话、压缩和用户提示之间恢复上下文。安装只做三件事：

1. 复制运行时到 `<HOME>\task-pointer\`（src、schemas、scripts、hooks.example）；
2. 向 `<HOME>\hooks.json` 合并 `PreCompact`、`SessionStart`、`UserPromptSubmit` 三个事件（既有其他 Hook 原样保留）；
3. 在 `<HOME>\task-pointer-install-backups\` 写入备份 manifest。

它不修改 `config.toml`、凭据、项目设置、会话、Memory 和任何 state。先读 `README.md` 和 `docs/installation-windows.md` 可以获得与本文件一致的细节。

## 2. Preflight（自主执行）

逐项检查，任何一项不满足就进入第 9.2 节：

```powershell
# 操作系统：本仓库安装流程面向 Windows
$env:OS                          # 期望 Windows_NT

# PowerShell ≥ 7.5
pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'

# Codex CLI 已安装
codex --version

# 可选：Node ≥ 18，仅部署后验证（第 6 节）需要
node --version
```

解析 `<HOME>`：`$env:CODEX_HOME` 非空则用它；否则用 `$HOME\.codex`。这是确定性问题，**不要询问用户**，把解析结果明确告诉用户即可。仅当解析结果不存在且用户曾自述使用自定义 home 时，进入第 9.1 节。

检查是否已有安装：`<HOME>\task-pointer\` 或 `<HOME>\hooks.json` 中已含 `task-pointer-lifecycle.ps1` 引用时，走升级路径——流程完全相同，安装器会幂等合并并先备份旧文件；把这一点告知用户。

## 3. 获取仓库与安装前验证（自主执行）

```powershell
git clone <REPO_URL> <SCRATCH>\codex-task-pointer
cd <SCRATCH>\codex-task-pointer
```

安装前先在临时目录跑测试（只写系统临时目录，不碰用户 home）：

```powershell
pwsh -NoProfile -File .\tests\Test-TaskPointerLifecycle.ps1
# 期望结尾：SUMMARY ... passed=35 failed=0 skipped=0 blocked=0（passed 数可随版本增长，failed 必须为 0）

pwsh -NoProfile -File .\tests\install-smoke.ps1
# 期望结尾：verdict : PASS
```

任一失败：停止，原样报告输出，**不要安装**。

## 4. 安装（先预览，再应用）

```powershell
# 预览：不写任何文件
pwsh -NoProfile -File .\scripts\install.ps1 -CodexHome <HOME> -Apply -WhatIf

# 应用：输出 JSON receipt
pwsh -NoProfile -File .\scripts\install.ps1 -CodexHome <HOME> -Apply -Confirm:$false |
  Tee-Object -Variable installReceipt
```

应用后立即从 receipt 提取并记录三个字段：`owned_root`、`hooks_json`、`backup`。`backup` 是回滚唯一凭据，把完整路径告知用户。若用户已有其他 Hook，展示合并预览中新增的三条命令并确认无误（第 9.4 节）。

建议在 Codex 宿主关闭时安装；安装后需要新开或恢复会话才会加载 Hook。

## 5. 唯一必须由用户完成的步骤：信任 Hook

你**无法**代替用户完成信任——这是宿主的安全审阅门，没有 CLI、RPC 或配置开关可绕过。明确告诉用户：

1. 打开 Codex，运行 `/hooks`；
2. 审阅并信任三条新增命令，它们都指向 `<HOME>\task-pointer\src\task-pointer-lifecycle.ps1`，参数为 `-StateRoot <HOME>\state\task-pointers\v2`，分别挂在 `PreCompact`、`SessionStart`、`UserPromptSubmit` 事件上；
3. 信任结果由宿主写入 `<HOME>\config.toml` 的 `[hooks.state]`，即时生效。

用户完成前，Hook 只会被发现、不会执行——这是正常状态，不要试图绕过。

## 6. 部署后验证（自主执行）

### 6.1 只读探针（不需要模型认证）

```powershell
node .\tests\app-server-hooks-list.mjs `
  --cwd <SCRATCH>\probe-cwd `
  --codex-home <HOME> `
  --output <SCRATCH>\hooks-list.json
```

读 receipt 判定：`verdict: PASS`、`hooks.target_count = 3`、`error_count = 0`、`warning_count = 0`。用户已信任后可追加 `--require-trusted` 复验信任状态。

若报 `spawn codex.exe ENOENT`（npm shim 安装的常见情况），定位真实可执行文件后重试：

```powershell
# 常见位置（按序探测）
$env:APPDATA\npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe
# 或用 Get-Command codex.exe；找到后传入：
node .\tests\app-server-hooks-list.mjs ... --app-server-command '"<真实路径>\codex.exe" app-server --listen stdio://'
```

### 6.2 冒烟（让用户确认）

请用户新开一个 Codex 会话：SessionStart 应出现 "Restoring task pointer" 状态提示，且首轮上下文中包含 `TASK_POINTER_V2_BOOTSTRAP` 标记。

### 6.3 完整 E2E（可选，默认跳过）

`tests\run-all.ps1` 不带 `-SkipAppServer` 会运行完整 app-server E2E，要求：隔离 `CODEX_HOME`、其中 Hook 已信任、模型认证可用。用户明确要求全量验证时才做，否则说明跳过原因即可。统一入口的其余门随时可跑：

```powershell
pwsh -NoProfile -File .\tests\run-all.ps1 -SkipAppServer
# 期望 receipt：verdict=PASS，app-server 两项为 SKIP
```

## 7. 回滚

仅在用户要求或安装/验证失败需要还原时执行，使用第 4 节记录的 `backup`：

```powershell
pwsh -NoProfile -File .\scripts\install.ps1 -CodexHome <HOME> -Rollback -BackupPath <backup>
```

回滚只恢复安装器 own 的文件和 Hook 条目，不触碰用户其他配置。

## 8. 故障处理与停止条件

安装器错误码都有明确语义，出现即停止并向用户报告原始输出，不要 improvising：

| 错误码 | 含义 |
| --- | --- |
| `PATH_*`、`STATE_ROOT_*` | 路径非法、逃逸、重解析点或覆盖越界 |
| `JSON_*`、`HOOKS_SCHEMA_INVALID` | 既有 hooks.json 非严格 UTF-8/JSON 或结构不符 |
| `BACKUP_*` | 备份目标冲突或已存在 |
| `SOURCE_MISSING`、`DESTINATION_INVALID` | 仓库源文件缺失或目标被占用 |
| `INSTALL_AND_ROLLBACK_FAILED` | 安装失败且回滚也失败——最高优先级上报 |

红线：不修改用户 `config.toml`、凭据、会话、Memory；不把指针正文、会话内容或用户路径写进报告、日志或本仓库。

## 9. 只在这些情形询问用户

1. `<HOME>` 解析结果不存在，且用户曾提到自定义 home——请用户给出实际路径；
2. Preflight 缺工具（pwsh/codex）——询问是否由你代为安装；
3. **第 5 节信任 Hook**——必须用户亲自完成，你只提供步骤；
4. 用户已有其他 Hook——展示合并预览后请确认；
5. 是否执行可选的完整 E2E（第 6.3 节）。

其余决定（目录解析、测试执行、探测命令、错误诊断）一律自主完成并汇报结果。

## 10. 开发本仓库时的规则

- 改动后运行 `pwsh -NoProfile -File .\tests\run-all.ps1 -SkipAppServer`，必须 `verdict=PASS`；
- `scripts\validate-public-tree.ps1` 是脱敏门：新文件必须登记 allowlist，私有路径、凭据、真实 UUID 零命中；
- 文本一律 UTF-8 无 BOM、LF；不引入第三方运行库；不改活动 `CODEX_HOME` 的私有状态；
- 涉及 Hook 行为的变更，需在隔离 `CODEX_HOME` 中用第 6.1 节探针验证后再提交。
