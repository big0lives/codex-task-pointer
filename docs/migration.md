# v1 迁移

## 适用范围

迁移器 `scripts/migrate-v1-to-v3.ps1` 把旧 v1 根目录中的 `active.json` 记录转换为 state schema v3。它只处理直接位于 v1 根下一层 session 目录中的记录，不读取宿主配置或其他运行数据。

典型布局：

```text
<V1_ROOT>\
└── <session-key>\
    └── active.json
```

`<V2_ROOT>` 由 store 的路径规则校验，只能是默认 state 根、`CODEX_HOME` 下的其他路径或系统临时目录。建议先把 v1 根复制到隔离位置，再执行迁移预览。

## 两阶段用法

默认是 dry-run，不写 v3 文件：

```powershell
$v1 = 'C:\Work\task-pointer-v1'
$v3 = 'C:\CodexHome\example\state\task-pointers\v2'
pwsh -NonInteractive -NoProfile `
  -File .\scripts\migrate-v1-to-v3.ps1 `
  -V1Root $v1 -V2Root $v3
```

预览无 invalid 后，显式加 `-Apply`：

```powershell
pwsh -NonInteractive -NoProfile `
  -File .\scripts\migrate-v1-to-v3.ps1 `
  -V1Root $v1 -V2Root $v3 -Apply
```

标准输出是一行计数 receipt：

```text
scanned=<n> migrated=<n> existing=<n> invalid=<n> apply=<True|False>
```

退出码为 0 表示扫描完成且 `invalid=0`；退出码为 2 表示至少一条记录无效，脚本在写入前结束，不会以部分成功掩盖 invalid。`existing` 记录已经有相同目标状态/正文时跳过；状态或正文冲突会计入 invalid。

## v1 校验

每个 `active.json` 必须是无 BOM 的严格 UTF-8 单行 JSON envelope：

```json
{"payload":<按键名字典>,"payload_sha256":"<64 位小写十六进制>"}
```

payload 的字段集合、类型和关系会逐项校验：

- `active_snapshot` 的 `schema_version=1`，状态只能是 `CLEAN`、`DIRTY` 或 `RETIRED`；
- `active_tombstone` 的状态必须为 `TOMBSTONE`，reason 只能是 `CLEAR` 或 `NO_ACTIVE`；
- session ID、session key、任务 ID、指针正文、UTF-8 字节数、SHA-256、时间和 trigger 必须一致；
- payload 键按序列化规则排序，envelope 不得有重复字段、额外换行或非 canonical 表示；
- `active.json` 必须位于 v1 根的直接 session 子目录，嵌套目录会拒绝。

## 状态映射

| v1 记录 | v3 `status` | `task_id` / `pointer_text` | generation / revision |
| --- | --- | --- | --- |
| snapshot `CLEAN` | `CLEAN` | 保留 | 新 generation，`1` |
| snapshot `DIRTY` | `DIRTY` | 保留 | 新 generation，`1` |
| snapshot `RETIRED` | `CLEARED` | 都为 `null` | 新 generation，`1` |
| tombstone `TOMBSTONE` | `CLEARED` | 都为 `null` | 新 generation，`1` |

迁移器不会把 v1 的 revision 或旧 envelope hash 搬进 v3；每条新 state 从 revision 1 开始。之后所有写入由 v3 的 generation + revision CAS 管理。

## 与 schema v2 的关系

运行时读取器仍可读取 schema v2，并把其 generation 视为 `LEGACY_V2`。写入器只产生 schema v3；第一次成功 prompt 或 publish 会完成代际升级。v1 记录应优先通过本迁移器转换，不要手工改写 state JSON。

## 迁移后检查

```powershell
pwsh -NonInteractive -NoProfile -File .\tests\Test-TaskPointerLifecycle.ps1
```

检查重点是 CLEAN/DIRTY/RETIRED/TOMBSTONE 映射、重复字段/坏 hash 拒绝、已存在冲突、旧 v2 升级和 Windows session 名称边界。迁移器本身不删除 v1 源文件；确认 v3 可读并完成业务验收后，再按自己的备份保留策略处理源数据。
