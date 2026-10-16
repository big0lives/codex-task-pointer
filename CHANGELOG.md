# 更新记录

## [0.2.0] - 2026-10-16

### 新增

- 每会话追加日志 `journal.jsonl`：每次发布与 fenced 清除各追加一条只含元数据与 SHA-256 的记录，正文不入日志；日志是审计侧车，追加失败不阻塞 CAS（回执带 `journal_appended=false`）。
- 只读诊断入口 `src/task-pointer-report.ps1`：输出状态、`POINTER_AGE_SECONDS`、`revision`、日志深度、缺口与损坏行计数、最近十条日志；`-Recall` 按 `revision` 检索历史发布记录。
- `UserPromptSubmit` 注入的 CAS 上下文新增 `POINTER_AGE_SECONDS`、`JOURNAL_IDENTICAL_TEXT_STREAK` 与 `NEXT_ACTION`，把"指针陈旧"和"原地踏步"暴露给模型。
- 设计说明 `docs/design.md`：记录借鉴自 billion-context（ACP）与 dsh-argp 的机制、明确不做的三件事与 D1–D9 验收表。

### 变更

- **no-op 守卫**：状态已是 `DIRTY` 时，后续 `UserPromptSubmit` 不再改写 `state.json`、不递增 `revision`，但仍注入 CAS 上下文。`revision` 因此从"prompt 轮数"变回"指针内容版本"，`updated_at` 也停在真正最后一次内容变更上，`POINTER_AGE_SECONDS` 才是可信的陈旧信号。
- CLEARED 记录保留被清除指针的 `task_id` 与 `pointer_digest`（UTF-8 字节数），使"清空即抹除"变成可追溯的墓碑。
- README 流程图连线统一为灰色，并补上日志节点。

### 修复

- `Publish-TPV2State` 的首条日志记录把 `previous_revision` 写成 `null`，与 generation 模型用 `ABSENT` 表达"此前不存在"不一致；现统一为 `0`。

## [0.1.0] - 2026-08-30

- 发布 state schema v3，使用 `generation` 与 `revision` 组成乐观并发校验。
- 发布严格 UTF-8 stdin 的 lifecycle hook 与 publisher。
- 支持 `PreCompact`、`SessionStart`、`UserPromptSubmit` 三类根 Hook 事件。
- 发布 v1 到 v3 的只读预览和显式 `-Apply` 迁移器。
- 发布带备份、合并、自动失败恢复和显式回滚的 Windows 安装器。
- 发布 PowerShell 生命周期测试、安装回滚 smoke 和 app-server E2E harness。
- 新增面向用户 agent 的 AGENTS.md 部署手册与双语 README。
- 新增 CONTRIBUTING 与 SECURITY 说明。
