// 一句话流程：把刚做过的一串操作写成一份技能，下次一句话就能复用。
//
// 技能就是 `$DSH_HOME/skills/<名字>/SKILL.md`（和用户自己写的技能同一个地方、同一个格式），
// 所以“存下来”不需要新机制：写文件 + 引擎下一次加载技能时就会看到。
// 只写技能目录，不碰别的；名字做白名单校验，不允许跳出 skills/。
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const NAME = /^[a-z0-9][a-z0-9-]{1,47}$/;
const MAX_STEPS = 24;

function skillsDir() {
  const home = process.env.DSH_HOME || join(homedir(), ".dsh");
  return join(home, "skills");
}

function oneLine(text) {
  return String(text ?? "").replace(/\s+/g, " ").trim();
}

function render({ name, description, steps }) {
  const body = steps.map((step, index) => `${index + 1}. ${step}`).join("\n");
  return [
    "---",
    `name: ${name}`,
    `description: ${oneLine(description)}`,
    "---",
    "",
    `# ${oneLine(description)}`,
    "",
    "## 怎么用",
    "",
    "用户说一句差不多的话时，按下面这几步做；中间需要用户拿主意的地方先问一句。",
    "",
    "## 步骤",
    "",
    body,
    "",
    "## 注意",
    "",
    "- 这是从一次真实操作里记下来的流程，环境变了就按实际情况调整，别死守。",
    "- 花钱、删除、对外发送这三类动作，每次都要用户确认。",
    "",
  ].join("\n");
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
      name: "skill_save",
      description:
        "把刚才做成的一串操作存成一个技能：下次用户说一句差不多的话，就能照这份技能重做。写的是 $DSH_HOME/skills/<名字>/SKILL.md，和用户自己写的技能同一个地方。只在用户说「存成技能 / 下次也这么做」时用；存之前先在对话里把步骤给他看一眼，他同意再调这个工具。名字用英文小写加连字符。",
      properties: {
        name: { type: "string", required: true, description: "技能名：小写字母、数字、连字符，例如 book-flight-check" },
        description: {
          type: "string",
          required: true,
          description: "一句话说明什么时候用它（会写进 description，模型靠它决定要不要加载）",
        },
        steps: {
          type: "array",
          required: true,
          description: "按顺序的步骤，每步一句话，写清用什么工具、看什么、遇到什么要问用户",
          items: { type: "string" },
        },
      },
      execute: async (args) => {
        const name = oneLine(args.name).toLowerCase();
        if (!NAME.test(name)) {
          return { ok: false, error: "bad_name", message: "名字只能用小写字母、数字和连字符，2～48 个字符" };
        }
        const description = oneLine(args.description);
        if (!description) return { ok: false, error: "description_required" };
        const steps = Array.isArray(args.steps)
          ? args.steps.map(oneLine).filter((step) => step.length > 0).slice(0, MAX_STEPS)
          : [];
        if (steps.length === 0) return { ok: false, error: "steps_required" };
        const dir = join(skillsDir(), name);
        const file = join(dir, "SKILL.md");
        try {
          mkdirSync(dir, { recursive: true });
          writeFileSync(file, render({ name, description, steps }), "utf8");
          return { ok: true, name, path: file, steps: steps.length, note: "下次对话开始时会加载；让用户看一眼内容再确认。" };
        } catch (error) {
          return { ok: false, error: "write_failed", message: String(error?.message ?? error) };
        }
      },
    }),
    tool({
      name: "skill_list",
      description: "列出这台手机上已有的技能（名字、一句话说明）。想删某个技能用 skill_remove。",
      execute: async () => {
        const dir = skillsDir();
        if (!existsSync(dir)) return { ok: true, skills: [] };
        const skills = [];
        for (const entry of readdirSync(dir, { withFileTypes: true })) {
          if (!entry.isDirectory()) continue;
          const file = join(dir, entry.name, "SKILL.md");
          if (!existsSync(file)) continue;
          let description = "";
          try {
            const head = readFileSync(file, "utf8").slice(0, 2000);
            const match = /^description:\s*(.+)$/m.exec(head);
            if (match) description = match[1].trim();
          } catch {}
          skills.push({ name: entry.name, description });
        }
        skills.sort((a, b) => a.name.localeCompare(b.name));
        return { ok: true, skills };
      },
    }),
    tool({
      name: "skill_remove",
      description: "删掉一个技能（整目录）。只在用户明确要删时用；删之前把技能名念给他确认。",
      properties: {
        name: { type: "string", required: true, description: "skill_list 给出的技能名" },
      },
      execute: async (args) => {
        const name = oneLine(args.name).toLowerCase();
        if (!NAME.test(name)) return { ok: false, error: "bad_name" };
        const dir = join(skillsDir(), name);
        if (!existsSync(dir)) return { ok: false, error: "not_found" };
        try {
          rmSync(dir, { recursive: true, force: true });
          return { ok: true, name, removed: true };
        } catch (error) {
          return { ok: false, error: "remove_failed", message: String(error?.message ?? error) };
        }
      },
    }),
  ];
}

export function registerSkillTools(ctx) {
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
