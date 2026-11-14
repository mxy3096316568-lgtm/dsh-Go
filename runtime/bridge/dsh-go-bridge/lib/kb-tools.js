// 知识库工具: 用户自己的资料，检索结果带来源。走 App 的本机接口（同 browser-api.json）。
import { readFileSync } from "node:fs";

const CONFIG = "/sdcard/Download/DSH-Go/browser-api.json";
const DEFAULT = { port: 47811, token: "dshgo-local" };
const EMPTY =
  "知识库还是空的：让用户把文件放进 下载/DSH-Go/知识库/，或用 kb_import 导入，然后重试。";

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
  if (json.error === "denied") throw new Error(json.message);
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

function definitions() {
  return [
    tool({
      name: "kb_search",
      description: "在用户自己的知识库（下载/DSH-Go/知识库 里的文档）里按关键词检索，返回命中的片段和来源路径。回答用户问题时先搜这里，引用原文并给出文档路径；搜不到就直说没找到，不要编。",
      properties: {
        query: { type: "string", required: true, description: "要找的内容，中文直接写，不用分词" },
        limit: { type: "integer", description: "最多几条，默认 8" },
      },
      execute: async (args) => {
        const result = await call("/kb/search", { query: args.query, limit: args.limit ?? 8 });
        if (result.ok && (!result.hits || result.hits.length === 0)) {
          const stats = await call("/kb/stats", {});
          return { ...result, note: `${EMPTY}（现在有 ${stats.docs ?? 0} 个文档、${stats.chunks ?? 0} 块）` };
        }
        return result;
      },
    }),
    tool({
      name: "kb_read",
      description: "读知识库里某个块或它的上下文（用 kb_search 返回的 doc 和 chunk）。需要完整上下文时 chunk 加减一各读一次。",
      properties: {
        doc: { type: "string", required: true, description: "kb_search 返回的 doc 路径" },
        chunk: { type: "integer", description: "块序号，默认 0" },
      },
      execute: (args) => call("/kb/read", { doc: args.doc, chunk: args.chunk ?? 0 }),
    }),
    tool({
      name: "kb_import",
      description: "把手机上的一个文件导入知识库（会复制进 下载/DSH-Go/知识库 并建索引）。支持 txt/md/html/csv/json/docx；PDF 暂不支持。导入前先问用户。",
      properties: { path: { type: "string", required: true, description: "手机上的完整路径" } },
      execute: (args) => call("/kb/import", { path: args.path }, 120000),
    }),
    tool({
      name: "kb_stats",
      description: "看知识库现状：多少文档、多少块、占多少空间、超时跳过了多少文件。",
      execute: () => call("/kb/stats", {}),
    }),
  ];
}

export function registerKbTools(ctx) {
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
