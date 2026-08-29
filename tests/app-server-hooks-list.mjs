import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import path from "node:path";

const sha256 = (value) => createHash("sha256").update(String(value), "utf8").digest("hex");

function requireAbsolutePath(value, name) {
  if (typeof value !== "string" || value.length === 0 || !path.isAbsolute(value)) {
    throw new Error(`${name} 必须是绝对路径`);
  }
  return path.resolve(value);
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

function hookEventName(hook) {
  return hook?.eventName ?? hook?.event_name ?? null;
}

function hookCommand(hook) {
  return hook?.command ?? hook?.commandWindows ?? null;
}

function taskPointerDefinitionKind(hook) {
  const command = hookCommand(hook);
  const handlerType = hook?.handlerType ?? hook?.handler_type ?? null;
  if ((handlerType !== null && handlerType !== "command") || typeof command !== "string") return "other";
  if (!/task-pointer-lifecycle\.ps1/i.test(command)) return "other";
  return "task-pointer";
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
    if (!["--cwd", "--output", "--codex-home", "--app-server-command"].includes(key) || !value) {
      throw new Error("用法：--cwd ABS --output ABS [--codex-home ABS] [--app-server-command COMMAND] [--require-trusted]");
    }
    values[key.slice(2)] = value;
    index += 1;
  }
  if (!values.cwd || !values.output) {
    throw new Error("cwd 和 output 必须是绝对路径");
  }
  const cwd = requireAbsolutePath(values.cwd, "cwd");
  const output = requireAbsolutePath(values.output, "output");
  const codexHomeRaw = values["codex-home"] ?? cwd;
  const codexHome = requireAbsolutePath(codexHomeRaw, "codex-home");
  return {
    cwd,
    output,
    codexHome,
    appServerCommand: resolveAppServerCommand(values["app-server-command"]),
    requireTrusted,
  };
}

class AppServer {
  constructor(cwd, codexHome, command) {
    const [executable, ...args] = splitCommandLine(command);
    this.child = spawn(executable, args, {
      cwd,
      env: { ...process.env, CODEX_HOME: codexHome },
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
      shell: false,
    });
    this.buffer = "";
    this.nextId = 1;
    this.pending = new Map();
    this.stderr = "";
    this.exitResult = null;
    this.exitPromise = new Promise((resolve) => { this.resolveExit = resolve; });
    this.child.stdout.on("data", (chunk) => this.consume(chunk.toString("utf8")));
    this.child.stderr.on("data", (chunk) => { this.stderr += chunk.toString("utf8"); });
    this.child.stdin.on("error", () => {});
    this.child.on("error", (error) => {
      this.exitResult = { code: null, signal: null, error: error.message };
      this.resolveExit(this.exitResult);
      for (const pending of this.pending.values()) pending.reject(error);
      this.pending.clear();
    });
    this.child.on("exit", (code) => {
      if (!this.exitResult) this.exitResult = { code, signal: null };
      this.resolveExit(this.exitResult);
      for (const pending of this.pending.values()) pending.reject(new Error(`app-server exit ${code}`));
      this.pending.clear();
    });
  }

  consume(chunk) {
    this.buffer += chunk;
    while (this.buffer.includes("\n")) {
      const newline = this.buffer.indexOf("\n");
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (!line) continue;
      let message;
      try { message = JSON.parse(line); } catch { continue; }
      if (typeof message.id !== "number" || !this.pending.has(message.id)) continue;
      const pending = this.pending.get(message.id);
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(JSON.stringify(message.error)));
      else pending.resolve(message.result);
    }
  }

  request(method, params, timeoutMs = 30_000) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      if (this.exitResult) {
        reject(new Error("app-server unavailable"));
        return;
      }
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} 超时`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (value) => { clearTimeout(timer); resolve(value); },
        reject: (error) => { clearTimeout(timer); reject(error); },
      });
      try {
        this.child.stdin.write(`${JSON.stringify({ method, id, params })}\n`);
      } catch (error) {
        this.pending.delete(id);
        clearTimeout(timer);
        reject(error);
      }
    });
  }

  notify(method, params) {
    if (this.exitResult) return;
    try { this.child.stdin.write(`${JSON.stringify({ method, params })}\n`); } catch {}
  }

  async close() {
    if (!this.exitResult) {
      try { this.child.stdin.end(); } catch {}
      const timeout = new Promise((resolve) => setTimeout(() => resolve({ forced: true }), 5_000));
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
    return this.exitResult ?? { code: null, signal: "timeout", forced: true };
  }
}

function sanitizeHook(hook) {
  return {
    event_name: hookEventName(hook),
    enabled: hook.enabled ?? null,
    trust_status: hook.trustStatus ?? hook.trust_status ?? null,
    source_sha256: hook.source ? sha256(hook.source) : null,
    matcher: hook.matcher ?? null,
    timeout_sec: hook.timeoutSec ?? hook.timeout_sec ?? null,
    handler_type: hook.handlerType ?? hook.handler_type ?? null,
    command_sha256: sha256(hookCommand(hook) ?? ""),
    definition_kind: taskPointerDefinitionKind(hook),
  };
}

const rawArgs = process.argv.slice(2);
let options = null;
let parseError = null;
try { options = parseArgs(rawArgs); }
catch (error) { parseError = error; }

function rawOutputPath(argv) {
  for (let index = 0; index < argv.length - 1; index += 1) {
    if (argv[index] === "--output" && path.isAbsolute(argv[index + 1])) return path.resolve(argv[index + 1]);
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
    schema_version: 1,
    generated_at: new Date().toISOString(),
    protocol: "initialize -> initialized -> hooks/list",
    read_only: true,
    cleanup: { threads_created: 0, threads_deleted: 0, state_files_created: 0, server_closed: true },
    verdict: "FAIL",
    error: summarizeError(parseError),
  };
  if (output) {
    try { await writeReceipt(output, report); } catch {}
  }
  process.stderr.write("hooks/list 参数无效；详见 JSON receipt\n");
  process.exitCode = 1;
} else {
const report = {
  schema_version: 1,
  generated_at: new Date().toISOString(),
  protocol: "initialize -> initialized -> hooks/list",
  cwd_sha256: sha256(options.cwd),
  codex_home_sha256: sha256(options.codexHome),
  app_server_command_sha256: sha256(options.appServerCommand),
  require_trusted: options.requireTrusted,
  read_only: true,
  cleanup: { threads_created: 0, threads_deleted: 0, state_files_created: 0, server_closed: false },
  verdict: "FAIL",
};
let server;
let failure;
try {
  server = new AppServer(options.cwd, options.codexHome, options.appServerCommand);
  await server.request("initialize", { clientInfo: { name: "control_plane_hooks_list", title: "只读 Hook 列表探针", version: "1.0.0" } });
  server.notify("initialized", {});
  const result = await server.request("hooks/list", { cwds: [options.cwd] });
  const row = result?.data?.[0] ?? {};
  const hooks = Array.isArray(row.hooks) ? row.hooks : [];
  report.hooks = {
    count: hooks.length,
    enabled: hooks.filter((hook) => hook.enabled === true).length,
    trusted: hooks.filter((hook) => hook.trustStatus === "trusted").length,
    error_count: Array.isArray(row.errors) ? row.errors.length : null,
    warning_count: Array.isArray(row.warnings) ? row.warnings.length : null,
    items: hooks.map(sanitizeHook),
  };
  const targetItems = report.hooks.items.filter((item) => item.definition_kind === "task-pointer");
  const eventNames = new Set(targetItems.map((item) => item.event_name));
  const requiredEvents = ["preCompact", "sessionStart", "userPromptSubmit"];
  const missingEvents = requiredEvents.filter((eventName) => !eventNames.has(eventName));
  report.hooks.target_count = targetItems.length;
  if (missingEvents.length > 0 || report.hooks.error_count !== 0 || report.hooks.warning_count !== 0) {
    throw new Error("hooks/list 目标定义缺失、结构无效或包含诊断");
  }
  if (options.requireTrusted && targetItems.some((item) => item.trust_status !== "trusted")) {
    throw new Error("目标 Hook 尚未全部信任；请在 Codex /hooks 中完成审阅");
  }
  report.verdict = "PASS";
} catch (error) {
  failure = error;
  report.error = summarizeError(error);
} finally {
  if (server) {
    const exit = await server.close();
    report.stderr_sha256 = sha256(server.stderr);
    report.stderr_byte_count = Buffer.byteLength(server.stderr, "utf8");
    report.cleanup.server_closed = !exit.forced && (exit.code !== null || Boolean(exit.signal) || Boolean(exit.error));
    report.cleanup.server_exit = {
      ok: exit.code === 0 && !exit.signal && !exit.error,
      code: Number.isInteger(exit.code) ? exit.code : null,
      signal: exit.signal ?? null,
      error: exit.error ? summarizeError(exit.error) : null,
    };
    if (!report.cleanup.server_exit.ok) {
      if (!failure) failure = new Error("app-server close failed");
      report.verdict = "FAIL";
    }
  }
  await writeReceipt(options.output, report);
}
if (failure) {
  process.stderr.write("hooks/list 失败；详见 JSON receipt\n");
  process.exitCode = 1;
} else {
  process.stdout.write(`${JSON.stringify({ verdict: report.verdict, output: options.output })}\n`);
}
}
