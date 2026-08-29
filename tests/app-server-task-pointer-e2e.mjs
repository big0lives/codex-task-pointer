import { createHash, randomUUID } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { promises as fs } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

let E2E_STATE_ROOT;
let E2E_PUBLISHER;
const SCRIPT_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_PUBLISHER = path.resolve(SCRIPT_DIRECTORY, "..", "src", "task-pointer-publish.ps1");
const sha256 = (value) => createHash("sha256").update(String(value), "utf8").digest("hex");

function requireAbsolutePath(value, name) {
  if (typeof value !== "string" || value.length === 0 || !path.isAbsolute(value)) {
    throw new Error(`${name} 必须是绝对路径`);
  }
  return path.resolve(value);
}

function samePath(left, right) {
  const leftPath = path.resolve(left);
  const rightPath = path.resolve(right);
  return process.platform === "win32"
    ? leftPath.toLowerCase() === rightPath.toLowerCase()
    : leftPath === rightPath;
}

function defaultAppServerCommand() {
  return process.platform === "win32"
    ? "codex.exe app-server --listen stdio://"
    : "codex app-server --listen stdio://";
}

function resolveAppServerCommand(value) {
  const fromEnvironment = process.env.CODEX_APP_SERVER_COMMAND
    ?? process.env.TASK_POINTER_APP_SERVER_COMMAND;
  const command = value ?? fromEnvironment ?? defaultAppServerCommand();
  if (typeof command !== "string" || command.trim().length === 0) {
    throw new Error("app-server command 不能为空");
  }
  return command.trim();
}

function splitCommandLine(command) {
  const parts = [];
  let current = "";
  let quote = null;
  for (const character of command) {
    if (quote) {
      if (character === quote) quote = null;
      else current += character;
    } else if (character === "\"" || character === "'") {
      quote = character;
    } else if (/\s/.test(character)) {
      if (current) {
        parts.push(current);
        current = "";
      }
    } else {
      current += character;
    }
  }
  if (quote) throw new Error("app-server command 引号未闭合");
  if (current) parts.push(current);
  if (parts.length === 0) throw new Error("app-server command 不能为空");
  return parts;
}

function summarizeError(error) {
  const message = error instanceof Error ? error.message : String(error ?? "");
  return {
    category: error?.name ?? "Error",
    message_sha256: sha256(message),
    message_byte_count: Buffer.byteLength(message, "utf8"),
  };
}

function summarizeText(value) {
  const text = String(value ?? "");
  return { sha256: sha256(text), byte_count: Buffer.byteLength(text, "utf8") };
}

function spawnAppServer(command, cwd, codexHome) {
  const [executable, ...args] = splitCommandLine(command);
  return spawn(executable, args, {
    cwd,
    env: { ...process.env, CODEX_HOME: codexHome },
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
    shell: false,
  });
}

function parseArgs(argv) {
  const values = {};
  let requireTrusted = false;
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (key === "--require-trusted") {
      requireTrusted = true;
      continue;
    }
    const value = argv[index + 1];
    if (!["--cwd", "--output", "--case", "--codex-home", "--state-root", "--publisher", "--app-server-command"].includes(key) || !value) {
      throw new Error("用法：--cwd ABS --output ABS [--case all|auto] [--codex-home ABS] [--state-root ABS] [--publisher ABS] [--app-server-command COMMAND] [--require-trusted]");
    }
    values[key.slice(2)] = value;
    index += 1;
  }
  if (!values.cwd || !values.output) throw new Error("cwd 和 output 必须是绝对路径");
  const cwd = requireAbsolutePath(values.cwd, "cwd");
  const output = requireAbsolutePath(values.output, "output");
  const codexHomeRaw = values["codex-home"] ?? cwd;
  const codexHome = requireAbsolutePath(codexHomeRaw, "codex-home");
  const stateRoot = values["state-root"]
    ? requireAbsolutePath(values["state-root"], "state-root")
    : path.resolve(codexHome, "state", "task-pointers", "v2");
  const installedPublisher = path.resolve(codexHome, "task-pointer", "src", "task-pointer-publish.ps1");
  const publisher = values.publisher
    ? requireAbsolutePath(values.publisher, "publisher")
    : (existsSync(installedPublisher) ? installedPublisher : DEFAULT_PUBLISHER);
  const testCase = values.case ?? "all";
  if (!["all", "auto"].includes(testCase)) throw new Error("case must be all or auto");
  return {
    cwd,
    output,
    codexHome,
    stateRoot,
    publisher,
    appServerCommand: resolveAppServerCommand(values["app-server-command"]),
    codexHomeSource: values["codex-home"] ? "argument" : "cwd-default",
    stateRootSource: values["state-root"] ? "argument" : "codex-home-default",
    publisherSource: values.publisher ? "argument" : (existsSync(installedPublisher) ? "codex-home-install" : "repository-default"),
    requireTrusted,
    testCase,
  };
}

class AppServerClient {
  constructor(cwd, codexHome, command) {
    this.child = null;
    this.buffer = "";
    this.stderr = "";
    this.nextId = 1;
    this.pending = new Map();
    this.notifications = [];
    this.waiters = [];
    this.exitResult = null;
    this.exitPromise = new Promise((resolve) => { this.resolveExit = resolve; });
    try {
      this.child = spawnAppServer(command, cwd, codexHome);
      this.child.stderr.on("data", (chunk) => { this.stderr += chunk.toString("utf8"); });
      this.child.stdout.on("data", (chunk) => this.#consume(chunk.toString("utf8")));
      this.child.stdin.on("error", () => {});
      this.child.on("exit", (code, signal) => {
        if (!this.exitResult) this.exitResult = { code, signal: signal ?? null };
        this.resolveExit(this.exitResult);
        const error = new Error(`app-server exit ${code ?? "signal"}`);
        for (const [, pending] of this.pending) pending.reject(error);
        this.pending.clear();
        for (const waiter of [...this.waiters]) waiter.fail(error);
      });
      this.child.on("error", (error) => {
        if (!this.exitResult) this.exitResult = { code: null, signal: null, error: error.message };
        this.resolveExit(this.exitResult);
        for (const [, pending] of this.pending) pending.reject(error);
        this.pending.clear();
        for (const waiter of [...this.waiters]) waiter.fail(error);
      });
    } catch (error) {
      this.exitResult = { code: null, signal: null, error: error?.message ?? String(error) };
      this.resolveExit(this.exitResult);
    }
  }

  #consume(chunk) {
    this.buffer += chunk;
    while (this.buffer.includes("\n")) {
      const newline = this.buffer.indexOf("\n");
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (!line) continue;
      let message;
      try { message = JSON.parse(line); } catch { continue; }
      if (typeof message.id === "number" && this.pending.has(message.id)) {
        const pending = this.pending.get(message.id);
        this.pending.delete(message.id);
        if (message.error) pending.reject(new Error(JSON.stringify(message.error)));
        else pending.resolve(message.result);
        continue;
      }
      if (typeof message.method === "string") {
        this.notifications.push(message);
        for (const waiter of [...this.waiters]) waiter.check();
      }
    }
  }

  send(message) {
    if (!this.child || this.exitResult) throw new Error("app-server unavailable");
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  request(method, params, timeoutMs = 60_000) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      if (!this.child || this.exitResult) {
        reject(new Error("app-server unavailable"));
        return;
      }
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timeout`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (value) => { clearTimeout(timeout); resolve(value); },
        reject: (error) => { clearTimeout(timeout); reject(error); },
      });
      try { this.send({ method, id, params }); }
      catch (error) {
        this.pending.delete(id);
        clearTimeout(timeout);
        reject(error);
      }
    });
  }

  waitFor(predicate, startIndex = 0, timeoutMs = 60_000) {
    return new Promise((resolve, reject) => {
      const waiter = {
        check: () => {
          for (let index = startIndex; index < this.notifications.length; index++) {
            if (predicate(this.notifications[index])) {
              clearTimeout(timeout);
              this.waiters = this.waiters.filter((item) => item !== waiter);
              resolve(this.notifications[index]);
              return;
            }
          }
        },
        fail: (error) => {
          clearTimeout(timeout);
          this.waiters = this.waiters.filter((item) => item !== waiter);
          reject(error);
        },
      };
      const timeout = setTimeout(() => {
        this.waiters = this.waiters.filter((item) => item !== waiter);
        reject(new Error("notification timeout"));
      }, timeoutMs);
      this.waiters.push(waiter);
      waiter.check();
    });
  }

  waitForCount(predicate, count, startIndex = 0, timeoutMs = 60_000) {
    return this.waitFor(() => {
      let matches = 0;
      for (let index = startIndex; index < this.notifications.length; index++) {
        if (predicate(this.notifications[index])) matches += 1;
      }
      return matches >= count;
    }, startIndex, timeoutMs);
  }

  async close() {
    if (this.child && !this.exitResult) {
      try { this.child.stdin.end(); } catch {}
      const timeout = new Promise((resolve) => setTimeout(() => resolve({ code: null, signal: "timeout", forced: true }), 5_000));
      const result = await Promise.race([this.exitPromise, timeout]);
      if (result.forced && !this.exitResult) {
        try { this.child.kill(); } catch {}
        await Promise.race([this.exitPromise, new Promise((resolve) => setTimeout(resolve, 1_000))]);
      }
      if (!this.exitResult) {
        try { this.child.kill("SIGKILL"); } catch {}
        await Promise.race([this.exitPromise, new Promise((resolve) => setTimeout(resolve, 1_000))]);
      }
      if (!this.exitResult) {
        for (const stream of [this.child.stdin, this.child.stdout, this.child.stderr]) {
          try { stream.destroy(); } catch {}
        }
        this.child.unref();
      }
    }
    const result = this.exitResult ?? { code: null, signal: "timeout", forced: true };
    return { ...result, ok: result.code === 0 && !result.signal && !result.error };
  }
}

function threadStartParams(cwd, source = "startup", config = null) {
  return {
    cwd,
    ephemeral: false,
    approvalPolicy: "never",
    sandbox: "danger-full-access",
    sessionStartSource: source,
    ...(config ? { config } : {}),
  };
}

function sessionKey(sessionId) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(sessionId)) throw new Error("unsafe session id");
  return `s-${Buffer.from(sessionId, "utf8").toString("hex")}`;
}

function stateDir(sessionId) { return path.join(E2E_STATE_ROOT, sessionKey(sessionId)); }
function statePath(sessionId) { return path.join(stateDir(sessionId), "state.json"); }

async function assertSessionAbsent(sessionId) {
  for (const directory of [stateDir(sessionId), path.join(E2E_STATE_ROOT, sessionId)]) {
    try { await fs.lstat(directory); throw new Error("session directory not absent"); }
    catch (error) { if (error.code !== "ENOENT") throw error; }
  }
}

async function readState(sessionId) {
  return JSON.parse(await fs.readFile(statePath(sessionId), "utf8"));
}

async function publishClean(sessionId, pointer, expectedGeneration, expectedRevision) {
  const request = {
    schema_version: 3,
    session_id: sessionId,
    expected_generation: expectedGeneration,
    expected_revision: expectedRevision,
    task_id: randomUUID(),
    target_status: "CLEAN",
    pointer_text: pointer,
  };
  const result = spawnSync("pwsh", [
    "-NoProfile", "-File", E2E_PUBLISHER, "-SessionId", sessionId, "-StateRoot", E2E_STATE_ROOT,
  ], { input: `${JSON.stringify(request)}\n`, encoding: "utf8", windowsHide: true, env: { ...process.env, CODEX_HOME: options.codexHome } });
  if (result.status !== 0) throw new Error("publisher failed");
  let receipt;
  try { receipt = JSON.parse(result.stdout.trim()); }
  catch { throw new Error("publisher receipt parse failed"); }
  if (!receipt.ok || receipt.schema_version !== 3 || receipt.session_id !== sessionId
      || receipt.status !== "CLEAN" || receipt.revision !== expectedRevision + 1
      || typeof receipt.generation !== "string" || !/^g-[0-9a-f]{32}$/.test(receipt.generation)) {
    throw new Error("publisher receipt invalid");
  }
  return receipt;
}

async function snapshotInventory() {
  const entries = await fs.readdir(E2E_STATE_ROOT, { withFileTypes: true });
  const inventory = [];
  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    const item = { name: entry.name, kind: entry.isDirectory() ? "directory" : entry.isFile() ? "file" : "other" };
    if (entry.isDirectory()) {
      const children = await fs.readdir(path.join(E2E_STATE_ROOT, entry.name), { withFileTypes: true });
      item.children = [];
      for (const child of children.sort((left, right) => left.name.localeCompare(right.name))) {
        const childItem = { name: child.name, kind: child.isFile() ? "file" : child.isDirectory() ? "directory" : "other" };
        if (child.isFile()) {
          const bytes = await fs.readFile(path.join(E2E_STATE_ROOT, entry.name, child.name));
          childItem.bytes = bytes.toString("base64");
          childItem.sha256 = createHash("sha256").update(bytes).digest("hex");
        }
        item.children.push(childItem);
      }
    } else if (entry.isFile()) {
      const bytes = await fs.readFile(path.join(E2E_STATE_ROOT, entry.name));
      item.bytes = bytes.toString("base64");
      item.sha256 = createHash("sha256").update(bytes).digest("hex");
    }
    inventory.push(item);
  }
  return inventory;
}

function inventoryWithoutOwned(inventory, sessions) {
  const owned = new Set(sessions.map(sessionKey));
  return inventory.filter((item) => !owned.has(item.name));
}

async function removeOwnedState(sessionId) {
  const directory = stateDir(sessionId);
  const state = statePath(sessionId);
  const entries = await fs.readdir(directory, { withFileTypes: true }).catch((error) => {
    if (error.code === "ENOENT") return null;
    throw error;
  });
  if (!entries) return;
  if (entries.some((entry) => entry.name !== "state.json" || !entry.isFile())) {
    throw new Error("owned state directory is not empty");
  }
  await fs.unlink(state);
  await fs.rmdir(directory);
}

function hookCompleted(eventName, threadId) {
  return (item) => item.method === "hook/completed"
    && item.params?.threadId === threadId
    && item.params?.run?.eventName === eventName
    && item.params?.run?.status === "completed";
}

function hookTerminal(eventName, threadId) {
  return (item) => item.method === "hook/completed"
    && item.params?.threadId === threadId
    && item.params?.run?.eventName === eventName
    && item.params?.run?.status !== "running";
}

function turnCompleted(threadId, turnId) {
  return (item) => item.method === "turn/completed"
    && item.params?.threadId === threadId
    && item.params?.turn?.id === turnId
    && item.params?.turn?.status === "completed";
}

function hookEntriesText(notification) {
  const entries = notification?.params?.run?.entries;
  if (!Array.isArray(entries)) throw new Error("hook notification missing entries");
  return entries.map((entry) => `${entry?.kind ?? ""}:${entry?.text ?? ""}`).join("\n");
}

function hookEventName(hook) {
  return hook?.eventName ?? hook?.event_name ?? null;
}

function taskPointerDefinitionKind(hook) {
  const command = hook?.command ?? hook?.commandWindows ?? null;
  const handlerType = hook?.handlerType ?? hook?.handler_type ?? null;
  if ((handlerType !== null && handlerType !== "command") || typeof command !== "string") return "other";
  return /task-pointer-lifecycle\.ps1/i.test(command) ? "task-pointer" : "other";
}

function assertBootstrapHook(notification, expected) {
  const text = hookEntriesText(notification);
  const expectedEntries = [
    ["bootstrap marker", "TASK_POINTER_V2_BOOTSTRAP"],
    ["status", `STATUS=${expected.status}`],
    ["generation", `GENERATION=${expected.generation}`],
    ["revision", `REVISION=${expected.revision}`],
    ["session", `SESSION_ID=${expected.sessionId}`],
    ["publisher", `PUBLISH_CURRENT_POINTER_PATH=${E2E_PUBLISHER}`],
    ["transport", "PUBLISH_TRANSPORT=STDIN_JSON"],
    ["schema", "REQUEST_SCHEMA=3"],
  ];
  for (const [label, value] of expectedEntries) {
    if (!text.includes(value)) throw new Error(`bootstrap hook entry missing ${label}`);
  }
}

async function waitForSuccessfulHook(client, eventName, threadId, startIndex, timeoutMs) {
  const notification = await client.waitFor(hookTerminal(eventName, threadId), startIndex, timeoutMs);
  if (notification.params?.run?.status !== "completed") {
    throw new Error(`${eventName} hook did not complete`);
  }
  return notification;
}

async function assertAssistantTurnContains(client, threadId, turnId, expected) {
  const thread = (await client.request("thread/read", { threadId, includeTurns: true }, 60_000)).thread;
  const turn = (thread?.turns ?? []).find((item) => item.id === turnId);
  const messages = (turn?.items ?? []).filter((item) => item.type === "agentMessage");
  if (!JSON.stringify(messages).includes(expected)) throw new Error("assistant turn missing expected marker");
}

async function startTurn(client, threadId, text, timeoutMs = 240_000, expectSessionStart = false) {
  const index = client.notifications.length;
  const response = await client.request("turn/start", {
    threadId,
    input: [{ type: "text", text, text_elements: [] }],
  }, 60_000);
  const turnId = response?.turn?.id;
  if (!turnId) throw new Error("turn/start missing id");
  const sessionStartHook = expectSessionStart
    ? await waitForSuccessfulHook(client, "sessionStart", threadId, index, 60_000)
    : null;
  const userPromptHook = await waitForSuccessfulHook(client, "userPromptSubmit", threadId, index, 60_000);
  const completed = await client.waitFor(turnCompleted(threadId, turnId), index, timeoutMs);
  return { turnId, startIndex: index, sessionStartHook, userPromptHook, completed };
}

const rawArgs = process.argv.slice(2);
let options = null;
let parseError = null;
try { options = parseArgs(rawArgs); }
catch (error) { parseError = error; }

function rawOutputPath(argv) {
  for (let index = 0; index < argv.length - 1; index += 1) {
    if (argv[index] === "--output" && path.isAbsolute(argv[index + 1])) {
      return path.resolve(argv[index + 1]);
    }
  }
  return null;
}

async function writeReceipt(output, value) {
  await fs.mkdir(path.dirname(output), { recursive: true });
  await fs.writeFile(output, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

if (!options) {
  const output = rawOutputPath(rawArgs);
  const report = {
    schema_version: 3,
    generated_at: new Date().toISOString(),
    stage: "argument_validation",
    verdict: "FAIL",
    error: summarizeError(parseError),
    cleanup: { session_count: 0, removed: 0, created_threads: 0, deleted_threads: 0, errors: [], server_closed: true },
  };
  if (output) {
    try { await writeReceipt(output, report); } catch {}
  }
  process.stderr.write("Task Pointer E2E 参数无效；详见 JSON receipt\n");
  process.exitCode = 1;
} else {
E2E_STATE_ROOT = options.stateRoot;
E2E_PUBLISHER = options.publisher;
const clients = [];
const newClient = () => {
  const value = new AppServerClient(options.cwd, options.codexHome, options.appServerCommand);
  clients.push(value);
  return value;
};
let client = null;
const sessions = [];
const threadIds = [];
const summary = {
  schema_version: 3,
  generated_at: new Date().toISOString(),
  cwd_sha256: sha256(options.cwd),
  codex_home_sha256: sha256(options.codexHome),
  production_state_root_sha256: sha256(E2E_STATE_ROOT),
  publisher_sha256: sha256(E2E_PUBLISHER),
  app_server_command_sha256: sha256(options.appServerCommand),
  path_sources: {
    codex_home: options.codexHomeSource,
    state_root: options.stateRootSource,
    publisher: options.publisherSource,
  },
  hooks: null,
  manual: null,
  auto: null,
  clear: null,
  resume: null,
  cleanup: null,
  stage: "startup",
  require_trusted: options.requireTrusted,
};
let runError = null;
const cleanupErrors = [];
let inventoryBefore = [];
let stateRootCreated = false;
let stateRootExistedBefore = false;
const createdStateDirectories = [];

async function registerThread(thread) {
  if (!thread?.id || !thread?.sessionId) throw new Error("thread/start missing id or sessionId");
  threadIds.push(thread.id);
  sessions.push(thread.sessionId);
  await assertSessionAbsent(thread.sessionId);
  return thread;
}

try {
  const rootInfo = await fs.lstat(E2E_STATE_ROOT).catch((error) => {
    if (error.code === "ENOENT") return null;
    throw error;
  });
  if (rootInfo && !rootInfo.isDirectory()) throw new Error("state root is not a directory");
  if (rootInfo && rootInfo.isSymbolicLink()) throw new Error("state root reparse point");
  if (!rootInfo) {
    let candidate = E2E_STATE_ROOT;
    while (candidate !== path.dirname(candidate)
        && !samePath(candidate, options.cwd)
        && !samePath(candidate, options.codexHome)) {
      const exists = await fs.lstat(candidate).then(() => true).catch((error) => {
        if (error.code === "ENOENT") return false;
        throw error;
      });
      if (exists) break;
      createdStateDirectories.push(candidate);
      candidate = path.dirname(candidate);
    }
    await fs.mkdir(E2E_STATE_ROOT, { recursive: true });
    stateRootCreated = true;
  } else {
    stateRootExistedBefore = true;
  }
  inventoryBefore = await snapshotInventory();
  client = newClient();
  await client.request("initialize", {
    clientInfo: { name: "task_pointer_v2_e2e", title: "Task Pointer v2 E2E", version: "1.0.0" },
  });
  client.send({ method: "initialized", params: {} });

  summary.stage = "hooks_list";
  const hooks = await client.request("hooks/list", { cwds: [options.cwd] });
  const hookRow = hooks?.data?.[0] ?? {};
  const hookItems = Array.isArray(hookRow.hooks) ? hookRow.hooks : [];
  summary.hooks = {
    count: hookItems.length,
    enabled: hookItems.filter((item) => item.enabled === true).length,
    trusted: hookItems.filter((item) => item.trustStatus === "trusted").length,
    error_count: Array.isArray(hookRow.errors) ? hookRow.errors.length : null,
    warning_count: Array.isArray(hookRow.warnings) ? hookRow.warnings.length : null,
  };
  const targetItems = hookItems.filter((item) => taskPointerDefinitionKind(item) === "task-pointer");
  const targetEventNames = new Set(targetItems.map(hookEventName));
  const requiredEvents = ["preCompact", "sessionStart", "userPromptSubmit"];
  const missingEvents = requiredEvents.filter((eventName) => !targetEventNames.has(eventName));
  summary.hooks.target_count = targetItems.length;
  if (missingEvents.length > 0 || summary.hooks.error_count !== 0 || summary.hooks.warning_count !== 0
      || targetItems.length < requiredEvents.length) {
    throw new Error("hook list target definitions missing, invalid, or diagnosed");
  }
  if (options.requireTrusted && targetItems.some((item) => (item.trustStatus ?? item.trust_status) !== "trusted")) {
    throw new Error("target hooks are not fully trusted; review them in /hooks first");
  }

  if (options.testCase === "all") {
  const manualStartIndex = client.notifications.length;
  summary.stage = "manual_thread_start";
  const manualThread = await registerThread((await client.request("thread/start", threadStartParams(options.cwd))).thread);
  const manualBootstrapTurn = await startTurn(client, manualThread.id, "读取本轮 TASK_POINTER_V2_BOOTSTRAP，只回复其中的 STATUS、GENERATION、REVISION、SESSION_ID 和 PUBLISH_CURRENT_POINTER_PATH。", 240_000, true);
  const manualFence = await readState(manualThread.sessionId);
  if (manualFence.status !== "CLEARED" || manualFence.revision !== 1) throw new Error("manual bootstrap fence invalid");
  assertBootstrapHook(manualBootstrapTurn.sessionStartHook, { status: "ABSENT", generation: "ABSENT", revision: 0, sessionId: manualThread.sessionId });
  assertBootstrapHook(manualBootstrapTurn.userPromptHook, { status: "CLEARED", generation: manualFence.generation, revision: manualFence.revision, sessionId: manualThread.sessionId });
  await assertAssistantTurnContains(client, manualThread.id, manualBootstrapTurn.turnId, `GENERATION=${manualFence.generation}`);
  summary.stage = "manual_publish";
  const manualPointerMarker = `MANUAL_POINTER_${randomUUID()}`;
  const manualReceipt = await publishClean(manualThread.sessionId, `目标锚点：${manualPointerMarker}\n下一步：完成 Hook v2 E2E`, manualFence.generation, manualFence.revision);
  summary.manual_publish = { schema_version: manualReceipt.schema_version, generation: manualReceipt.generation, revision: manualReceipt.revision };
  summary.stage = "manual_turn";
  const manualPadding = "MANUAL_COMPACT_PADDING ".repeat(1800);
  const manualTurn = await startTurn(client, manualThread.id, `仅回复 ROOT_HOOK_V2_MANUAL_OK。忽略以下填充：${manualPadding}`, 240_000, false);
  const dirty = await readState(manualThread.sessionId);
  if (dirty.status !== "DIRTY" || dirty.revision !== 3) throw new Error("manual thread not DIRTY");
  const beforeManual = JSON.stringify(dirty);
  const compactIndex = client.notifications.length;
  summary.stage = "manual_compact";
  const compactResponse = await client.request("thread/compact/start", { threadId: manualThread.id }, 240_000);
  summary.manual_compact_response = compactResponse == null ? null : { present: true, ...summarizeText(JSON.stringify(compactResponse)) };
  const manualPreCompact = await waitForSuccessfulHook(client, "preCompact", manualThread.id, compactIndex, 60_000);
  if ((manualPreCompact.params?.run?.entries?.length ?? -1) !== 0) throw new Error("manual PreCompact must have entries=0");
  const compactTurnId = manualPreCompact.params?.turnId;
  if (!compactTurnId) throw new Error("manual PreCompact missing compact turn id");
  const manualCompactCompleted = await client.waitFor(turnCompleted(manualThread.id, compactTurnId), compactIndex, 240_000);
  const afterManual = await readState(manualThread.sessionId);
  summary.manual = {
    user_prompt_hook: true,
    pre_compact_hook: true,
    session_start_compact_hook: false,
    state_unchanged: JSON.stringify(afterManual) === beforeManual,
    status: afterManual.status,
    revision: afterManual.revision,
    pre_compact_entries: manualPreCompact.params.run.entries.length,
    compact_session_start_entries: null,
    compact_turn_id_sha256: sha256(compactTurnId),
    compact_turn_completed: manualCompactCompleted.params?.turn?.status === "completed",
  };
  if (!summary.manual.state_unchanged) throw new Error("manual compact changed state");
  const compactContinuation = await startTurn(client, manualThread.id, "只回复恢复上下文中的目标锚点。", 240_000, true);
  const compactContext = hookEntriesText(compactContinuation.sessionStartHook);
  if (!compactContext.includes("TASK_POINTER_V2") || !compactContext.includes(manualPointerMarker)) throw new Error("compact SessionStart missing pointer context");
  summary.manual.session_start_compact_hook = true;
  summary.manual.compact_session_start_entries = compactContinuation.sessionStartHook.params?.run?.entries?.length ?? null;
  await assertAssistantTurnContains(client, manualThread.id, compactContinuation.turnId, manualPointerMarker);

  summary.stage = "resume";
  await client.request("thread/unsubscribe", { threadId: manualThread.id }, 30_000);
  const resumedClient = client;
  const resumedExit = await resumedClient.close();
  if (!resumedExit.ok) throw new Error("app-server exit failed during resume");
  client = newClient();
  await client.request("initialize", {
    clientInfo: { name: "task_pointer_v2_resume", title: "Task Pointer v2 Resume", version: "1.0.0" },
  });
  client.send({ method: "initialized", params: {} });
  await client.request("thread/resume", {
    threadId: manualThread.id,
    cwd: options.cwd,
    approvalPolicy: "never",
    sandbox: "danger-full-access",
  }, 60_000);
  const resumeTurn = await startTurn(client, manualThread.id, "只回复恢复上下文中的目标锚点。", 240_000, true);
  await assertAssistantTurnContains(client, manualThread.id, resumeTurn.turnId, manualPointerMarker);
  summary.resume = { session_start_hook: true, status: (await readState(manualThread.sessionId)).status };

  const clearIndex = client.notifications.length;
  summary.stage = "clear";
  const clearThread = await registerThread((await client.request("thread/start", threadStartParams(options.cwd, "clear"))).thread);
  const clearTurn = await startTurn(client, clearThread.id, "读取本轮 TASK_POINTER_V2_BOOTSTRAP，只回复其中的 STATUS、GENERATION、REVISION、SESSION_ID 和 PUBLISH_CURRENT_POINTER_PATH。", 240_000, true);
  const cleared = await readState(clearThread.sessionId);
  summary.clear = { session_start_hook: true, status: cleared.status, revision: cleared.revision };
  if (cleared.status !== "CLEARED" || cleared.revision !== 2) throw new Error("clear state invalid");
  const clearStartText = hookEntriesText(clearTurn.sessionStartHook);
  for (const [label, value] of [["status", "STATUS=CLEARED"], ["revision", "REVISION=1"], ["session", `SESSION_ID=${clearThread.sessionId}`], ["publisher", `PUBLISH_CURRENT_POINTER_PATH=${E2E_PUBLISHER}`]]) {
    if (!clearStartText.includes(value)) throw new Error(`clear SessionStart entry missing ${label}`);
  }
  assertBootstrapHook(clearTurn.userPromptHook, { status: "CLEARED", generation: cleared.generation, revision: cleared.revision, sessionId: clearThread.sessionId });
  await assertAssistantTurnContains(client, clearThread.id, clearTurn.turnId, `GENERATION=${cleared.generation}`);
  }

  const autoStartIndex = client.notifications.length;
  summary.stage = "auto_thread_start";
  const autoThread = await registerThread((await client.request("thread/start", threadStartParams(options.cwd, "startup", {
    model_auto_compact_token_limit: 12000,
    model_auto_compact_token_limit_scope: "total",
  }))).thread);
  const autoBootstrapTurn = await startTurn(client, autoThread.id, "读取本轮 TASK_POINTER_V2_BOOTSTRAP，只回复其中的 STATUS、GENERATION、REVISION、SESSION_ID 和 PUBLISH_CURRENT_POINTER_PATH。", 240_000, true);
  const autoFence = await readState(autoThread.sessionId);
  if (autoFence.status !== "CLEARED" || autoFence.revision !== 1) throw new Error("auto bootstrap fence invalid");
  assertBootstrapHook(autoBootstrapTurn.sessionStartHook, { status: "ABSENT", generation: "ABSENT", revision: 0, sessionId: autoThread.sessionId });
  assertBootstrapHook(autoBootstrapTurn.userPromptHook, { status: "CLEARED", generation: autoFence.generation, revision: autoFence.revision, sessionId: autoThread.sessionId });
  await assertAssistantTurnContains(client, autoThread.id, autoBootstrapTurn.turnId, `GENERATION=${autoFence.generation}`);
  await publishClean(autoThread.sessionId, "目标：验证 auto compact\n下一步：完成自动压缩 E2E", autoFence.generation, autoFence.revision);
  const padding = "AUTO_COMPACT_PADDING ".repeat(8000);
  summary.stage = "auto_turn";
  await startTurn(client, autoThread.id, `仅回复 ROOT_HOOK_V2_AUTO_SEED_OK。忽略以下填充：${padding}`, 300_000, false);
  const autoSecond = await startTurn(client, autoThread.id, "仅回复 ROOT_HOOK_V2_AUTO_OK", 300_000, false);
  await waitForSuccessfulHook(client, "preCompact", autoThread.id, autoSecond.startIndex, 300_000);
  await waitForSuccessfulHook(client, "sessionStart", autoThread.id, autoSecond.startIndex, 300_000);
  const autoState = await readState(autoThread.sessionId);
  summary.auto = {
    user_prompt_hook: true,
    pre_compact_hook: true,
    session_start_compact_hook: true,
    status: autoState.status,
    revision: autoState.revision,
  };
  if (autoState.status !== "DIRTY" || autoState.revision < 4) throw new Error("auto state invalid");

  summary.stage = "complete";
} catch (error) {
  runError = error;
  summary.stage = "failed";
  summary.error = summarizeError(error);
} finally {
  let deletedThreads = 0;
  const serverExits = [];
  for (const threadId of threadIds) {
    try {
      if (!client) throw new Error("app-server unavailable");
      await client.request("thread/delete", { threadId }, 30_000);
      deletedThreads += 1;
    }
    catch (error) { cleanupErrors.push({ operation: "thread/delete", ...summarizeError(error) }); }
  }
  for (const value of clients) {
    const exit = await value.close();
    serverExits.push(exit);
    if (!exit.ok) cleanupErrors.push({ operation: "app-server/close", ...summarizeError(JSON.stringify(exit)) });
  }
  let removed = 0;
  for (const sessionId of sessions) {
    try { await removeOwnedState(sessionId); removed += 1; }
    catch (error) { cleanupErrors.push({ operation: "state cleanup", ...summarizeError(error) }); }
  }
  const inventoryAfter = await snapshotInventory().catch((error) => {
    cleanupErrors.push({ operation: "state inventory", ...summarizeError(error) });
    return [];
  });
  const otherInventoryUnchanged = JSON.stringify(inventoryWithoutOwned(inventoryBefore, sessions))
    === JSON.stringify(inventoryWithoutOwned(inventoryAfter, sessions));
  if (!otherInventoryUnchanged) cleanupErrors.push({ operation: "other state inventory drift", ...summarizeError("inventory changed") });
  if (threadIds.length !== new Set(threadIds).size) cleanupErrors.push({ operation: "duplicate thread id", ...summarizeError("duplicate thread id") });
  if (deletedThreads !== threadIds.length) cleanupErrors.push({ operation: "thread cleanup count", ...summarizeError("created/deleted thread count mismatch") });
  for (const sessionId of sessions) {
    try { await assertSessionAbsent(sessionId); }
    catch (error) { cleanupErrors.push({ operation: "owned state remains", ...summarizeError(error) }); }
  }
  let stateRootRemoved = false;
  let stateDirectoriesRemoved = 0;
  if (stateRootCreated) {
    for (const directory of createdStateDirectories) {
      try {
        const remaining = await fs.readdir(directory, { withFileTypes: true });
        if (remaining.length === 0) {
          await fs.rmdir(directory);
          stateDirectoriesRemoved += 1;
          if (directory.toLowerCase() === E2E_STATE_ROOT.toLowerCase()) stateRootRemoved = true;
        }
      } catch (error) {
        if (error.code !== "ENOENT") cleanupErrors.push({ operation: "state root cleanup", ...summarizeError(error) });
      }
    }
    const stateRootStillExists = await fs.lstat(E2E_STATE_ROOT).then(() => true).catch((error) => {
      if (error.code !== "ENOENT") cleanupErrors.push({ operation: "state root readback", ...summarizeError(error) });
      return error.code !== "ENOENT";
    });
    stateRootRemoved = !stateRootStillExists;
    if (!stateRootRemoved) {
      cleanupErrors.push({ operation: "state root remains", ...summarizeError("created state root was not removed") });
    }
  }
  summary.cleanup = {
    session_count: sessions.length,
    removed,
    created_threads: threadIds.length,
    deleted_threads: deletedThreads,
    server_closed: clients.every((value) => value.exitResult !== null),
    server_exit_ok: serverExits.every((exit) => exit.code === 0 && !exit.signal && !exit.error),
    server_exit_count: serverExits.length,
    state_root_preexisting: stateRootExistedBefore,
    state_root_created: stateRootCreated,
    state_root_removed: stateRootRemoved,
    state_directories_created: createdStateDirectories.length,
    state_directories_removed: stateDirectoriesRemoved,
    other_state_inventory_unchanged: otherInventoryUnchanged,
    errors: cleanupErrors,
  };
  summary.notifications = clients.flatMap((value) => value.notifications).slice(-120).map((item) => ({
    method: item.method,
    thread_id_sha256: item.params?.threadId ? sha256(item.params.threadId) : null,
    turn_id_sha256: (item.params?.turn?.id ?? item.params?.turnId) ? sha256(item.params.turn?.id ?? item.params.turnId) : null,
    hook_event: item.params?.run?.eventName ?? null,
    hook_status: item.params?.run?.status ?? null,
    warning: item.method === "warning" ? summarizeText(item.params?.message ?? item.params?.warning ?? "") : null,
  }));
  summary.stderr = clients.map((value) => summarizeText(value.stderr));
  summary.inventory = {
    before_entries: inventoryBefore.length,
    after_entries: inventoryAfter.length,
    other_state_inventory_unchanged: otherInventoryUnchanged,
  };
  summary.verdict = runError || cleanupErrors.length > 0 ? "FAIL" : "PASS";
  try {
    await writeReceipt(options.output, summary);
  } catch (error) {
    cleanupErrors.push({ operation: "receipt write", ...summarizeError(error) });
    summary.verdict = "FAIL";
  }
  process.stdout.write(`${JSON.stringify({ verdict: summary.verdict, output: options.output })}\n`);
  if (summary.verdict !== "PASS") process.exitCode = 1;
}
}
