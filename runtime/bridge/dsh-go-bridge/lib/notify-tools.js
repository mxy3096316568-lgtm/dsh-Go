// 通知中枢工具: the phone's notifications the app has read (after the person granted
// 通知使用权), through the app's loopback API. Same endpoint file as the browser tools.
import { readFileSync } from "node:fs";

const CONFIG = "/sdcard/Download/DSH-Go/browser-api.json";
const DEFAULT = { port: 47811, token: "dshgo-local" };

function config() {
  try {
    const parsed = JSON.parse(readFileSync(CONFIG, "utf8"));
    if (parsed && parsed.port && parsed.token) return parsed;
  } catch {}
  return DEFAULT;
}

async function call(path, body, timeoutMs = 20000) {
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

/** Formats one notification as a line the model can quote. */
function line(item) {
  const title = item.title ? `${item.title}：` : "";
  return `[${item.app}] ${item.timeText} ${title}${item.text}`;
}

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
      name: "notify_list",
      description: "列出手机最近收到的通知（新的在前），每条有 app/标题/正文/时间。用户问「有什么通知」「谁找我了」时用它。需要用户先授予通知读取权限。",
      properties: {
        limit: { type: "integer", description: "最多几条，默认 20，最大 200" },
        app: { type: "string", description: "只看某个应用，比如「微信」或包名 com.tencent.mm" },
      },
      execute: async (args) => {
        const result = await call("/notify/list", { limit: args.limit ?? 20, app: args.app });
        if (Array.isArray(result.items)) {
          return { ok: true, items: result.items, lines: result.items.map(line) };
        }
        return result;
      },
    }),
    tool({
      name: "notify_search",
      description: "在最近的通知里按关键词搜（标题、正文、应用名都算）。",
      properties: {
        query: { type: "string", required: true, description: "要找的词" },
        limit: { type: "integer", description: "最多几条，默认 20" },
      },
      execute: async (args) => {
        const result = await call("/notify/search", { query: args.query, limit: args.limit ?? 20 });
        if (Array.isArray(result.items)) {
          return { ok: true, items: result.items, lines: result.items.map(line) };
        }
        return result;
      },
    }),
    tool({
      name: "notify_rule_add",
      description: "加一条通知规则：手机收到含这个关键词的通知时，记一条（record）或者提醒用户（remind）。用户说「帮我盯着快递」「有面试消息提醒我」时用它。规则在本机执行，不走模型。",
      properties: {
        keyword: { type: "string", required: true, description: "要盯的词，比如「快递」「面试」" },
        action: { type: "string", description: "record（只记一条，默认）或 remind（再弹一条提醒）" },
      },
      execute: async (args) => {
        const result = await call("/notify/rule-add", { keyword: args.keyword, action: args.action ?? "record" });
        return result;
      },
    }),
    tool({
      name: "notify_rule_list",
      description: "列出已有的通知规则。",
      execute: () => call("/notify/rules", {}),
    }),
    tool({
      name: "notify_rule_remove",
      description: "删掉一条通知规则（按关键词）。",
      properties: { keyword: { type: "string", required: true, description: "规则里的关键词" } },
      execute: (args) => call("/notify/rule-remove", { keyword: args.keyword }),
    }),
    tool({
      name: "notify_hits",
      description: "看通知规则命中过什么（时间、应用、标题、正文）。用户问「之前盯的那件事有消息吗」时用它。",
      properties: { limit: { type: "integer", description: "最多几条，默认 50" } },
      execute: async (args) => {
        const result = await call("/notify/hits", { limit: args.limit ?? 50 });
        if (Array.isArray(result.items)) return { ...result, lines: result.items.map(line) };
        return result;
      },
    }),
    tool({
      name: "notify_digest",
      description: "按应用汇总最近的通知：每个应用多少条、最新一条是什么，附最近的通知列表。用户说「帮我看看今天有什么消息」「总结一下通知」时先用它。",
      properties: {
        limit: { type: "integer", description: "附带的最近通知条数，默认 40" },
      },
      execute: async (args) => {
        const result = await call("/notify/digest", { limit: args.limit ?? 40 });
        if (Array.isArray(result.items)) {
          return { ...result, lines: result.items.map(line) };
        }
        return result;
      },
    }),
  ];
}

export function registerNotifyTools(ctx) {
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
