# 更新记录

## [0.1.0] - 2026-08-30

- 发布 state schema v3，使用 `generation` 与 `revision` 组成乐观并发校验。
- 发布严格 UTF-8 stdin 的 lifecycle hook 与 publisher。
- 支持 `PreCompact`、`SessionStart`、`UserPromptSubmit` 三类根 Hook 事件。
- 发布 v1 到 v3 的只读预览和显式 `-Apply` 迁移器。
- 发布带备份、合并、自动失败恢复和显式回滚的 Windows 安装器。
- 发布 PowerShell 生命周期测试、安装回滚 smoke 和 app-server E2E harness。
- 新增面向用户 agent 的 AGENTS.md 部署手册与双语 README。
- 新增 CONTRIBUTING 与 SECURITY 说明。
