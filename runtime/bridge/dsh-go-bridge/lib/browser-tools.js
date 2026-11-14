// 浏览器工具: the app's in-app browser, reached over its loopback API. Registered from this
// bundle so they ship with the runtime (no separate plugin to install).
//
// The app writes { port, token } to the shared folder; without that file the defaults below
// are used, which is also what the app falls back to.
import { readFileSync } from "node:fs";

const CONFIG = "/sdcard/Download/DSH-Go/browser-api.json";
const DEFAULT = { port: 47811, token: "dshgo-local" };

const CLOSED = "App 的浏览器页面没有打开：请用户点输入框旁的地球图标打开浏览器，再重试。";

function config() {
  try {
    const parsed = JSON.parse(readFileSync(CONFIG, "utf8"));
    if (parsed && parsed.port && parsed.token) return parsed;
  } catch {}
  return DEFAULT;
}

async function call(path, body) {
  const { port, token } = config();
  const res = await fetch(`http://127.0.0.1:${port}${path}`, {
    method: body ? "POST" : "GET",
    headers: { "x-dsh-token": token, "content-type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(15000),
  });
  let json = {};
  try {
    json = await res.json();
  } catch {}
  if (!res.ok) throw new Error(json.error ?? `http ${res.status}`);
  return json;
}

const OUT = {
  schema: { type: "object", additionalProperties: true },
  render: (_args, value) => [
    {
      type: "text",
      text: typeof value?.text === "string" ? value.text : JSON.stringify(value, null, 2),
    },
  ],
};

function tool(spec) {
  const properties = spec.properties ?? {};
  const required = Object.keys(properties).filter((key) => properties[key].required);
  const clean = {};
  for (const [key, value] of Object.entries(properties)) {
    const { required: _required, ...rest } = value;
    clean[key] = rest;
  }
  return {
    name: spec.name,
    description: spec.description,
    parameters: { type: "object", properties: clean, required, additionalProperties: false },
    output: OUT,
    execute: spec.execute,
  };
}

/** The six tools, in the order the model should reach for them. */
function definitions() {
  return [
    tool({
      name: "browser_state",
      description: "看 App 内置浏览器当前状态：是否打开、在哪个网址。",
      execute: () => call("/state"),
    }),
    tool({
      name: "browser_open",
      description: "在 App 内置浏览器里打开一个网址。浏览器页面没打开时返回 browser_closed。",
      properties: { url: { type: "string", required: true, description: "完整网址，https:// 开头" } },
      execute: async (args) => {
        const result = await call("/open", { url: args.url });
        if (result.error === "browser_closed") throw new Error(CLOSED);
        return result;
      },
    }),
    tool({
      name: "browser_read",
      description: "读 App 内置浏览器当前页面的正文文字（最多两万字）。",
      execute: () => call("/read"),
    }),
    tool({
      name: "browser_snapshot",
      description: "列出当前页面上可点的元素，每项带编号 ref 和文字。点按和填表都用这个编号。",
      execute: () => call("/snapshot"),
    }),
    tool({
      name: "browser_click",
      description: "点击页面上编号为 ref 的元素（编号来自 browser_snapshot）。",
      properties: { ref: { type: "integer", required: true, description: "browser_snapshot 给出的编号" } },
      execute: (args) => call("/click", { ref: args.ref }),
    }),
    tool({
      name: "browser_type",
      description: "往编号为 ref 的输入框里填文字（编号来自 browser_snapshot）。",
      properties: {
        ref: { type: "integer", required: true, description: "browser_snapshot 给出的编号" },
        text: { type: "string", required: true, description: "要填进去的文字" },
      },
      execute: (args) => call("/type", { ref: args.ref, text: args.text }),
    }),
  ];
}

/**
 * Registers the browser tools on the tools service and answers the disposer.
 * A tool that is already registered (the standalone plugin installed too) is
 * skipped rather than failing the whole bridge.
 */
export function registerBrowserTools(ctx) {
  const disposers = [];
  for (const definition of definitions()) {
    try {
      disposers.push(ctx.tools.register(definition));
    } catch (error) {
      if (!/already registered/.test(String(error?.message))) throw error;
    }
  }
  return () => {
    for (const dispose of disposers.splice(0)) {
      try {
        dispose();
      } catch {}
    }
  };
}
