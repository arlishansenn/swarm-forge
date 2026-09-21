# Dashboard 四件事 × pi 原生机制对照（issue #183）

调研范围：<https://pi.dev/docs/latest>（`rpc`、`sdk`、`extensions`、`tui`、`usage`）、
`~/.pi/agent/npm/node_modules/pi-subagents/docs/`（v0.70.0，经与
`nicobailon/pi-subagents` 的 CHANGELOG 核对，是当前发布的最新版）、
`/Users/admin/workspace/pi-mono/`（本机 pi 源码）、以及本仓
`swarmforge/scripts/pack_web.bb` / `pack_dashboard_request.bb` 作为 swarm-forge
侧的对照物。

**重要前提**：pi-subagents 的所有原生协作机制（`contact_supervisor`、
`subagent_supervisor`、`steer`/`follow_up`）都建立在「一个 pi 进程用
`subagent`/`runs.run` 把另一个 pi session 作为**子进程/子 session** 拉起」这个
父子关系上。swarm-forge 现状（`pack_web.bb`）是反过来的：每个 role 是 tmux 里独立
起的顶层 pi 进程，operator 靠 `send-keys!` 往 pane 里"打字"、靠正则扫 pane 文本
判断状态——role 和 operator 之间**没有**这层 pi 父子关系。下面标"原生"的机制，
默认前提是 swarm-forge 把 role 接到一个 dispatcher/lieutenant pi session 的子级下
（`MEMORY.md` 里已经在考虑的方向）；只要还是当前的纯 tmux 架构，这些原生机制就够
不到 role，等于"没有"。这一点在每一行的证据栏里都标了出来。

## 对照表

| Dashboard 的事 | pi 的候选机制 | 原生 / 要自己写 / 没有 | 证据位置 |
|---|---|---|---|
| **1. 澄清**（role 卡住时问 operator，不在 pane 里问） | `contact_supervisor({reason:"need_decision"｜"interview_request"})`（子→父）+ `subagent_supervisor({action:"reply"｜"pending"})`（父→子） | **原生，但仅当 role 是 pi 子 session 时**；swarm-forge 现状仍需自己写（文件轮询） | `~/.pi/agent/npm/node_modules/pi-subagents/docs/workflows.md:486-522`（"Supervisor coordination (child asks parent)"节，含 reason 三选项与 reply/pending 用法）。swarm-forge 现状见 `swarmforge/scripts/pack_dashboard_request.bb:145-165`（`clarify!`/`create-clarification!`：role 写 `.request` 文件到 `.swarmforge/dashboard/clarifications/pending/`，operator 用 `answer` 写回，纯文件轮询，无进程间信道） |
| **2. 批准 gate**（到点停下等人点头） | 无对应的"人工点头"原生机制；`acceptance` 是自动化证据 gate，不是人工 gate（见下方"acceptance 到底是什么"） | **没有**——pi-subagents 没有"暂停等人类按一下确认"的内建 API | `tool-reference.md:380-468`（Acceptance gates 全节，见下方展开）。pi.dev `/usage` 页面搜索 acceptance/approval 无结果（`--approve`/`-a` 只是项目信任开关，见该页）。swarm-forge 现状见 `swarmforge/scripts/pack_web.bb`（`pending-approval-ids`/`pending-approval-names`/`approvals`，第 338-350、521 行附近，文件目录当审批队列） |
| **3. 投任务**（operator 把新卡放上 Board） | 子 session 未启动时：`subagent`/`runs.run` 直接起一个新 child；子 session 已在跑时：`subagent({action:"steer", mode:"follow_up"｜"steer", message})` 或 `runs.steer(key, message, {mode})` | **原生，同样受父子关系限制** | `tool-reference.md:105,149-153,330-378`（`steer`/`follow_up`/`auto` 三种投递模式的定义与语义；`follow_up`="等下一个 turn 边界再处理"，`steer`="打断当前 turn"）。swarm-forge 现状见 `swarmforge/scripts/pack_web.bb:138-167`（`inject-role!`/`inject-master!`：`send-keys!` 直接把文本当按键序列打进 tmux pane，等价于人对着终端打字，不是结构化消息） |
| **4. 看状态**（每个 role 在干什么、卡在哪条 lane） | `subagent({action:"status", view:"fleet"})`（无 TUI 也能用的文本 fallback）+ 落盘的 `status.json` | **原生**，且是可编程的（见下方 FleetView 展开），与 role 是否为 pi 子 session 无关——只要 role 本身是被 pi-subagents 启动/追踪的 run | `observability.md:80-123`（FleetView 一节）、`observability.md:123`（"Without a TUI, `/subagents-fleet` retains the textual `subagent({ action: "status", view: "fleet" })` fallback"）、`observability.md:181-193`（`status.json` 落盘路径 `<tmpdir>/pi-subagents-<scope>/async-subagent-runs/<id>/status.json`）。swarm-forge 现状见 `swarmforge/scripts/pack_web.bb:314-335`（`pane-status-for`/`im-status`：正则扫 tmux pane 最近几行文本分类句子，猜测状态，不是结构化数据） |

## 逐条展开

### 这四件各自映到哪个机制（确切 API + 文档位置）

已在表格证据栏给出。补充两点表格放不下的细节：

- `contact_supervisor` 的三个 `reason` 值——`need_decision`（阻塞性决策/澄清）、
  `interview_request`（结构化输入）、`progress_update`（非阻塞的进度更新）——直接
  对应 Dashboard 想要的"澄清"语义中的前两种；`progress_update` 对应的其实是"看状态"
  里主动推送的那一半（被动扫描之外，子 session 也能主动汇报）。
  （`workflows.md:500-506`）
- `subagent_supervisor` 的回复是**会话作用域**的："Supervisor messages are scoped
  to the exact Pi session id that spawned the child. A second Pi session in the
  same repository does not receive those requests."（`workflows.md:508`）。这意味着
  如果 swarm-forge 想用这条原生通道，"operator" 必须落在**那个具体的父 session**
  里操作，不能是随便一个能访问仓库的进程——这对 Dashboard（一个独立的 HTTP/UI
  进程）是个硬约束，天然不满足。

### 哪几件没有原生对应物，必须自己写；最小形状是什么

**必须自己写的是「批准 gate」，且不管 role 架构怎么改都得写**——pi-subagents 里
没有"运行到某一步，暂停，等一个人类在带外点确认"的 API。`acceptance` 是自动化证据
校验（见下节），`review: {required:true, agent:"reviewer"}` 是让另一个 agent 复核，
两者都不引入人类介入点。pi.dev 的 `/usage`、`/tui`、`/rpc`、`/sdk` 四页搜索
approval/acceptance/gate 均未提及人工确认工作流。

最小形状（ponytail 版本，不是设计文档）：

- 不需要新起一个 HTTP server——swarm-forge 已经有一条能用的、role 和 operator
  都认识的信道：`pending-approval-ids`/`approvals` 这条文件队列（`pack_web.bb`
  已有）。批准 gate 缺的不是通道，是"role 侧怎么等"：让 role 在到达 gate 点时调用
  一个 custom tool（比如 `pack_dashboard_request.sh approve <summary>`），语义等价于
  `clarify`——写一个 pending 文件然后**轮询等待**对应的 done 文件出现（or 直接让
  role 自己 block 在一个 `while not exists done; sleep N` 上，这正是 `clarify`
  现在的实现路子，抄它就够）。
- 如果 role 之后真的迁移成某个 dispatcher pi session 的子级，`contact_supervisor`
  的 `need_decision` reason 可以**直接复用**来承载批准请求（阻塞、原生、不用等
  文件轮询）——但这是原生 + 自己定义语义（"blocked" answer 约定成"批准"/"打回"），
  不是纯原生，所以仍然记在"要自己写"里，写的是**协议层**（reply 里 message 是
  approve 还是 reject 需要 role 侧自己解析），不是传输层。

其余三件（澄清、投任务、看状态）在"role 是 pi 子 session"的前提下都有原生对应，
不需要另起炉灶；在 swarm-forge 当前的纯 tmux 架构下，这三件目前的实现（文件轮询、
`send-keys!`、pane 文本扫描）就是"自己写"的那部分，只是已经写完了，issue 真正要
回答的是"值不值得换成原生的"，不是"有没有替代方案"。

### `extension_ui_request` 在 SDK 里（不是 RPC 模式）怎么用；外壳程序能不能拦截

RPC 模式下 `extension_ui_request`/`extension_ui_response` 是一对 stdout/stdin 上的
JSON 消息（`method` 取 `select`/`confirm`/`input`/`editor` 时阻塞等回复，`notify`/
`setStatus`/`setWidget`/`setTitle`/`set_editor_text` 是 fire-and-forget）。
证据：`pi.dev/docs/latest/rpc`"Extension UI Protocol"节；本机代码里有一份完整的
参考实现，`packages/coding-agent/examples/rpc-extension-ui.ts`——一个外部 TUI
client `spawn` 出 agent 子进程，在 `stdout` 上监听 `type === "extension_ui_request"`，
弹出自己的 dialog，再把结果写回 `stdin` 的 `extension_ui_response`
（`rpc-extension-ui.ts:513-536` 的 `stdoutRl.on("line", ...)` 分支，
`handleExtensionUI` 在 `377-458` 行）。这就是 issue 问的"外壳程序拦截并换成自己
UI"在 RPC 模式下的标准做法，且是**pi 官方示例**，不是我们要自己发明的模式。

SDK 模式（in-process，没有 stdout/stdin 协议）里没有 `extension_ui_request` 这个
消息本身——它被替换成一个直接的 TypeScript 接口：

```ts
// /Users/admin/workspace/pi-mono/packages/coding-agent/src/core/extensions/types.ts:104-105
/**
 * UI context for extensions to request interactive UI.
 * Each mode (interactive, RPC, print) provides its own implementation.
 */
export interface ExtensionUIContext {
  select(title, options, opts?): Promise<string | undefined>;
  confirm(title, message, opts?): Promise<boolean>;
  input(title, placeholder?, opts?): Promise<string | undefined>;
  editor(title, prefill?): Promise<string | undefined>;
  // ...notify/setStatus/setWidget/custom/...
}
```

宿主程序在创建 `AgentSession` 时，通过 `ExtensionBindings.uiContext`
（`agent-session.ts:153-154`）传入自己的 `ExtensionUIContext` 实现；
`ExtensionRunner.setUIContext(bindings.uiContext)`
（`agent-session.ts:1842`）把它接到运行时。extension 代码里的每次
`ctx.ui.select(...)` 调用都会直接落到宿主传入的这个对象上——**这就是 SDK 模式下
"外壳程序拦截"的答案：不是拦截，是宿主本来就该实现这个接口**，等价于 RPC 模式里
自己写的那个 stdout/stdin 处理器，只是换成了直接函数调用，不需要序列化。

如果宿主没有传 `uiContext`（比如纯 print/headless 模式），运行时会退化成
`noOpUIContext`：`select`/`editor`/`input` 直接 resolve `undefined`，`confirm`
直接 resolve `false`（`runner.ts:168-194`）——**不是阻塞，是立即给一个"没有回答"的
默认值**，`hasUI()` 也会返回 `false`（`runner.ts:296-298`）。这对 Dashboard 场景
是个提醒：如果 role session 起的时候忘了接 `uiContext`，`extension_ui_request`
风格的交互不会挂起等 Dashboard，会直接静默失败成"取消"。

### role session 等答案时是阻塞还是让出控制权；会不会互相饿死

分两层看：

- **子 session 自己的执行线**：会阻塞。`toolTimeoutMs` 的计时器"starts on
  `tool_execution_start`, clears on the matching `tool_execution_end`"——工具调用
  在收到回复前"remains open"（`tool-reference.md:119`）。`contact_supervisor`（连同
  `intercom`、`bg_wait`）被显式排除在这个硬性单工具超时之外
  （`agents.md:365`、`tool-reference.md:119`），所以它可以无限期挂起而不会被
  单工具超时踢掉。但**没有**被排除在整个 run 的 `timeoutMs` 之外——前台 run 默认
  30 分钟墙钟超时（`observability.md:7`：无显式 `timeoutMs` 时"a generous
  30-minute wall-clock timeout"）。也就是说：role 会真的停在那儿等，但如果 operator
  半小时内没回，run 本身可能先因为整体超时死掉，除非启动时把 `timeoutMs` 调大。
- **role 之间会不会互相饿死**：不会，因为每个 role/child 是独立的 session（前台
  child 是"a pi session created inside the parent Pi process, not a second `pi`
  process"，后台 child 是"a pi session created inside the detached runner
  process"，`observability.md:9,11`），互相之间没有共享的单线程执行栈。一个 role
  卡在 `contact_supervisor` 上只挂起它自己的 tool_execution，不占用父 session 或
  兄弟 role 的执行时间；父 session 可以随时用
  `subagent_supervisor({action:"pending"})` 去看有哪些请求在等，回复的先后顺序由
  人/父 session 决定，不是被 pi 的调度序列化的。真正的瓶颈是 operator 一个人只能
  按顺序看 Dashboard 上的请求，那是人力带宽问题，不是 pi 的机制问题。

### FleetView 能看到的东西，外壳程序能不能拿到同样的数据

能，而且是文档明确写的 fallback 路径，不是逆向工程出来的：
"Without a TUI, `/subagents-fleet` retains the textual
`subagent({ action: "status", view: "fleet" })` fallback"（`observability.md:123`）。
FleetView 本身"reads that cache only. It does not poll caller code."
（`observability.md:227`，讲的是外部 job 注册的缓存，同一份缓存也是 FleetView
和 `status` 查询共享的底）。更底层还有落盘的机器可读文件：

```text
<tmpdir>/pi-subagents-<scope>/async-subagent-runs/<id>/
  status.json     # 驱动 widget 和 subagent({action:"status"}) 的输出
  events.jsonl    # 生命周期事件流
  output-<n>.log  # 实时人类可读 tail
```

（`observability.md:181-193`）。所以外壳程序有两条路都能拿到 FleetView 同款数据：
调 `subagent({action:"status", view:"fleet"})`（如果外壳本身就是一个 pi
session/extension），或者直接读 `status.json`（如果外壳是外部进程，不在 pi 里）。
pi 核心的 `/tui` 文档页本身**不提** FleetView——它是 pi-subagents 这个 extension
的功能，不是 pi 内核功能（对 `pi.dev/docs/latest/tui` 的抓取确认了这一点：搜索
FleetView 无结果）。

### `acceptance` 字段到底是什么 gate；跟 operator 批准是不是一回事

不是一回事。`acceptance` 是**子 agent 自证其工作完成质量**的自动化证据体系，
评估对象是子 agent 交出来的东西（改了哪些文件、跑没跑测试、有没有 staged 但没提交
的垃圾），不是"有个人看了一眼说 OK"：

- 证据等级是 `auto`/`none`/`attested`/`checked`/`verified` 五级
  （`tool-reference.md:432`），越往后越"自动化程度高"：`attested` 要求子 agent
  自己交一份结构化的 `acceptance-report`（`tool-reference.md:462-468`）；`checked`
  是运行时做结构性检查（比如 staged index 前后一致，`tool-reference.md:384`）；
  `verified` 是宿主真的跑一条命令（`gate`/`acceptance.verify`）来验证
  （`tool-reference.md:401-409`）。
- 唯一带"review"字样的选项是 `review: { agent: "reviewer", required: true }`
  ——这是**另一个 agent** 复核，不是人类（`tool-reference.md:434-436,447`）。
- `acceptanceRole: "read-only" | "writer"` 只影响"要不要自动推断出一个 gate"，
  跟人工点头毫无关系（`agents.md:367`、`tool-reference.md:440`）。

所以 issue 里"自动化用户编辑批准"这个说法，落到文档原文应该理解成"自动校验子
agent 编辑结果是否合格"，不是"用户审批"。Dashboard 要的"批准 gate"（人停下来等
operator 点头）在这套体系里没有位置——最接近的口子是 `acceptance.verify` 可以挂一条
host-run 命令，理论上可以把这条命令写成"检查一个人工批准标记文件是否存在"，但那是
在 gate 机制上面自己叠一层，不是 gate 本身自带的人工批准语义。

## 结论：必须自己写的那部分，最小形状

只有**批准 gate**是纯粹的空白，其余三件在"role 挂到 dispatcher pi session 之下"
的前提下都有原生机制可以直接对表使用（澄清→`contact_supervisor`/
`subagent_supervisor`；投任务→`steer`/`follow_up`；看状态→
`subagent({action:"status",view:"fleet"})` 或 `status.json`）。批准 gate 的最小
形状：

1. 不新开 server、不新加依赖——复用 `pack_dashboard_request.bb` 现有的
   pending/done 文件队列模式。
2. 加一个 `approve` 子命令（对称于现有的 `clarify`）：role 侧写一个 pending
   文件（内容是"我要过这道 gate 了，这是摘要"），然后原地轮询等 operator 写
   done 文件（真批准）或 reject 文件（打回），本质是 `clarify!`/`answer-request!`
   的复制体，不用另写一套轮询逻辑。
3. 如果/当 role 迁移成 dispatcher 的子 session：把第 2 步的"pending 文件"换成
   `contact_supervisor({reason:"need_decision", message:"gate: <summary>"})`，
   把"等 done 文件"换成等 `subagent_supervisor({action:"reply"})`
   的回复内容按约定解析成 approve/reject——协议不变，只换传输层，是增量迁移，
   不是推倒重写。
