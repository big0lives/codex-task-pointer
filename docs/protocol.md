# 协议

本页描述当前实现的 state schema v3、publisher 请求和三个 Hook 事件。机器可校验的字段约束以 [`schemas/state-v3.schema.json`](../schemas/state-v3.schema.json) 与 [`schemas/publish-request-v3.schema.json`](../schemas/publish-request-v3.schema.json) 为准。

## state v3

每个 session 一个 `state.json`，UTF-8 编码、单个 JSON 对象、字段集合固定且不允许额外字段。下面是带占位符的协议模板，`<UUID_V4>` 需要替换为实际值后才能提交：

```json
{
  "schema_version": 3,
  "session_id": "session-example",
  "generation": "g-0123456789abcdef0123456789abcdef",
  "revision": 3,
  "status": "CLEAN",
  "task_id": "<UUID_V4>",
  "pointer_text": "目标：完成示例\n下一步：运行验证",
  "updated_at": "2026-01-01T00:00:00Z"
}
```

字段规则：

- `schema_version` 固定为 `3`。
- `session_id` 匹配 `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`。
- `generation` 匹配 `g-` 加 32 位小写十六进制字符。
- `revision` 是从 1 开始的整数；每次成功写入递增 1。
- `status` 为 `CLEAN`、`DIRTY` 或 `CLEARED`。
- `CLEAN`/`DIRTY` 必须有 UUID v4 `task_id` 和非空 `pointer_text`；`CLEARED` 两者都必须为 `null`。
- `updated_at` 使用 `yyyy-MM-ddTHH:mm:ssZ`。

正文会把 CRLF/CR 规范化为 LF，并按 UTF-8 字节数限制为 8192。state 写入先创建同目录临时文件、WriteThrough 刷新、读回校验，再原子替换；失败会清理临时文件并保留原 state。

## generation + revision CAS

publisher 请求必须同时携带观察到的 `expected_generation` 和 `expected_revision`。空 state 的代际是 `ABSENT`、旧 schema v2 的代际是 `LEGACY_V2`；正式 v3 代际使用 `g-...`。

```json
{
  "schema_version": 3,
  "session_id": "session-example",
  "expected_generation": "g-0123456789abcdef0123456789abcdef",
  "expected_revision": 2,
  "task_id": "<UUID_V4>",
  "target_status": "CLEAN",
  "pointer_text": "目标：完成示例\n下一步：继续"
}
```

示例中的 `<UUID_V4>` 是公开占位符，实际请求必须替换成合法的小写 UUID v4。请求通过 stdin 传输，大小上限 12288 字节；严格 UTF-8、JSON 对象、无重复字段、固定字段集合。`target_status=CLEARED` 时 `task_id` 和 `pointer_text` 必须为 `null`；`CLEAN` 时两者必须非空。

publisher 在 session 互斥内重新读取 state，然后按顺序比较代际和版本：

1. generation 不匹配返回 `STALE_GENERATION`；
2. generation 匹配但 revision 不匹配返回 `STALE_REVISION`；
3. 两者都匹配才写入 `revision + 1`。

新 session 或从 v2 升级时生成新 generation；成功清除也生成新 generation，防止旧请求在清除后通过 ABA 复活。普通 CLEAN/DIRTY 发布沿用当前 generation。失败响应 `ok=false`、退出码为 2，且不改变 state。

## 生命周期事件

Hook stdin 至少包含 `session_id` 与 `hook_event_name`：

| 事件 | 必填附加字段 | 行为 |
| --- | --- | --- |
| `UserPromptSubmit` | 无 | 可继续的 state 写为 `DIRTY` 并递增 revision；空/CLEARED state 建立 CLEARED fence；返回 CAS 或 bootstrap 上下文 |
| `PreCompact` | `trigger=manual\|auto` | 不修改 state；当前指针已在此前 publish/prompt 时持久化 |
| `SessionStart` | `source=startup\|resume\|clear\|compact` | `clear` 写 CLEARED；其他来源读取并注入当前指针或 bootstrap 上下文 |

成功上下文格式包含 `TASK_POINTER_V2` 或 `TASK_POINTER_V2_BOOTSTRAP` 标记、状态、代际、版本、session ID 和 publisher 路径。DIRTY 恢复模式为 `MERGE_FIRST`，CLEAN 恢复模式为 `CONTINUE`。上下文上限为 10000 字节。

错误策略：

- prompt 的 dirty 写失败输出 block JSON，stderr 记录 `TASK_POINTER_V2:<CODE>`，退出码 2；
- startup/resume 读取失败输出 `UNKNOWN_RECOVERY:<CODE>` 并继续；
- clear/compact 读取或恢复失败输出 `TASK_POINTER_RECOVERY_REQUIRED` 并停止继续；
- PreCompact 的输入错误按通用 Hook 失败处理。

## 典型状态序列

```text
ABSENT/0
  --首次 UserPromptSubmit--> CLEARED/g1/1（fence）
  --publisher(CAS g1,1)--> CLEAN/g1/2
  --下一次 UserPromptSubmit--> DIRTY/g1/3
  --publisher(CAS g1,3)--> CLEAN/g1/4
  --SessionStart(clear)--> CLEARED/g2/5
```

数字仅表示相对顺序；实际 generation 每次由随机 UUID v4 生成。

## 兼容性

读取器可识别 schema v2，并将其代际报告为 `LEGACY_V2`。写入器只写 schema v3；第一次成功 prompt/publish 会生成 v3 state。v1 的 envelope 记录不在运行时直接读取，应先使用 [迁移器](migration.md) 做 dry-run 和显式 apply。
