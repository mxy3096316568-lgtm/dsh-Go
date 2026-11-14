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
      description: "看 App 内置浏览器当前状态：是否打开、在哪个网址。要处理任何网页任务前先调它。",
      execute: () => call("/state"),
    }),
    tool({
      name: "browser_open",
      description: "在 App 内置浏览器里打开一个网址。凡是需要网页、登录、点按的任务都默认用它，不必等用户指定；页面会在用户面前自动出现。",
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
      name: "browser_js",
      description: "在当前标签里执行一段你现写的 JavaScript（可 await、可 fetch、可读写 localStorage）。用它一步取数据，别用几十次点击硬点；结果按 JSON 返回，超过 32KB 截断。副作用：脚本能改页面、能用登录态发请求。",
      properties: {
        code: { type: "string", required: true, description: "要执行的脚本，直接写语句，最后的表达式或 return 值会作为结果" },
        timeoutMs: { type: "integer", description: "超时毫秒，默认 10000，最大 30000" },
      },
      execute: (args) => call("/js", { code: args.code, timeoutMs: args.timeoutMs ?? 10000 }),
    }),
    tool({
      name: "browser_download",
      description: "下载一个文件到手机的 下载/DSH-Go 目录，下载完成才返回。下载前先问用户是否要存到手机。",
      properties: {
        url: { type: "string", required: true, description: "文件的完整网址" },
        filename: { type: "string", description: "保存的文件名，省略则用网址末段" },
      },
      execute: (args) => call("/download", { url: args.url, filename: args.filename }),
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
