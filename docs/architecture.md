# 架构

## 目标与边界

运行时由三个 PowerShell 入口组成：

1. `src/task-pointer-store.ps1` 负责路径解析、schema 校验、互斥、原子写入和 CAS。
2. `src/task-pointer-lifecycle.ps1` 把宿主 Hook 的 stdin 事件转换为 state 变更或恢复上下文。
3. `src/task-pointer-publish.ps1` 接收一次性的 stdin JSON 请求，并把新的指针以 CAS 方式发布。

`scripts/install.ps1` 只负责把这些入口、两个 schema 和 Hook 示例复制到一个明确的 owned 根；它不承担任务编排，也不读取或改写宿主的其他运行数据。仓库可在没有其他配置仓库的情况下独立运行。

## 存储布局

默认根由 `CODEX_HOME` 环境变量决定；未设置时使用当前用户配置目录下的 `.codex`。state 根为：

```text
<CODEX_HOME>\state\task-pointers\v2\
└── s-<session-id 的 UTF-8 小写十六进制编码>\
    └── state.json
```

session ID 只能匹配 `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`。编码目录避免 Windows 保留名称和路径别名带来的碰撞。为兼容旧 state，读取时也接受 state 根下与 session ID 完全相同的旧目录；编码目录和旧目录同时存在会报告冲突，不会猜测应使用哪一个。

`-StateRoot` 只能指向默认根、`CODEX_HOME` 下的其他路径或系统临时目录。每个已存在的路径组件都会检查重解析点；不在允许范围内的重解析点、路径逃逸和目录/文件类型冲突都会被拒绝。

## 状态流

```text
Hook stdin
   │ 读取、严格 UTF-8 解码、事件校验
   ▼
按 session 获取互斥（最多等待 5 秒）
   │
   ├─ UserPromptSubmit ──> 写 DIRTY 或建立 CLEARED fence ──> 返回 CAS 上下文
   ├─ PreCompact       ──> 不写 state，直接成功
   └─ SessionStart     ──> clear 写 CLEARED；其余读取并注入恢复/启动上下文

publisher stdin JSON ──> 同一互斥 + generation/revision 校验
                         └─> 临时文件写入、刷新、读回、原子替换
```

所有 writer 使用同一命名互斥，因此 prompt、clear 和 publisher 在进程间串行化。CAS 校验失败时不会写文件；并发请求中只有持有匹配代际和版本的请求可以提交。

## Hook 适配

`hooks/hooks.example.json` 描述三个宿主事件的结构，但不是安装器的文本模板。安装器根据目标 home 独立生成绝对路径，并同时写入 `command` 与 `commandWindows`：

- `PreCompact` 匹配 `manual` 或 `auto`；生命周期脚本只确认事件，不复制 state。
- `SessionStart` 匹配 `startup`、`resume`、`clear` 或 `compact`；`clear` 会建立新的 CLEARED 状态，其余来源读取当前指针。
- `UserPromptSubmit` 无额外 matcher；它把可继续的 CLEAN 指针标记为 DIRTY，并返回下一次 publisher 请求所需的 generation/revision。

成功恢复通过 `hookSpecificOutput.additionalContext` 返回，且带 `continue: true`。恢复失败时：普通启动/恢复返回 `UNKNOWN_RECOVERY` 诊断并继续；clear/compact 返回 `TASK_POINTER_RECOVERY_REQUIRED` 并停止继续；prompt 写失败返回 block 响应并退出码 2。

## 组件所有权

安装器的 owned 文件是 `src/task-pointer-store.ps1`、`src/task-pointer-lifecycle.ps1`、`src/task-pointer-publish.ps1`、`scripts/migrate-v1-to-v3.ps1`、两个 `schemas/*.json` 和 `hooks.example.json`。Hook 合并只删除同一 lifecycle 路径与 state 根的旧定义，再追加当前定义；其他事件和 handler 原样保留。回滚按备份 manifest 逐项恢复，发现目标漂移或重解析点时停止。

## 资源上限

| 资源 | 上限 |
| --- | ---: |
| 指针正文（UTF-8） | 8192 字节 |
| 恢复上下文（UTF-8） | 10000 字节 |
| `state.json` | 32768 字节 |
| lifecycle Hook stdin | 65536 字节 |
| publisher 请求 stdin | 12288 字节 |

这些上限在解码或写入前检查，避免超大输入进入上下文或磁盘。
