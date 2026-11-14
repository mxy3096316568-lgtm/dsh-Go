// v1.4 host capabilities (docs/design/native-plugins-protocol.md §13): data the plugin cannot
// see from the host (the session in the app's memory, what the person selected) and actions only
// the app can take (fill the composer, post a notification, register a schedule). Always a round
// trip: plugin → bridge → app over the stream → answer. Nothing is sent unless the app negotiated
// the capability in `hello`, the plugin declared it, and the app allowed this plugin to use it.
//
// Two kinds:
//   - data:   the app runs it and answers with a value (sessionText, selection, schedule).
//   - action: the app runs it and answers ok (send, notify).
//   - permit: the app only decides; the bridge does the work (phone, tools, pluginFiles), because
//     the work happens on the host (a phone MCP tool runs in this process, plugin files live here).
import { AsyncLocalStorage } from "node:async_hooks";
import { randomBytes } from "node:crypto";
import { mkdir, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { HOST_FEATURES, HOST_LIMITS as L } from "./capabilities.js";
import { errorText, isPlainObject, utf8Bytes, withTimeout } from "./util.js";

/** A refusal the plugin can read: `error.code` is one of unsupported / denied / timeout / limit / bad-request / unavailable. */
export class HostError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const ID = /^[A-Za-z0-9_-]{1,64}$/;
const TOOL_NAME = /^[A-Za-z0-9_.:-]{1,96}$/;
const FILE_MAX = 1024 * 1024;
const PERMIT = new Set(["phone", "tools", "pluginFiles"]);
/** Capabilities whose arguments are validated here, before anything reaches the app. */
const PAYLOAD = {
  sessionText: (a) => ({ limit: clampInt(a.limit, 1000, 60000, 12000) }),
  selection: () => ({}),
  send: (a) => ({ text: needText(a.text, 4000, "send.text") }),
  notify: (a) => ({
    title: needText(a.title, 120, "notify.title"),
    text: needText(a.text, 600, "notify.text"),
    ...(a.attention === true ? { attention: true } : {}),
  }),
  schedule: (a) => ({
    title: needText(a.title, 120, "schedule.title"),
    prompt: needText(a.prompt, 4000, "schedule.prompt"),
    rrule: needText(a.rrule, 500, "schedule.rrule"),
  }),
  phone: (a) => ({ tool: needTool(a.tool, true), args: plainArgs(a.args) }),
  tools: (a) => ({ tool: needTool(a.tool, false), args: plainArgs(a.args) }),
  pluginFiles: (a) => {
    const op = a.op;
    if (!["read", "write", "list", "delete", "stat"].includes(op)) throw new HostError("bad-request", "pluginFiles.op must be read, write, list, delete or stat");
    const out = { op };
    if (op === "list") return out;
    out.path = needRelPath(a.path);
    if (op === "write") out.text = needText(a.text, FILE_MAX, "pluginFiles.text");
    return out;
  },
};

const clampInt = (v, min, max, fallback) => (Number.isInteger(v) ? Math.min(max, Math.max(min, v)) : fallback);
function needText(value, maxChars, name) {
  if (typeof value !== "string" || value.length === 0) throw new HostError("bad-request", `${name} must be a non-empty string`);
  if ([...value].length > maxChars) throw new HostError("too-large", `${name} is longer than ${maxChars} characters`);
  return value;
}
function needTool(value, phoneOnly) {
  if (typeof value !== "string" || !TOOL_NAME.test(value)) throw new HostError("bad-request", "tool must be a tool name");
  if (phoneOnly && !value.startsWith("mcp__phone__")) throw new HostError("bad-request", "phone only calls mcp__phone__* tools");
  return value;
}
function plainArgs(value) {
  if (value === undefined) return {};
  if (!isPlainObject(value)) throw new HostError("bad-request", "args must be an object");
  const json = JSON.stringify(value);
  if (utf8Bytes(json) > 2048) throw new HostError("too-large", "args are larger than 2 KiB");
  return JSON.parse(json);
}
/** A relative path inside the plugin's data directory: no absolutes, no `..`, no NUL. */
function needRelPath(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > 512) throw new HostError("bad-request", "path must be a 1-512 character string");
  if (value.includes("\0") || isAbsolute(value)) throw new HostError("denied", "path must be relative to the plugin data directory");
  const clean = value.replaceAll("\\", "/");
  if (clean.split("/").some((part) => part === "..")) throw new HostError("denied", "path must not leave the plugin data directory");
  return clean;
}

export class HostRuntime {
  constructor(core, { dataRoot } = {}) {
    this.core = core;
    this.delivery = new AsyncLocalStorage();
    this.pending = new Map();
    this.dataRoot = dataRoot ?? join(process.env.DSH_HOME?.trim() || join(homedir(), ".dsh"), "dsh-go", "plugins");
    core.host = this;
  }

  dispose() {
    for (const e of [...this.pending.values()]) this.settle(e, false, { code: "unavailable", message: "bridge stopped" });
    this.delivery.disable();
    if (this.core.host === this) this.core.host = undefined;
  }

  /** Runs one tapped action with the connection it came from, so `capability()` can find it. */
  run(entry, fn) {
    return this.delivery.run(entry, fn);
  }

  /** A `host.res` from the app: resolves the matching request. Unknown ids are ignored. */
  answer(conn, msg) {
    if (msg.t !== "host.res") return false;
    const e = this.pending.get(msg.id);
    if (e === undefined) return true;
    if (e.conn !== conn) return true;
    const ok = msg.ok === true;
    const value = ok ? msg.value : undefined;
    if (ok) {
      const json = value === undefined ? "{}" : JSON.stringify(value);
      if (utf8Bytes(json) > e.capLimit.responseBytes) {
        this.settle(e, false, { code: "too-large", message: "the app's answer was larger than this capability allows" });
        return true;
      }
    }
    this.settle(e, ok, ok ? value : {
      code: typeof msg.code === "string" && /^[a-z-]{2,40}$/.test(msg.code) ? msg.code : "denied",
      message: typeof msg.message === "string" ? msg.message.slice(0, 200) : "the app refused",
    });
    return true;
  }

  /** The socket went: every request on it is refused, not left hanging. */
  drop(conn) {
    for (const e of [...this.pending.values()]) if (e.conn === conn) this.settle(e, false, { code: "unavailable", message: "the app disconnected" });
  }

  settle(e, ok, data) {
    if (this.pending.get(e.id) !== e) return;
    this.pending.delete(e.id);
    clearTimeout(e.timer);
    if (!ok && data?.code === "timeout") this.core.violation(e.pkg, "timeout", `capability(${e.cap}) timed out`);
    if (ok) e.resolve(data);
    else e.reject(new HostError(data.code, data.message));
  }

  /**
   * A plugin asking for [cap]. Returns the app's value (data), `true` (action), or the
   * work's result (permit). Throws [HostError] when refused.
   */
  async capability(pkg, cap, args) {
    if (typeof cap !== "string" || !HOST_FEATURES.includes(cap)) throw new HostError("unsupported", `unknown capability ${String(cap).slice(0, 32)}`);
    const entry = this.delivery.getStore();
    if (entry === undefined || entry.pkg !== pkg) {
      throw new HostError("unavailable", `${cap} can only be used while a tapped action is running`);
    }
    const rec = this.core.plugin(pkg);
    if (rec === undefined || this.core.stateOf(rec) !== "ok" || rec.uid !== entry.uid || rec.stamp !== entry.stamp) {
      throw new HostError("unavailable", "this plugin changed while the action was running");
    }
    if (!(rec.parsed.capabilities ?? []).includes(cap)) {
      throw new HostError("unsupported", `${cap} is not declared in this plugin's dshGo.capabilities`);
    }
    const conn = entry.conn;
    if (conn === undefined || !conn.helloed || conn.ws.closed || !conn.features?.includes(cap)) {
      throw new HostError("unsupported", `${cap} was not negotiated by this app`);
    }
    if (args !== undefined && !isPlainObject(args)) throw new HostError("bad-request", "arguments must be an object");
    const capLimit = L.caps[cap];
    const payload = PAYLOAD[cap](args ?? {});
    if (PERMIT.has(cap)) payload.summary = summarize(cap, payload);
    if (utf8Bytes(JSON.stringify(payload)) > L.payloadBytes) throw new HostError("too-large", "the request is larger than 4 KiB");
    const inflight = [...this.pending.values()].filter((e) => e.conn === conn).length;
    if (inflight >= L.perConn) throw new HostError("limit", `at most ${L.perConn} host requests at once`);
    const value = await this.ask(conn, pkg, cap, payload, capLimit.timeoutMs, entry.scope?.scope ?? {});
    if (!PERMIT.has(cap)) return value === undefined ? true : value;
    switch (cap) {
      case "pluginFiles":
        return this.files(pkg, payload);
      case "phone":
        return this.runTool(packTool(payload), capLimit.timeoutMs);
      case "tools":
        return this.runTool(packTool(payload), capLimit.timeoutMs);
      default:
        return true;
    }
  }

  ask(conn, pkg, cap, payload, timeoutMs, scope) {
    return new Promise((resolvePromise, reject) => {
      const id = randomBytes(12).toString("base64url");
      const e = {
        id, conn, pkg, cap,
        capLimit: L.caps[cap],
        resolve: resolvePromise,
        reject,
        timer: setTimeout(() => this.settle(e, false, { code: "timeout", message: `no answer within ${timeoutMs} ms` }), timeoutMs),
      };
      e.timer.unref?.();
      this.pending.set(id, e);
      try {
        conn.send({ t: "host.req", id, cap, pkg, scope, payload });
      } catch (error) {
        this.settle(e, false, { code: "unavailable", message: errorText(error) });
      }
    });
  }

  // ── pluginFiles: the one writable place a plugin owns ─────────────────────

  pluginDir(pkg) {
    return join(this.dataRoot, pkg.replaceAll("/", "%2F"), "data");
  }

  filePath(pkg, rel) {
    const root = this.pluginDir(pkg);
    const target = resolve(root, rel);
    const back = relative(root, target);
    if (back === "" || back.startsWith("..") || isAbsolute(back) || back.split(sep).includes("..")) {
      throw new HostError("denied", "path must stay inside the plugin data directory");
    }
    return target;
  }

  async files(pkg, payload) {
    const root = this.pluginDir(pkg);
    try {
      switch (payload.op) {
        case "list": {
          await mkdir(root, { recursive: true });
          const entries = await readdir(root, { withFileTypes: true });
          return { ok: true, dir: root, entries: entries.slice(0, 200).map((d) => ({ name: d.name, dir: d.isDirectory() })) };
        }
        case "stat": {
          const info = await stat(this.filePath(pkg, payload.path));
          return { ok: true, path: payload.path, bytes: info.size, modified: info.mtimeMs, dir: info.isDirectory() };
        }
        case "read": {
          const target = this.filePath(pkg, payload.path);
          const info = await stat(target);
          if (!info.isFile()) throw new HostError("bad-request", "not a file");
          if (info.size > FILE_MAX) throw new HostError("too-large", "plugin data files are at most 1 MiB");
          const bytes = await readFile(target);
          return { ok: true, path: payload.path, bytes: bytes.length, text: bytes.toString("utf8") };
        }
        case "write": {
          const target = this.filePath(pkg, payload.path);
          if (utf8Bytes(payload.text) > FILE_MAX) throw new HostError("too-large", "plugin data files are at most 1 MiB");
          await mkdir(dirname(target), { recursive: true });
          await writeFile(target, payload.text, "utf8");
          return { ok: true, path: payload.path, bytes: utf8Bytes(payload.text) };
        }
        case "delete": {
          const target = this.filePath(pkg, payload.path);
          await rm(target, { recursive: false, force: true });
          return { ok: true, path: payload.path, deleted: true };
        }
        default:
          throw new HostError("bad-request", "unknown op");
      }
    } catch (error) {
      if (error instanceof HostError) throw error;
      if (error?.code === "ENOENT") throw new HostError("not-found", "no such file in the plugin data directory");
      throw new HostError("failed", `plugin files: ${errorText(error)}`);
    }
  }

  // ── phone / tools: run one engine tool, after the app allowed it ──────────

  async runTool(payload, timeoutMs) {
    const tools = this.core.ctx?.get?.("tools");
    if (tools === undefined || typeof tools.execute !== "function") {
      throw new HostError("unsupported", "this host has no tool executor");
    }
    const call = { id: `host-${randomBytes(6).toString("hex")}`, name: payload.tool, arguments: JSON.stringify(payload.args ?? {}) };
    let batch;
    try {
      batch = await withTimeout(Promise.resolve(tools.execute({ calls: [call] })), timeoutMs);
    } catch (error) {
      if (error?.timeout) throw new HostError("timeout", `${payload.tool} did not finish in ${timeoutMs} ms`);
      throw new HostError("failed", `${payload.tool}: ${errorText(error)}`);
    }
    const result = batch?.results?.[0]?.result;
    const text = (result?.content ?? [])
      .filter((part) => part?.type === "text" && typeof part.text === "string")
      .map((part) => part.text)
      .join("\n")
      .slice(0, 32768);
    return { ok: result?.isError !== true, tool: payload.tool, text, isError: result?.isError === true };
  }
}

const packTool = (payload) => ({ tool: payload.tool, args: payload.args });

function summarize(cap, payload) {
  if (cap === "phone" || cap === "tools") {
    let args = "";
    try {
      args = JSON.stringify(payload.args ?? {});
    } catch {
      args = "";
    }
    return `${payload.tool} ${args}`.slice(0, 300);
  }
  return `${payload.op} ${payload.path ?? ""}`.slice(0, 300);
}
