## 变更说明

<!-- 一段话说明本 PR 做了什么，以及为什么。 -->

## 验证

<!-- 在仓库根目录执行并粘贴关键输出。 -->

```powershell
pwsh -NonInteractive -NoProfile -File .\tests\run-all.ps1 -SkipAppServer
```

- [ ] `tests/Test-TaskPointerLifecycle.ps1` 通过
- [ ] `tests/install-smoke.ps1` 通过
- [ ] `scripts/validate-public-tree.ps1` 通过
- [ ] 涉及 Hook 行为的变更已在隔离 `CODEX_HOME` 中验证
- [ ] 未引入真实路径、凭据、会话数据或指针正文
