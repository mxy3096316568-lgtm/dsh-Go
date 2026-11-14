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
          const docs = stats.docs ?? 0;
          const chunks = stats.chunks ?? 0;
          // 空命中分两种：知识库本来空着（该放文件），还是有文档但没有这个词。
          // 以前两种情况都回 EMPTY，于是「有 3 个文档」和「知识库还是空的」一起出现。
          const note = docs === 0
            ? EMPTY
            : `没有找到包含「${args.query}」的文档（当前 ${docs} 个文档、${chunks} 块）。` +
              "换个关键词、少写几个字试试，或用 kb_stats 看看收了哪些文件。";
          return { ...result, note };
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
    tool({
      name: "web_crawl",
      description:
        "抓网页正文存进知识库，之后用 kb_search 检索（长文章、系列页、要反复查的资料适合这样存）。只抓用户给的这个站：同域、限深限量、遵守 robots.txt、页间有间隔。要登录态或用 JS 渲染的页面把 render 设为 true（会用内置浏览器逐页打开，慢）。抓完自动入库，只更新内容变了的页。不要拿它批量镜像整个网站。",
      properties: {
        url: { type: "string", required: true, description: "起始网址" },
        depth: { type: "integer", description: "往下跟几层链接：0 只抓这一页，默认 1，最大 3" },
        limit: { type: "integer", description: "最多抓几页，默认 10，上限 30" },
        same_domain: { type: "boolean", description: "只抓同一个站点，默认 true" },
        render: { type: "boolean", description: "用内置浏览器渲染（需要登录态或页面靠 JS 出内容），默认 false" },
      },
      execute: (args) =>
        call(
          "/kb/crawl",
          {
            url: args.url,
            depth: args.depth ?? 1,
            limit: args.limit ?? 10,
            same_domain: args.same_domain ?? true,
            render: args.render ?? false,
          },
          240000,
        ),
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
