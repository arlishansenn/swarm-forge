# pi SDK 常驻 session 能不能撑住一个 role

研究对象：`@earendil-works/pi-coding-agent`（已安装运行时版本 `0.86.1`，`pi --version` 核验）。
本机 `/Users/admin/workspace/pi-mono`（`badlogic/pi-mono`，包名 `@mariozechner/pi-coding-agent`，
`0.54.2`）版本落后安装版本 32 个次版本号，且包名/组织都已改名（mariozechner → earendil-works）。
**凡是两处冲突，以 npm 包 `dist/*.js`（即实际运行的 0.86.1）为准**；本机源码只在与 npm dist
一致时作为补充引用。下文每条结论标注具体来源。

---

## 1. 耐久性

**结论**：session.jsonl 在“会话已经出现过至少一条 assistant 消息”之后，是逐条 `appendFileSync`
同步落盘，无缓冲、无 debounce；这之后进程 `kill -9`，已经落盘的轮次不会丢。但**在第一条 assistant
回复出现之前，什么都不落盘——连 session 文件本身都不存在**。SDK 没有 idle timeout、TTL 或 token
预算上限会主动杀掉/回收一个长期存活的 session。

证据（`node_modules/@earendil-works/pi-coding-agent/dist/core/session-manager.js`，0.86.1）：
- `newSession()`（行 646-671）：创建 session 时只计算 `sessionFile` 路径，`flushed = false`，
  不写任何文件。
- `_persist(entry)`（行 740-769）：
  ```js
  const hasAssistant = this.fileEntries.some(e => e.type === "message" && e.message.role === "assistant");
  if (!hasAssistant) {
      if (this.flushed) appendFileSync(...);
      else { this.flushed = false; return; }   // 缓冲在内存，不落盘
  }
  if (!this.flushed) { /* 用 "wx" 独占创建，一次性把内存里攒的全部条目写盘 */ }
  else appendFileSync(this.sessionFile, ...);   // 之后每条都是同步追加
  ```
  即：session 里出现第一条 assistant 消息之前的所有条目（header、第一条 user 消息）都只在内存
  里，`_persist` 直接 `return`；第一条 assistant 消息落地的那一刻才用 `openSync(file, "wx")` 把
  攒的条目一次性写盘，此后转为逐条 `appendFileSync`。
- `_setSessionFile()`（行 620-645）：`SessionManager.open()`/`continueRecent()` 打开已存在文件时
  `this.flushed = true`，所以“已经有过对话”的 session 从恢复的那一刻起就是逐条同步落盘，没有第
  1 条的窗口期问题。

Pi.dev `sessions` 文档（<https://pi.dev/docs/latest/sessions>）：“Sessions auto-save to
`~/.pi/agent/sessions/`, organized by working directory.” 文档未提及落盘时机颗粒度、idle 回收、
token 预算上限——**这些细节文档未提及**，以上是源码里查到的实际行为，比文档更细。

超时/回收：
- `settings-manager.d.ts`/`.js` 里唯一与“idle”“timeout”相关的字段是 `httpIdleTimeoutMs`
  （默认 `300_000` ms，`http-dispatcher.js:3` `DEFAULT_HTTP_IDLE_TIMEOUT_MS = 300_000`）——这是
  **HTTP 传输层连接空闲超时**，不是 session 对象的存活时间，session 本身没有对应字段。
- 没有 `maxTokens`/`budget`/`maxTurns` 之类会强制终止 session 的设置；唯一会主动处理“上下文太大”
  的机制是 compaction（见第 3 条），它是摘要+截断，不是终止。

## 2. resume 的保真度

**结论**：`SessionManager.open(path)`/`continueRecent(cwd)` 完整重放消息树（含 tool_use/
tool_result），并从 transcript 里恢复 model 和 thinking level（除非调用方显式传参覆盖）；但
**system prompt 不是从 session.jsonl 恢复的**，而是每次 `createAgentSession()` 用当前磁盘上的
resourceLoader（AGENTS.md/skills/工具清单等）重新生成的；进程崩在“工具已调用、结果还没落盘”的
窗口内会留下悬空的 tool_use，没有对应处理逻辑的证据。

证据（`sdk.js`，0.86.1，行 75-138）：
```js
const existingSession = sessionManager.buildSessionContext();
// model: 显式传参优先；否则从 existingSession.model（model_change 条目）恢复
if (!model && hasExistingSession && existingSession.model) {
    const restoredModel = modelRuntime.getModel(...);
    if (restoredModel && modelRuntime.hasConfiguredAuth(...)) model = restoredModel;
}
// thinkingLevel 同理：显式传参优先，否则从 thinking_level_change 条目恢复
let thinkingLevel = options.thinkingLevel;
if (thinkingLevel === undefined && hasExistingSession) {
    thinkingLevel = hasThinkingEntry ? existingSession.thinkingLevel : ...;
}
```
即：**调用方传入的新参数会覆盖旧值**（`createAgentSession({ model, sessionManager: SessionManager.open(...) })`
里的 `model` 一旦给了就赢）。

工具调用历史：`SessionEntry` 类型（`session-manager.d.ts:23-119`）里消息就是普通
`AgentMessage`（含 tool_use/tool_result），`buildSessionContext()`/`buildContextEntries()`
（`session-manager.d.ts:172-178`）按树路径重放，正常情况下历史是完整的。但类型定义里**没有
“pending tool result”这种状态**——一次工具调用的 tool_use 和它的 tool_result 是否已经落盘取决于
第 1 条的落盘规则；如果进程恰好崩在“LLM 已经吐出 tool_use、工具正在跑、tool_result 还没产生”这
个窗口，session.jsonl 里会有一条不完整的 tool_use（如果当时 session 已经 flushed，则这条 tool_use
本身可能已经落盘，但对应的 tool_result 缺失）。**pi-agent-core 对这种悬空 tool_use 在下一次请求时
如何处理，源码未深入到那一层确认**——标记为“未查实”。

系统提示词：`CreateAgentSessionOptions` 没有把 system prompt 存进 `session.jsonl` 的常规路径；
唯一逐字保存 system prompt 的地方是 `CompactionEntry.systemMessage`——“Complete prompt and tool
state at this compaction boundary”（`session-manager.d.ts:57-58`），这是 compaction 时的一次性快
照，用于该次摘要的审计/重建，**不是** resume 时自动套用的东西。正常 resume 路径下，system prompt
由 `DefaultResourceLoader`（读当前磁盘上的 AGENTS.md/skills/工具清单）在每次 `createAgentSession()`
时重新拼装（`sdk.js:76-79` `resourceLoader.reload()`）。也就是说：**同一个 role 三天里如果
AGENTS.md 被改过，resume 后用的是新版 system prompt，不是三天前那个**——这对 swarm-forge 是好事
（改文档不用重启六个 role），但意味着“resume=完全冻结重放”这个假设不成立。

另有 `agent-session.js:844-856` 的 `_restoreToolsFromTranscript()`：从 transcript 里最近一次系统
消息记录的 `toolsAdded` 恢复“当时激活的工具集合”，但只在这些工具名仍在当前 `_toolRegistry` 里时
生效（按名字过滤），细节未继续深挖。

## 3. compaction

**结论**：compaction 自动触发（两种条件：`overflow` 和 `threshold`），可以整体关闭（手动 `/compact`
仍可用），触发后原始消息对 LLM **不再可见**（只剩摘要文本进入上下文），但原始条目物理上仍留在
`.jsonl` 文件里没删除。对“上一个 role 交给我什么”这类精确记忆，compaction 之后是有实质性损伤的
——模型看到的只是它自己生成的摘要，不是原文。

触发条件（`agent-session.js`，0.86.1）：
- `threshold`：`shouldCompact(contextTokens, contextWindow, settings)` → `compaction/index.js`
  的判据是 `contextTokens > contextWindow - reserveTokens`（对应 pi.dev `compaction` 文档原文一致）。
  检查点：工具执行完之后、新 user prompt 之前、agent 一轮跑完之后（`agent-session.js:287-290`,
  `908`, `1004`, `1752-1843`）。
- `overflow`：provider 实际报了上下文溢出错误（`isContextOverflow`），先把溢出的那条 assistant
  回复摘掉，再 compact，再重试（`agent-session.js:1783-1813`）。
- 手动：`session.compact(customInstructions?)`，对应 `/compact [instructions]`
  （`agent-session.d.ts:541-556`）。

默认阈值（`settings-manager.js`）：
```js
const DEFAULT_COMPACTION_TOKEN_SETTINGS = { reserveTokens: 16384, keepRecentTokens: 20000 };
```
可按模型覆盖（`CompactionSettings.modelOverrides`，`settings-manager.d.ts:4-12`）。与 pi.dev
`compaction` 文档给出的示例配置一致。

关闭方式：`session.setAutoCompactionEnabled(false)` 或 `settings.compaction.enabled = false`
（`agent-session.d.ts:570-572`）；pi.dev 文档明确“Manual `/compact` commands remain available”，
即关自动不等于关手动。可通过扩展的 `session_before_compact` 事件拦截/替换摘要或取消这次 compaction
（pi.dev `compaction` 文档 + `SessionBeforeCompactEvent`/`SessionBeforeCompactResult` 类型，
`extensions/index.d.ts` 导出）。

数据保留（`CompactionEntry`，`session-manager.d.ts:46-59`）：`summary`（LLM 生成的摘要文本）+
`firstKeptEntryId`（该 ID 之后的原始条目仍逐字保留在上下文里）+ `tokensBefore`。
`buildContextEntries()`（`session-manager.d.ts:164-172`）明确写着：“the latest compaction is
represented by the compaction entry itself, followed by the kept entries starting at
firstKeptEntryId... **Older summarized entries are omitted**”——omitted 是指从**送给 LLM 的上下
文**里拿掉，不是从磁盘文件删除；`.jsonl` 文件本身是 append-only 树结构，原始条目物理上还在，人工
或脚本可以在文件里找回，但模型自己在下一轮拿到的只有摘要。

## 4. 并发上限

**结论**：SDK 层面没有进程内多 session 的并发调度、连接池或限流；一个 `AgentSession`/`Agent` 内部
一次只能处理一条 prompt（串行），但多个独立 `AgentSession` 实例之间完全没有协调，各自直接对
provider 发请求。文档和源码都没有给出“进程内开 N 个 session”的硬上限数字。

证据：
- `@earendil-works/pi-agent-core/dist/agent.js:337`：`throw new Error("Agent is already
  processing.")`——单个 Agent 实例（对应一个 AgentSession）一次只能有一个 in-flight prompt，第二
  个必须走 `steer()`/`followUp()` 排队，不是并发执行。这是**单 session 内**的限制，与“进程内开
  N 个 session”无关。
- 搜索 `pi-coding-agent`/`pi-agent-core`/`pi-ai` 全部 `dist/*.js`：没有找到 `Semaphore`、
  `maxConcurrent`、连接池、或任何“进程级”并发协调代码——每个 `createAgentSession()` 都是独立对象，
  独立持有自己的 `ModelRuntime`/HTTP 请求。
- 唯一和“反复请求失败”相关的节流是 provider 重试：`RetrySettings`/`ProviderRetrySettings`
  （`settings-manager.d.ts:18-29`），默认 `maxRetries: 3`、`baseDelayMs: 2000`
  （`settings-manager.js:620-622`）——这是失败后的退避重试，不是主动限流。
- pi.dev `security` 文档（<https://pi.dev/docs/latest/security>）和 `usage` 文档都**未提及**并发
  会话数上限或资源隔离建议；`security` 文档明确说 pi 本身“没有内置沙箱，是设计选择”，多进程/多
  session 的资源隔离是调用方（这里是 swarm-forge）的责任。

结论落地到“六个 role 的 six-pack 跑不跑得动”：**SDK 不会替你限流，真正的天花板来自 provider 的
rate limit 和宿主机的内存/文件句柄/网络连接数**，这几项文档都没有给数字，只能靠 swarm-forge 自己
压测拿经验值。

## 5. 成本

**结论**：prompt cache 是自动的，不需要调用方显式开启；每个 session 独立计费、独立统计，SDK 不提
供跨 session/跨进程的成本汇总，六个常驻 role 的总成本需要 swarm-forge 自己在应用层加一层汇总。

证据（`@earendil-works/pi-ai/dist/api/anthropic-messages.js`，0.86.1）：
- 默认 retention 是 `"short"`（可用 `PI_CACHE_RETENTION=long` 环境变量或按请求传
  `cacheRetention` 切到 1 小时 TTL 的 ephemeral cache）：
  ```js
  // 行 19-38: resolveCacheRetention() 默认 "short"，getCacheControl() 返回
  // { type: "ephemeral", ttl?: "1h" }
  ```
- 自动打在：system prompt/工具定义的最后一块（行 791, 823-840）、以及最后一条 user/历史消息块
  （行 1107-1127，注释原文“Add cache_control to the last user or system message to cache
  conversation history”）——**调用方不用手动传 `cache_control`，SDK 内部按 `sessionId` 自动加**。
- `CacheWarmer` 类（`cache-warmer.d.ts`）：在 cache 条目快过期前，用“重放同一请求 + 1 token 输出
  上限”的方式主动续命，决策依据是期望收益 `expectedSavings = continuationProbability * missCost
  - warmCost` ≥ 0.05 美元才会真的发一次续命请求（`CacheWarmingDecision`,
  `cache-warmer.d.ts:23-37`）。是否启用由 `settings.cacheWarming`
  （`"off" | "streaming" | "idle"`，`settings-manager.d.ts:52-54`）控制，`"idle"` 模式会在 agent
  不跑的时候也续，这对“长期挂着等 handoff”的常驻 role 是直接相关的成本旋钮，默认值文档/源码里没标
  出全局默认（只看到类型定义，未继续深挖 `SettingsManager.getCacheWarmingMode()` 的兜底值，标记
  为“未查实默认值，只查实机制本身”）。
- Token 用量：不是通过事件流广播的（`AgentSessionEvent` 列表里没有 usage/cost 专门事件，
  `agent-session.d.ts:41-102`），需要主动调用 `session.getSessionStats()`
  （`agent-session.d.ts:176-194, 679-683`）拿聚合值，且明确说明“Aggregates over ALL session
  entries (including history that was compacted away)”——即使原文被摘要掉了，账单口径上的 token
  数还在。**这只是单个 session 内的聚合，没有跨 session 的成本 API**。
- pi.dev `usage` 文档只提到 TUI 底部栏会显示 token/cache/cost，没有给出跨轮复用率或计算方法的具
  体数字——**文档未提及**，以上比例判断（0.05 美元阈值、short/long 两档 TTL）来自源码。

## 6. 工具注入

**结论**：`tools` 白名单和 `customTools` 都会被同一套 `isAllowedTool()` 过滤——**`tools` 一旦给
定，就是全量工具（含内置和自定义/扩展）的唯一允许清单，不在名单里的一律被逐出注册表**，不是只
筛内置工具。自定义工具的 `execute()` 是普通 `Promise`，可以任意时长挂起（例如等外部事件），SDK
不加超时包装，只提供 `AbortSignal` 做协作式取消。

证据（`agent-session.js:2207-2262`，0.86.1）：
```js
const isAllowedTool = (name) =>
    (!allowedToolNames || allowedToolNames.has(name)) && !excludedToolNames?.has(name);
const allCustomTools = [...registeredTools, ...this._customTools.map(...)]
    .filter(tool => isAllowedTool(tool.definition.name));       // 自定义工具也过这层
const definitionRegistry = new Map(
    Array.from(this._baseToolDefinitions.entries())
        .filter(([name]) => isAllowedTool(name))                 // 内置工具也过这层
        .map(...)
);
```
即 `tools: ["my_handoff_tool"]` 这种只写自定义工具名的配置，会把 `read`/`bash`/`edit`/`write`
等默认内置工具**从注册表里整个排除**，不只是不激活——这是对 issue 原文“能不能完全替掉默认工具集”
的直接确认：**能**。

`sdk.js:142-145`（0.86.1）：
```js
const allowedToolNames = options.tools ?? (options.noTools === "all" ? [] : undefined);
const excludedToolNames = options.excludeTools;
const initialActiveToolNames = (options.tools ?? (options.noTools ? [] : (configuredDefaultToolNames ?? defaultActiveToolNames)))
    .filter(name => !excludedToolNameSet?.has(name));
```
`noTools: "builtin"` 只在**没有传 `tools`** 时才生效，效果是内置工具不进初始激活集合，但自定义/
扩展工具仍然可用（对应 `sdk.d.ts:26-33` 的官方注释）；一旦传了 `tools`，`noTools` 的这条分支就不
会被走到。`excludeTools` 是在 `tools`/默认集合算出来之后再做一次减法（denylist），两者可以叠加用。

长挂起工具（`extensions/types.d.ts:345-378`，0.86.1）：
```ts
execute(toolCallId, params, signal: AbortSignal | undefined,
        onUpdate: AgentToolUpdateCallback<TDetails> | undefined,
        ctx): Promise<AgentToolResult<TDetails>>;
```
类型定义里没有 `timeoutMs` 字段，`agent-session.js` 里安装工具钩子的逻辑（`_installAgentToolHooks`,
`agent-session.d.ts:254-262`）也没有对这个 Promise 包一层超时——**源码没有内置超时机制**，`signal`
是取消通道（`session.abort()`/`dispose()`/用户中断时触发），`onUpdate` 是流式进度回调。
`executionMode?: "sequential" | "parallel"`（`types.d.ts:364-371`）让某个工具声明自己能否和同一
轮里的其它工具调用并发跑，默认策略未继续深挖。

落到“等一个 handoff 进来”这种工具：**架构上可行**——`execute()` 就是一个可以挂几十分钟甚至几小
时的 `Promise`；但整个挂起期间，这个 session 处于“仍在跑一轮”的状态（`Agent` 不认为自己 idle，
`agent.js:238` 的单飞检查仍然生效），同一个 session 上再 `prompt()` 会被拒绝/需要走
`steer()`/`followUp()` 排队，**不会阻塞其它独立 session**。SDK 本身不会替你超时掐断，需要自己在
工具实现里加时间上限。

## 7. 退出与清理

**结论**：`abort()` 只中止当前这一轮运行（LLM 流 + 工具 + compaction/重试），等到 idle 后 session
仍可继续用；`dispose()` 在 0.86.1 里其实是“先整体 abort 一遍，再拆监听器、拆 cache warmer、清理
provider 侧的连接资源”，比表面上的“摘监听器”重得多。**没有专门的“暂停但不丢”中间态 API**——不调
用 `dispose()` 本身就是事实上的暂停，session 对象和它订阅的资源会一直挂在内存里，直到进程退出或
你显式 dispose。

证据（`agent-session.js`，0.86.1）：
```js
// 行 608-627: dispose()
dispose() {
    try {
        this.abortRetry(); this.abortCompaction(); this.abortBranchSummary();
        this.abortBash(); this.agent.abort();
    } catch { /* Dispose must succeed even if an abort hook throws. */ }
    this._extensionRunner.invalidate(...);
    this._disconnectFromAgent();
    this._eventListeners = [];
    if (this._cacheWarmer) { this._cacheWarmer.onWarmed = undefined; this._cacheWarmer.cancel(); }
    cleanupSessionResources(this.sessionId);   // 来自 @earendil-works/pi-ai/compat
}
// 行 1334-1343: abort()
async abort() {
    if (this._isAgentRunActive) this._agentRunAbortRequested = true;
    this.abortRetry(); this.abortCompaction(); this.abortBranchSummary();
    this.agent.abort();
    await this.waitForIdle();
}
```
（本机 `pi-mono` 0.54.2 源码里的 `dispose()` 明显更简单，只摘监听器；这是版本漂移的一个实例，
说明查这类生命周期语义必须以已安装的 0.86.1 dist 为准，不能只看本机 checkout。）

`session.jsonl` 在 dispose 之后：**不写任何结束标记**，文件原样留在磁盘上；下次
`SessionManager.open(同一路径)` 或 `continueRecent(同一 cwd)` 可以直接接着往后追加——这正是
swarm-forge 现在靠 `ready_for_next.sh` 手工实现、SDK 这边原生就有的能力。

`AgentSession` 的公开方法里（`agent-session.d.ts` 全量方法列表）没有 `pause()`/`detach()`/
`reattach()` 之类的方法——“暂停但不丢”这件事，实践上就是“别调用 `dispose()`，把 session 对象攥在
手里，也别再 `prompt()`”，此时唯一还在后台悄悄花钱的是 `cacheWarmingMode: "idle"` 时的 CacheWarmer
定时续命请求（见第 5 条），其余（HTTP 连接、订阅）都是被动挂起、不产生流量。

---

## 对常驻 role 的适配判断

**硬约束**（SDK 的既定事实，spec 只能绕开，改不了）：

1. 一个 session 一次只能处理一条 prompt，session 内部天然串行（`agent.js:337`）；role 内部想要
   “边思考边接收新指令”，必须走 `steer()`/`followUp()` 排队，不能假设并发 in-flight turn。
2. session.jsonl 的第一条 assistant 回复出现之前完全不落盘，连文件都不存在（`session-manager.js`
   `_persist`）——role 刚启动、还没等到第一条 LLM 回复就被杀，这一轮什么都留不下。
3. compaction 之后，原始消息对 LLM **不可见**，只剩它自己生成的摘要——不能指望 session 记忆完整
   保真地承载“上一个 role 交给我什么”这类精确 handoff 内容超过一次 compaction 周期。
4. system prompt 不是从 session.jsonl 恢复的，是每次启动用当前磁盘内容（AGENTS.md/skills）重新
   生成的——“resume”不等于“环境冻结重放”。
5. SDK 不做进程内多 session 的并发调度/限流/连接池，六个 role 的并发上限由 provider rate limit
   和宿主机资源决定，SDK/文档都不给数字。
6. 工具 `execute()` 没有内置超时，只有协作式 `AbortSignal`；长挂起工具（等 handoff）架构上可行，
   但超时/心跳要 swarm-forge 自己实现。
7. 没有“暂停但不丢”的专门 API；唯一的暂停手段是“不调用 dispose()、也不再 prompt()”。

**设计约束**（需要 swarm-forge 自己拍板、写进 spec 的，不是 SDK 逼的）：

1. Role 不能完全依赖 session 记忆做跨天/跨 compaction 边界的记忆，仍然要保留现在 tmux 版本“每轮
   从 Board 和 git 重读事实”的习惯，session 记忆只当“最近上下文缓存”用。
2. Role 重启应该用 `SessionManager.continueRecent(cwd)` 而不是每次新建 session，并且要接受
   “resume 后 system prompt 会按当前磁盘内容重新生成”这件事——这对多 role 同步 AGENTS.md 更新其
   实是好事，不用手动重启六个 role，但要在 spec 里写清楚这是预期行为，不是 bug。
3. 需要在 swarm-forge 侧补一层“进程收到第一条 assistant 回复之前”的落盘保险（类似现在
   `ready_for_next.sh` 的 pending 标记文件），弥补 session.jsonl 的第一轮空窗期，这是 SDK 不会替
   你做的事。
4. six-pack 的并发上限要靠压测拿经验值，不能从文档或源码反推出一个数字；同时要评估是否需要在
   swarm-forge 层加一个跨进程的限流层（SDK 完全没有）。
5. 是否给常驻 role 开 `cacheWarmingMode: "idle"` 是一个成本/恢复速度的权衡，需要在 spec 里显式写
   默认值和开关条件，不要静默继承 pi 的默认设置。
6. customTools + tools 白名单可以完全替掉默认工具集这件事，为“等 handoff 进来”这类专用工具打开了
   干净的实现路径（不用担心 read/bash 等默认工具干扰），但 timeout/心跳/取消语义要自己设计，SDK
   只给了 `AbortSignal` 这一个原语。
