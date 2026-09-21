// PROTOTYPE, wipe me. wayfinder #189 —— 两个常驻 pi SDK session，让一次 git handoff 真的走通。
//
// 跑法见 README.md。要证伪的六条问题也在那里。
// 这是一次性代码：没有测试、没有错误处理、没有抽象。看完结论就扔。

import { createAgentSession, defineTool, SessionManager, ModelRuntime } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const ROOT = process.env.SWARM189_ROOT ?? path.join(os.homedir(), ".swarm-189-scratch");
const STATE = path.join(ROOT, "state.json");
const PENDING = path.join(ROOT, "pending");
const TRACE = path.join(ROOT, "trace.log");

const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const val = (f, d) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : d; };

// --turn: handoff 工具立刻返回，外壳再 prompt() 一次（一张卡一轮）
// 默认:   handoff 工具挂着，下一张卡从它的返回值回来（role 的一生只有一轮）
const MODE = has("--turn") ? "turn" : "hang";
const RESUME = has("--resume");
const AUTO_ANSWER = val("--auto-answer", null);
// settings.json 的默认是 pi-claude/claude-opus-5，但这台机器上 pi-claude 一个模型都没有
// （auth.json 里只有 litellm / xai / openai-codex），所以默认走 litellm 上的 sonnet。
const MODEL_ID = val("--model", "cd-sonnet-4.6");
const PROVIDER = val("--provider", "litellm");

const ROLES = ["coder", "cleaner"];
const cwdOf = (role) => path.join(ROOT, "worktrees", role);

// ---------------------------------------------------------------- 观测

fs.mkdirSync(PENDING, { recursive: true });
const traceFd = fs.openSync(TRACE, "a");
const stamp = () => new Date().toISOString().slice(11, 23);
function say(...a) { console.log(`[${stamp()}]`, ...a); }
function trace(...a) { fs.writeSync(traceFd, `[${stamp()}] ${a.map(String).join(" ")}\n`); }

// ---------------------------------------------------------------- 信箱
// 外壳唯一的调度状态：谁有待处理的卡，谁在挂着等卡。

const inbox = Object.fromEntries(ROLES.map((r) => [r, []]));
const waiting = Object.fromEntries(ROLES.map((r) => [r, null]));

function deliver(role, card) {
  say(`→ ${role} 收到一张卡 (${card.split("\n")[0].slice(0, 60)}…)`);
  const w = waiting[role];
  if (w) { waiting[role] = null; w(card); } else { inbox[role].push(card); }
}

function awaitCard(role) {
  if (inbox[role].length) return Promise.resolve(inbox[role].shift());
  say(`… ${role} 空闲，挂着等下一张卡`);
  return new Promise((res) => { waiting[role] = res; });
}

// ---------------------------------------------------------------- 工具

function handoffTool(self) {
  return defineTool({
    name: "handoff",
    label: "Handoff",
    description:
      "把你刚提交的 commit 交给下一个 role。填 `to` 表示转发；省略 `to` 表示你是链路末端" +
      "（non-forwarding），只结束这一轮。调用之后这个工具会挂着，直到下一张卡到来才返回。",
    parameters: Type.Object({
      to: Type.Optional(Type.String({ description: "收件 role；末端省略不填" })),
      commit: Type.String({ description: "你刚提交的 commit sha" }),
      branch: Type.String({ description: "你的分支名" }),
      task: Type.String({ description: "任务名，原样保留收到的那个" }),
      note: Type.String({ description: "给收件方的一句话" }),
    }),
    execute: async (_id, p) => {
      say(`⇄ ${self} handoff`, JSON.stringify(p));
      trace("HANDOFF", self, JSON.stringify(p));
      if (p.to) {
        deliver(p.to, [
          `任务名：${p.task}`,
          `上游 ${self} 在分支 ${p.branch} 上交来 commit ${p.commit}。`,
          `上游留言：${p.note}`,
          "",
          "先把这个 commit 合并到你的分支，再按下面继续：",
          nextWorkFor(p.to),
        ].join("\n"));
      }
      if (MODE === "turn") {
        return { content: [{ type: "text", text: "已交出。这一轮到此为止。" }], details: {} };
      }
      const next = await awaitCard(self);
      return { content: [{ type: "text", text: `下一张卡：\n${next}` }], details: {} };
    },
  });
}

function askTool(self) {
  return defineTool({
    name: "ask_operator",
    label: "Ask Operator",
    description: "向人类 operator 提一个问题并等回答。遇到歧义时用它，不要自己拍板。",
    parameters: Type.Object({ question: Type.String() }),
    execute: async (id, p) => {
      const file = path.join(PENDING, `${self}-${id}`);
      fs.writeFileSync(`${file}.json`, JSON.stringify({ role: self, question: p.question, asked_at: new Date().toISOString() }, null, 2));
      say(`❓ ${self} 问 operator：${p.question}`);
      say(`   回答办法： echo "你的回答" > ${file}.answer`);
      if (AUTO_ANSWER) setTimeout(() => fs.writeFileSync(`${file}.answer`, AUTO_ANSWER), 1500);
      const answer = await pollFile(`${file}.answer`);
      say(`✓ operator 回答 ${self}：${answer.trim()}`);
      trace("ANSWER", self, answer.trim());
      return { content: [{ type: "text", text: answer.trim() }], details: {} };
    },
  });
}

function pollFile(p) {
  return new Promise((res) => {
    const t = setInterval(() => {
      if (fs.existsSync(p)) { clearInterval(t); res(fs.readFileSync(p, "utf8")); }
    }, 500);
  });
}

// ---------------------------------------------------------------- session

async function makeRole(role, modelRuntime, model, sessionFile) {
  const cwd = cwdOf(role);
  const { session } = await createAgentSession({
    cwd,
    model,
    modelRuntime,
    // 发现 #1：`tools` 白名单一旦给了，**custom tool 也必须列进去**，否则 role 根本看不见它。
    // 第一次跑的时候漏了，cleaner 把 `handoff` 当成 shell 命令去 PATH 里找，然后 `find /Users/admin`
    // 扫整个家目录扫到卡死。doc 里那句「Extension/custom tools remain enabled」只在省略 tools 时成立。
    tools: ["read", "bash", "edit", "write", "handoff", "ask_operator"],
    customTools: [handoffTool(role), askTool(role)],
    sessionManager: sessionFile
      ? SessionManager.open(sessionFile, undefined, cwd)
      : SessionManager.create(cwd),
  });

  session.subscribe((ev) => {
    trace(role, ev.type);
    if (ev.type === "tool_execution_start") say(`  ${role} 用工具 ${ev.toolName ?? "?"}`);
    if (ev.type === "compaction_start") say(`  ⚠ ${role} 开始 compaction`);
    if (ev.type === "turn_end") say(`  ${role} turn_end`);
  });

  say(`● ${role} 起来了  cwd=${cwd}  session=${session.sessionFile ?? "(还没落盘)"}`);
  return session;
}

// ---------------------------------------------------------------- 卡

function nextWorkFor(role) {
  if (role === "cleaner") {
    // 故意写成**猜不出来**的：代号是什么只有 operator 知道。
    // 第一版写的是「风格按我们约定的来」，cleaner 自己拍板了，根本没问 —— 见 README 第 4 条。
    return "合并之后，把 notes.md 里 `coder` 和 `cleaner` 两个词换成我们约定的那两个代号，然后提交。";
  }
  return "继续干。";
}

// 外部投卡口 —— 就是 #186 定的 Dashboard「投任务」那条路的最小形状。
// 往 $ROOT/cards/<role>.txt 写一句话，就唤醒那个挂着的 role。
function watchCardDrops() {
  const dir = path.join(ROOT, "cards");
  fs.mkdirSync(dir, { recursive: true });
  setInterval(() => {
    for (const f of fs.readdirSync(dir)) {
      const role = f.replace(/\.txt$/, "");
      if (!ROLES.includes(role)) continue;
      const p = path.join(dir, f);
      const text = fs.readFileSync(p, "utf8");
      fs.unlinkSync(p);
      say(`✉ 外部投卡给 ${role}`);
      deliver(role, text);
    }
  }, 500).unref();
}

const CARD_CLEANER_SEED = [
  "任务名：seed-cleaner",
  "在 notes.md 末尾加一行 `hello from cleaner`，然后提交。",
  "提交完调 handoff（你是末端，不要填 to），等下一张卡。",
].join("\n");

const CARD_CODER = [
  "任务名：add-greeting",
  "在 notes.md 末尾加一行 `hello from coder`，然后提交。",
  "提交完把这个 commit handoff 给 cleaner。",
].join("\n");

// ---------------------------------------------------------------- 主流程

async function main() {
  say(`模式 ${MODE}${RESUME ? " (resume)" : ""}  root=${ROOT}`);
  if (!fs.existsSync(cwdOf("coder"))) {
    say(`没有 scratch。先跑： bash ${path.join(import.meta.dirname, "scratch.sh")}`);
    process.exit(1);
  }

  const modelRuntime = await ModelRuntime.create();
  const model = modelRuntime.getModel(PROVIDER, MODEL_ID);
  if (!model) { say(`模型 ${PROVIDER}/${MODEL_ID} 没解析到。可用的：`,
    (await modelRuntime.getAvailable()).map((m) => `${m.provider}/${m.id}`).join(" ")); process.exit(1); }
  say(`模型 ${PROVIDER}/${MODEL_ID}`);

  watchCardDrops();
  const saved = RESUME && fs.existsSync(STATE) ? JSON.parse(fs.readFileSync(STATE, "utf8")) : {};
  const sessions = {};
  for (const role of ROLES) sessions[role] = await makeRole(role, modelRuntime, model, saved[role]);

  const persist = () => fs.writeFileSync(STATE, JSON.stringify(
    Object.fromEntries(ROLES.map((r) => [r, sessions[r].sessionFile])), null, 2));

  // 发现 #3：hang 模式下 `prompt()` 永远不返回，所以**没有「一轮结束」这个时机**可以拿来落盘。
  // 外壳必须自己找钩子。session 一建出来 sessionFile 就已经定了（文件还没落盘也一样），
  // 所以在这里存一次就够；真实外壳还要在每次 deliver 之后存调度状态。
  persist();

  // role 的一生：hang 模式下就是一次 prompt()，卡从 handoff 工具的返回值回来。
  // turn 模式下是一张卡一轮，外壳负责再 prompt() 一次。
  async function live(role, firstCard) {
    let card = firstCard;
    for (;;) {
      await sessions[role].prompt(card);
      persist();
      if (MODE !== "turn") return;          // hang 模式下 prompt() 不会正常返回
      card = await awaitCard(role);
    }
  }

  if (RESUME) {
    say("resume：直接给两边各投一张卡，看它们记不记得刚才那一步");
    deliver("cleaner", "接着刚才那一步往下走。你刚才干到哪了？一句话说清楚，然后调 handoff 结束这一轮。");
    const c = live("cleaner", await awaitCard("cleaner"));
    await Promise.race([c, new Promise((r) => setTimeout(r, 180000))]);
    persist();
    return;
  }

  // 1. 先让 cleaner 在同一行上落一个 commit —— 等 coder 交过来时必然冲突（第 5 条）
  const cleanerLife = live("cleaner", CARD_CLEANER_SEED);
  await new Promise((r) => setTimeout(r, 2000));

  // 2. 投卡给 coder
  const coderLife = live("coder", CARD_CODER);

  await Promise.race([
    Promise.all([cleanerLife, coderLife]),
    new Promise((r) => setTimeout(r, 900000)),
  ]);
  persist();
  say("跑完（或超时）。state 在 " + STATE + "，事件流在 " + TRACE);
  for (const role of ROLES) sessions[role].dispose();
}

main().catch((e) => { console.error(e); process.exit(1); });
