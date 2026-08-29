# Windows 安装

## 前提

- PowerShell 7.5 或更高版本（脚本带 `#requires -Version 7.5`）。
- 一个可写的绝对 `CODEX_HOME`；可以通过参数传入，也可以使用环境变量 `CODEX_HOME`。
- 宿主应用支持 `hooks.json` 中的 command Hook，并允许用户在 Hook 管理界面审阅和信任命令。

未传 `-CodexHome` 时，安装器依次使用环境变量 `CODEX_HOME`，再回退到当前用户配置目录下的 `.codex`。建议安装和验证都显式传入隔离目录。

## 计划（无写入）

`install.ps1` 支持 PowerShell 的 `-WhatIf` 公共参数。以下命令执行 ShouldProcess 预览并输出 PowerShell 的 `What if` 消息，不会创建 owned 目录、备份目录或 `hooks.json`：

```powershell
$repoRoot = 'C:\Work\codex-task-pointer'
$codexHome = 'C:\CodexHome\example'
pwsh -NoProfile -File "$repoRoot\scripts\install.ps1" `
  -CodexHome $codexHome -Apply -WhatIf
```

不带 `-Apply` 的调用同样只读，并输出 JSON `mode=PLAN` receipt：

```powershell
pwsh -NoProfile -File "$repoRoot\scripts\install.ps1" -CodexHome $codexHome
```

## 应用安装

```powershell
$receiptText = pwsh -NonInteractive -NoProfile `
  -File "$repoRoot\scripts\install.ps1" `
  -CodexHome $codexHome -Apply -Confirm:$false
$receipt = $receiptText | Select-Object -Last 1 | ConvertFrom-Json
$receipt | Format-List
```

安装步骤如下：

1. 解析并校验 `CODEX_HOME`、owned 根、Hook 文件和备份目标；路径组件中的意外重解析点会终止操作。
2. 在 `task-pointer-install-backups\<timestamp>-<unique-id>`（或 `-BackupPath` 指定的位置）创建备份 manifest。
3. 复制七个 owned 文件到 `<CODEX_HOME>\task-pointer\`：三个 `src` 入口、迁移器、两个 schema 和 `hooks.example.json`。
4. 在 `<CODEX_HOME>\hooks.json` 中为 `PreCompact`、`SessionStart`、`UserPromptSubmit` 合并绝对 lifecycle 路径和 state 根。
5. 读回 JSON 并比较结构；任一步骤失败都尝试使用刚创建的备份恢复。

成功 receipt 至少包含 `installed=true`、`codex_home`、`owned_root`、`hooks_json`、`backup`、三个 `hook_events` 和 `trust_required=true`。receipt 中的路径是本机运行时值，不应复制到公开 issue 或文档。

## Hook 合并规则

安装器不会用示例文件覆盖整个 `hooks.json`。对每个目标事件，它先识别同时指向当前 lifecycle 脚本和 state 根的旧 handler，移除这些旧定义，再追加一份当前定义；其他 matcher、事件和 handler 保留。`SessionStart` 使用 matcher `^(startup|resume|clear|compact)$`，`PreCompact` 使用 `^(manual|auto)$`，用户提示事件不设 matcher。

生成的 command 形如：

```text
pwsh -NoProfile -File "<CODEX_HOME>\task-pointer\src\task-pointer-lifecycle.ps1" -StateRoot "<CODEX_HOME>\state\task-pointers\v2"
```

同时写入可移植的 `/` 路径和 Windows `\` 路径。示例文件中的 `<CODEX_HOME>` 只用于说明结构，安装器不会读取该示例做文本替换；推荐始终让安装器按目标 home 生成定义。

安装完成后，打开宿主的 Hook 管理界面审阅命令并完成信任。安装器不会替用户改变信任状态，也不会自动启用其他事件。

## 回滚

应用安装返回的 `backup` 路径就是回滚输入：

```powershell
pwsh -NonInteractive -NoProfile `
  -File "$repoRoot\scripts\install.ps1" `
  -CodexHome $codexHome `
  -Rollback -BackupPath $receipt.backup -Confirm:$false
```

回滚先验证 manifest 的 schema、目标 `CODEX_HOME`、owned 根、相对文件清单和三条 Hook 安装记录。它只移除仍匹配本次安装的 handler，并恢复备份中的 owned 文件；如果用户在安装后编辑了其他 Hook，编辑内容会保留。原本没有 `hooks.json` 或 owned 根时，回滚会在清空本次资源后删除由本次安装新建的空路径。

备份目标不得与 `CODEX_HOME`、`task-pointer` 或 `hooks.json` 重叠，也不得位于意外重解析点下。备份目录应保留到确认回滚不再需要为止。

## 安装 smoke

在仓库根目录运行：

```powershell
pwsh -NonInteractive -NoProfile -File .\tests\install-smoke.ps1
```

该 smoke 在系统临时目录建立隔离 home，确认既有 `config.toml` 字节不变、无关 Hook 保留、三个事件存在、owned 文件复制成功，并在最后完成回滚和临时目录清理。

## 常见失败类别

| 类别 | 含义 |
| --- | --- |
| `PATH_REPARSE_POINT` / `PATH_ESCAPE` | 目标路径包含不允许的重解析点或越出允许根 |
| `HOOKS_PATH_INVALID` / `JSON_ROOT_INVALID` | Hook 路径不是普通文件，或 JSON 根/`hooks` 值类型不合法 |
| `JSON_ENCODING_INVALID` / `JSON_PARSE_FAILED` / `JSON_DUPLICATE_FIELD` | Hook 或 manifest 不是严格 UTF-8 JSON，或包含重复字段 |
| `BACKUP_TARGET_CONFLICT` | 备份目标与安装目标重叠 |
| `BACKUP_*` | manifest 缺失、版本不匹配或目标漂移 |
| `DESTINATION_INVALID` | 某个 owned 文件目标已被目录或其他非文件对象占用 |
| `INSTALL_AND_ROLLBACK_FAILED` | 安装和自动恢复都失败，需要保留现场并人工检查 |

错误消息会压缩换行和控制字符；不要把包含路径的原始错误直接公开。
