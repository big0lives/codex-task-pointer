---
name: Bug 报告
about: 报告 Task Pointer 运行时、安装器或迁移器的问题
labels: bug
---

**环境**

- OS 与版本：
- PowerShell 版本（`pwsh --version`）：
- Codex 宿主版本（如涉及 Hook 行为）：
- 安装方式（install.ps1 / 手动复制）：

**现象**

描述实际行为与期望行为。

**复现步骤**

1.
2.

**收据**

请附上相关 JSON receipt（`install.ps1`、`migrate-v1-to-v3.ps1` 或测试输出）。
不要包含认证信息、会话内容或指针正文。

**其他**

- 是否已在宿主 `/hooks` 界面信任新安装的 Hook？
- 是否修改过 `<CODEX_HOME>\hooks.json` 中由安装器写入的命令？
