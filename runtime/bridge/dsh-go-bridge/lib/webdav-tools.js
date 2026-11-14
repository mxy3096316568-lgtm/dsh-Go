// 云盘工具: the person's own WebDAV drive, driven through the app's loopback API (the app
// holds the account and the keystore password; the engine never sees it).
//
// Same endpoint file as the browser tools (/sdcard/Download/DSH-Go/browser-api.json).
import { readFileSync } from "node:fs";

const CONFIG = "/sdcard/Download/DSH-Go/browser-api.json";
const DEFAULT = { port: 47811, token: "dshgo-local" };

const NOT_SET =
  "还没设置云盘：请用户在 设置 → 帮助与关于 → 能力控制 → 云盘 里填地址、账号和密码，然后重试。";

function config() {
  try {
    const parsed = JSON.parse(readFileSync(CONFIG, "utf8"));
    if (parsed && parsed.port && parsed.token) return parsed;
  } catch {}
  return DEFAULT;
}

async function call(path, body, timeoutMs = 60000) {
  const { port, token } = config();
  const res = await fetch(`http://127.0.0.1:${port}${path}`, {
    method: "POST",
    headers: { "x-dsh-token": token, "content-type": "application/json" },
    body: JSON.stringify(body ?? {}),
    signal: AbortSignal.timeout(timeoutMs),
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
  render: (_args, value) => [{ type: "text", text: JSON.stringify(value, null, 2) }],
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

/** The four cloud tools. Paths are WebDAV paths ("/" is the account's root). */
function definitions() {
  return [
    tool({
      name: "webdav_ls",
      description: "列出云盘上一个目录里的文件和子目录（目录在前，各带 name/path/dir/size/modified）。先 ls 再决定下载或上传到哪。",
      properties: { path: { type: "string", description: "云盘路径，默认 /" } },
      execute: async (args) => {
        const result = await call("/dav/ls", { path: args.path ?? "/" });
        if (result.error === "denied") throw new Error(result.message ?? NOT_SET);
        return result;
      },
    }),
    tool({
      name: "webdav_upload",
      description: "把手机上的一个文件传到云盘。remote 可以是一个目录（以 / 结尾，文件名沿用原文件）或完整的文件路径。上传前先问用户要不要传。",
      properties: {
        local: { type: "string", required: true, description: "手机上的完整路径，例如 /sdcard/Download/report.pdf" },
        remote: { type: "string", required: true, description: "云盘目标，例如 /备份/ 或 /备份/report.pdf" },
      },
      execute: (args) => call("/dav/upload", { local: args.local, remote: args.remote }, 120000),
    }),
    tool({
      name: "webdav_download",
      description: "把云盘上的一个文件下载到手机的 下载/DSH-Go/webdav，返回保存路径和字节数。下载前先问用户。",
      properties: {
        remote: { type: "string", required: true, description: "云盘上的完整文件路径" },
        filename: { type: "string", description: "保存到手机时的文件名，省略则用云端文件名" },
      },
      execute: (args) => call("/dav/download", { remote: args.remote, filename: args.filename }, 180000),
    }),
    tool({
      name: "webdav_search",
      description: "在云盘里按名字搜索文件或目录（从 path 往下三层，最多 400 条）。",
      properties: {
        query: { type: "string", required: true, description: "要找的名字片段，不区分大小写" },
        path: { type: "string", description: "从哪个目录开始找，默认 /" },
      },
      execute: (args) => call("/dav/search", { query: args.query, path: args.path ?? "/" }),
    }),
  ];
}

export function registerWebdavTools(ctx) {
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
