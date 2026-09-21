# Research: swarm-forge 宪法与 role prompt 逐条分类——协议 / harness 适配 / 待定

对应 issue #185。范围：本仓 186 行——`swarmforge/constitution/articles/handoffs.prompt`
（85 行）、`workflow.prompt`（31 行）、`engineering.prompt`（56 行）、
`swarmforge/roles/lieutenant.prompt`（14 行，`main` 版）；外加 `upstream/lieutenant` 分支
（`23653942`）上同名但内容完全不同的 90+ 行 dispatcher 版 `lieutenant.prompt`，只挑其中属于
「协议」的部分过一遍。

判据用 issue 原文：**协议**——换了 harness 语义仍然成立；**harness 适配**——只因为跑在
tmux + PATH + Claude Code 上才需要；**待定**——换 harness 后语义会变、需要单独决策。

---

## 先说一个会改变整张表读法的事实

**这四个文件与 `upstream/main` 当前版本逐字节相同。** 用
`git show HEAD:<file>` 对比 `git show upstream/main:<file>`，四个文件 `diff` 输出均为空。
`git log --follow` 逐条查过它们的完整历史（handoffs.prompt 33 次改动、workflow.prompt 52 次、
engineering.prompt 30 次、lieutenant.prompt 2 次），**每一次改动的作者都是
`Robert C. Martin <unclebob@cleancoder.com>`**，`git log --follow --merges` 对四个文件都返回
空——本 fork 从未在这四个文件上产生过冲突，也从未用自己的 commit 改过它们一个字。

这意味着：**这 186 行里没有一条是被本 fork 自己的事故买来的。** `docs/fork-deltas.md` 记录的
十条事故驱动差异（D-1…D-10）全部落在 `.bb` 运行时脚本与 `swarmforge-operator` skill 里，
从未触碰这四个 prompt 文件本身。下表里能给出「出处」的地方，给的是**上游commit（设计
决定，不是事故）**，或者是**本 fork 的运行时是否真的兑现了这句 prompt 文本**（有几处，
prompt 文本本身没变过，但本 fork 的 `.bb` 实现相对 upstream 的实现打了一个 D-* 补丁，
才让这句话在本 fork 里为真——这种情况我在「出处」列写清楚，跟「文本被事故改写」是两回事）。

---

## `handoffs.prompt`（85 行）

| 原文（缩写，行号） | 分类 | 理由 | 出处 |
|---|---|---|---|
| 起草到 `./tmp/`，跑 `swarm_handoff.sh <draft-file>`（L4） | harness 适配 | `./tmp/`、worktree、脚本名都是这套 tmux+worktree 实现的具体路径约定 | — |
| 拒绝 `/tmp` 与 `outbox/tmp/` 里的草稿（L5） | harness 适配 | 防的是这套文件系统布局里两个具体的误用位置 | — |
| `--help` 打印用法，不要当路径传（L6） | harness 适配 | 纯粹这一个 CLI 的调用约定 | — |
| 只用 `git_handoff` / `note` 两种消息类型（L7-9） | 协议 | 消息类型是封闭集合、收件方按类型分流处理逻辑——这是消息协议的核心约束，与传输介质无关 | — |
| 未经用户/角色 prompt/宪法明确指示不发 `note`（L10-11） | 协议 | 谁有权发起一条通知是协作纪律，不依赖 harness | — |
| 遇到歧义/冲突用 `pack_dashboard_request.sh clarify` 问 operator，不在 pane 里问（L12-15） | 协议 | issue 原文给的协议例子——「求助权在谁身上、不能自己拍板」是权限边界；具体脚本名/"pane"是 harness 表述 | — |
| `git_handoff` 先 commit 再写草稿；helper 从 sender worktree HEAD 填 `commit`/`artifacts`，不要手填 SHA（L16 前半） | 协议 | payload 完整性：commit 指针必须来自工具读取的事实，不能靠 agent 编造 | — |
| `SWARMFORGE_ROLE` 未设时，helper 从 `roles.tsv` 和本 worktree 推断角色（L16 后半、L54-55） | harness 适配（但由本 fork 事故兑现） | 「按 worktree 目录解析角色身份」这套机制绑定在一 role=一 worktree=一 tmux window 的拓扑上，会随 harness 换掉；但**这句话能在本 fork 里为真，是 D-1 补丁的结果**——upstream 自己的 `.bb` 实现曾经/在别的分支上用进程 cwd（`user.dir`）解析收件箱，与这句 prompt 文本承诺的「按 roles.tsv」不是一回事，两个事实来源一旦分裂，daemon 与 agent 互相找不到对方且都不报错 | 本 fork 事故：issue #8，commit `3b6c315`，`docs/fork-deltas.md` D-1（pi-governance QA 停摆一天多） |
| master agent 若在含 specifier 的 pack 上，工作就绪即排 `git_handoff`，不要在 pane 里问批准，operator 用 Attention（L17） | 协议 | 「谁批准、什么时候不需要再问人」是决策权边界；Attention/pane 的具体呈现是 harness | — |
| 不加多余 git headers（`coverage`/CRAP/evidence），helper 写（L18） | 协议 | payload 里的证据字段该由工具生成、agent 不该编造，是防止污染交接物的通用纪律 | — |
| `git_handoff` 头部模板 `type/to/priority/task`（L19-26） | 协议 | 消息要带路由信息（发给谁、优先级、任务标识）是信封 schema 层面的协议，字段名可能变但"消息头要带路由信息"这个形状不会变 | — |
| 完成后无论改了什么都要转发到下一角色，格式化/manifest/审计等非功能改动也要转（L27-31） | 协议 | issue 原文给的协议例子第一条 | 首次写死于上游 commit `354a4fe`（设计决定，非事故） |
| 反向（`non-forwarding`）入站 `git_handoff` 只合并；helper 在 inbound 为 non-forwarding 时拒绝再发（L32-34） | 协议 | `non-forwarding` 是工具层强制的 payload 标记，不只是文案约定——upstream 的 `swarm_handoff.bb` 校验阶段真的会拒绝违规发送，见下方"出处" | 上游 commit `771d1fa`/`0b69a51`；本 fork 经 issue #45 同步这套机制；机制细节见 `docs/research/upstream-task-completion-protocol.md` Findings A |
| 转发同一任务时保留收到的任务名（L35） | 协议 | 任务标识在链路上要保持稳定，方便下游追踪，与传输介质无关 | — |
| master agent 用现有 New Task/board card 名当 `task:`，不要自造（L36） | harness 适配 | New Task、board card 是这套 dashboard 的具体概念；协议残留是「任务名必须来自单一权威来源」 | — |
| `note` 消息头模板（L37-44） | 协议 | 同 `git_handoff` 头部——信封要带路由信息，这是协议 | — |
| 校验失败就修草稿重跑（L46） | 协议 | 「先校验后送」是通用的可靠交付循环，不依赖具体 CLI | — |
| 发送成功后 helper 删除草稿；需要手动删用 `rm` 不用 `rm -f`（L47-48） | 拆分：前半协议，后半 harness 适配 | 「已发送的草稿不留脏状态」是协议；`rm` 而非 `rm -f` 是这套 shell 环境下避免掩盖错误信息的操作提示 | — |
| 不写长 handoff body，helper 生成最终 payload（L49） | 协议 | payload 由工具生成以保证结构化，避免自由文本污染交接物 | — |
| 不要直接发 tmux 通知（L50） | harness 适配 | tmux 是具体传输介质；协议层面是「不要绕开投递系统自己发通知」，但表述完全绑定 tmux | — |
| 不要手工编辑/合并/暂存/提交 handoff runtime state（L51） | 协议 | runtime state 只能由投递系统管理，agent 不该染指——这是不变量，不管 harness 是 tmux 还是别的 | — |
| `ready_for_next.sh` 按角色分发 task/batch；`git_handoff` 走 `merge_and_process.sh` 合并入站 commit（L56-58） | 协议（脚本名 harness 适配） | 「`git_handoff` 的处理方式就是 merge 一个 commit」是协议核心语义 | — |
| 结构随流水线下行改善：反向时接收方 replay 到入站树形状，不保留旧布局；正向时保留自己现有树形状，不采纳入站布局（L59-64） | 协议 | issue 原文给的协议例子第二条 | 上游 commit `fc85777`（设计决定，非事故） |
| 合并冲突全部由接收方解决，不发明新的 `git merge`；parallel 卡撞车是预期行为（L65-68） | 协议 | issue 原文给的协议例子第三条 | 上游 commit `68e78c6`（设计决定，非事故） |
| `NO_TASK`/`TASK`/`TASK_NAME`/`BATCH`/`BATCH_ITEM`——helper 打印什么就当什么，不要自己臆造任务信息（L69-75） | 待定 | 见下方「待定项」第 1 条：这是「命令跑完、解析 stdout 磁贴」的回合制状态机，在常驻 SDK session 的事件循环下是否还需要存在，未定 | — |
| tmux 唤醒在忙时忽略（L76） | harness 适配 | issue 原文给的 harness 适配例子；字面绑定 tmux 唤醒事件。协议残留（消费者要对重复通知幂等）已被 `docs/research/handoff-reconciliation-standards.md` 验证为通用队列原则，但这句话本身写的是 tmux 触发条件 | 队列幂等性的外部对照见该研究文档 Candidate matrix「Re-notify the same durable entry」 |
| 完成后跑 `done_with_current.sh`；反向合并后即是完成，不再为该 inbound 排 `git_handoff`（L77-79） | 协议（脚本名 harness 适配） | 完成态与合并态的对应关系，是 L32-34 那条 non-forwarding 规则的收尾一半 | 同 L32-34 |
| `note` 也是任务，读完/处理完要跑 `done_with_current.sh` 才能接下一个（L80-81） | 协议 | `note` 纳入同一个任务完成生命周期，不能读完就不了了之 | — |
| `MAIL_WAITING`/`NO_TASK`（完成侧）（L82-84） | 待定 | 同 L69-75，回合制打印状态机的一部分 | — |
| 重启时跑 `ready_for_next.sh` 并遵循输出（L85） | 待定 | 同样依赖打印状态机作为恢复入口 | — |

## `workflow.prompt`（31 行）

| 原文（缩写，行号） | 分类 | 理由 | 出处 |
|---|---|---|---|
| 启动时发现并记住分配的 branch/worktree（L4） | 协议 | 每个角色必须先确认自己被分配到哪份工作，是分工纪律的前提，不依赖具体机制 | — |
| assigned worktree 是 `master` 时在主 checkout 工作，不要指望 `.worktrees/<role>`（L5） | harness 适配 | worktree 布局细节，是这套 tmux+git worktree 架构专属的例外分支 | — |
| 只在分配的 branch/worktree 工作（L6） | 协议 | 角色只能动自己被分配的那份工作，越权是协作纪律，不依赖 harness | — |
| 不检查/diff/merge/base 别的分支，除非被显式点名（L7） | 协议 | 同上，越权边界的具体化 | — |
| 不要跑 `./swarm` 修复 helper 脚本；缺失就停止报告（L8） | harness 适配 | `./swarm` 是这套 launcher 的具体命令 | — |
| 不给 announcement/check-in comment 加角色 byline（L11） | harness 适配 | check-in comment 是这套 board/dashboard UI 的评论展示位置 | — |
| commit message 必须带 `By <role>.`；给出示例（L14-21） | 协议 | 谁做的必须可追溯，是跨 handoff 链路的审计要求，不依赖 harness——commit 本身就是协议里"载体是 git commit"的一部分 | 上游 commit `a9a3ffa`（把 byline 从 check-in comment 移到 commit message，设计决定） |
| commit-msg hook 补全缺失的 byline，不要 `--no-verify` 跳过（L23） | harness 适配 | issue 原文给的 harness 适配例子——这是这套 git hook 机制的具体绕过口子 | — |
| 临时文件用 `./tmp/`，不用 `/tmp`（L26） | harness 适配 | issue 原文给的 harness 适配例子 | — |
| parse/dry-check 写 `./tmp/…`；handoff 草稿也写 `./tmp/`（L27） | harness 适配 | 同上，路径约定 | — |
| 不把 `.swarmforge/handoffs/outbox/tmp/` 当草稿区，那是 handoff helper 的（L28） | harness 适配 | 具体目录布局的专属用途 | — |
| 预期 git 布局或 assigned worktree 缺失时停止并报告，不要静默在错误地方工作（L31） | 协议 | 环境校验失败时默认动作是"停止升级"而不是"猜测继续"，是跨 harness 都该有的纪律 | — |

## `engineering.prompt`（56 行）

| 原文（缩写，行号） | 分类 | 理由 | 出处 |
|---|---|---|---|
| 启动时从 `github.com/unclebob/...` 拉最新 CRAP/mutation/DRY 工具；解析到最新上游版本；不依赖过期缓存/预装副本；Go/Clojure/Java 工具表（L4-10） | harness 适配 | 点名的是 Uncle Bob 自己的工具生态（`crap4clj`/`mutate4go`/`dry4java` 等），是这个项目选定的具体工具链，不是新仓库会继承的语言/工具栈 | — |
| Clojure 项目优先 Babashka；写 Speclj 不写 `clojure.test`；装 Speclj/structure-check 的具体命令；Java 项目不用 Maven 跑测试，自建 test runner（L13-17） | harness 适配 | 语言与测试框架选择，绑定这个项目当前的技术栈 | — |
| 小步可评审地增量工作（L20） | 协议 | 工程纪律，与语言/工具/harness 无关 | — |
| 优先最简单、能撑住当前行为、给下一步留余地的设计（L21） | 协议 | 设计哲学，跨项目都成立 | — |
| 测试贴近被改的行为（L22） | 协议 | 通用测试纪律 | — |
| 把可测模块和环境不友好的模块（GUI/外部设备/系统错误/hang）分开，最大化可测边界（L23） | 协议 | 架构分层原则，语言无关 | — |
| IO-near 模块不得重新回答一个领域问题；已有高层模块答过就调用它、翻译结果（L24） | 协议 | 依赖方向与去重原则，是纯设计原则，与 harness 无关 | — |
| 只有可测模块才能参与跑测试/覆盖率/mutation/CRAP/DRY/property test 的工具（L25） | 协议 | L23 的推论，边界纪律 | — |
| property test 单独放，不混进常规验证（L26） | 协议 | 验证分层的通用纪律；具体工具名是 harness 层细节，但"分层"本身是协议 | — |
| 用 unclebob 的 Acceptance-Pipeline-Specification 做 Gherkin acceptance；APS 工具清单、安装方式、两参数 CLI 形式、Babashka 优先、project-specific 组件清单、"Gherkin acceptance mutation"的定义（L29-38） | harness 适配 | 全部点名这一套特定验收框架的具体依赖、命令行形状与安装方式 | — |
| Gherkin acceptance mutation 跑要周期性报进度，方便区分正常慢跑和 hang（L39） | 协议 | 长跑任务必须能被外部区分"正常慢"和"卡死"是可观察性纪律，任何执行环境都成立，只是信号形式会变 | — |
| 跑语言/build/test 命令前优先用项目本地缓存/配置路径，避免默认位置触发 sandbox 限制（L42） | 协议 | 沙箱化执行环境下的通用验证卫生，不限于这套 harness | — |
| constitution tools 一次只跑一个，不并发跑 CRAP/DRY/coverage/mutation/gherkin mutation/structure-check；worker 上限用 `--max-workers 4`/`--workers 4`；function mutation 差分、不传 `--mutate-all`；Gherkin mutation 差分、不传 `--level full`；acceptance generation 与 acceptance tests 顺序跑、不与整套语言测试并发（L43-49） | harness 适配 | 全部是这些具体工具在这台机器上并发时会冲突的经验规则，绑定具体 CLI flag 与工具实现 | — |
| mutation 工具的 scan/count 模式提示模块揉合了多个职责；按职责拆分而不是为了追 mutation 站点数拆分；拆分后保留 manifest、不手改（L46） | 拆分：前半协议，后半 harness 适配 | "一个文件揉合多个职责就该拆"是单一职责原则；"保留这个特定 mutation 工具的 manifest 格式"是工具实现细节 | 上游 commit `cc8d63b`（从"站点数阈值"改成"职责数"，设计纠偏，非事故） |
| handoff 前跑项目相关的本地验证命令，如果有的话（L50） | 协议 | 交接前要验证过一遍，是跨 harness 都成立的纪律；"local verification command"抽象足够高 | — |
| 不自造项目本地 CRAP/DRY/mutation/coverage 代理；要装并跑宪法工具，不把自制 `bb crap`/`coverage`/`mutation-count` 任务当成这些工具（L53） | harness 适配 | 点名了具体工具生态和自制脚本的反模式，是这套宪法工具生态特有的规则 | — |
| 不手改 mutation testing 或 Gherkin acceptance mutation manifest，让 approved 工具在正常跑的过程中更新（L54） | harness 适配 | manifest 是这些具体工具的产物 | — |
| 不提交不相关的本地改动或生成产物，除非任务需要（L55） | 协议 | commit 卫生纪律，通用工程原则 | — |
| 不熟悉的命令用前先看本地 help 或项目文档（L56） | 协议 | 通用操作纪律，不依赖特定 harness | — |

## `swarmforge/roles/lieutenant.prompt`（`main` 版，14 行，被动参谋）

| 原文（缩写，行号） | 分类 | 理由 | 出处 |
|---|---|---|---|
| 你管理 forge：`projects/`、dashboard、operator 的 chat；你不是 pack agent（L3-4） | harness 适配 | `forge`/`pack`/`projects`/`dashboard` 都是这套多角色 tmux+worktree 架构的具体拓扑概念 | — |
| 不要读或遵循 `swarmforge/constitution.prompt` 或 constitution articles（L4-5） | 协议 | 「协调/派发角色不受 worker 宪法约束，规则集单独一套」是决策权分层的设计，不是 harness 细节——这条大概率要带到新仓库：dispatcher 类角色与 pack 角色本来就该是两套规则 | — |
| Follow-up 以 `[id] text` 到达，用 `pack_dashboard_request.sh answer <id> ./tmp/answer.txt` 回（L7-8） | harness 适配 | 具体的 dashboard chat 消息格式与回应脚本 | — |
| 用 `pack_dashboard_request.sh clarify ./tmp/question.txt` 问；不在 pane 里问（L9-10） | 协议 | 与 handoffs.prompt L12-15 同一条协议（卡住了升级给人、不自己在对话里问），脚本名是 harness | — |
| 那些文件写在 `./tmp/`；helper 已经在 PATH 上（L11） | harness 适配 | issue 原文给的 harness 适配例子 | — |
| 不实施 project 工作，那是 pack agent 的事（L12） | 协议 | 「决策/协调角色永远不做实现」是关注点分离的不变量，不依赖具体机制；`docs/research/upstream-lieutenant.md` Findings C1 已确认这条与 `swarmforge-operator` skill 的边界互补关系 | `docs/research/upstream-lieutenant.md` Findings C1 |
| 可以总结状态、建议一个 pack 或 project、指向 `mission.md`（L13-14） | 待定 | 见下方「待定项」第 4 条——这条是被动参谋版本的权限上限（只能建议，不能拍板），dispatcher 版本把同一句话改写成了"主动提议、批准后自己动手"（`upstream/lieutenant:lieutenant.prompt` 第 19-20 行与第 40-52 行），新仓库到底继承哪个版本的措辞不是本票能定的 | — |

---

## `upstream/lieutenant` 分支的 dispatcher 版 `lieutenant.prompt`（91 行）——协议候选部分

`upstream/lieutenant` 上的同名文件不是这 14 行的另一个版本，是完全不同的 90+ 行内容：一个
主动提议、切卡、追进度的 planner & dispatcher。`docs/research/upstream-lieutenant.md`
Findings B4 已经逐段核实过行号，这里只挑其中**属于协议**（换 harness 后决策权/流程形状仍然
成立）的部分再过一遍，harness 特有的具体机制（`pack_board`/`.swarmforge/routes.tsv`/
`--caller lieutenant`）不重复罗列：

| 原文（缩写，对应行号） | 分类 | 理由 |
|---|---|---|
| 「You are the planner and dispatcher. Project roles do not ask the operator for the next feature. You cut cards.」（22-23 行） | 协议 | 核心决策权归属——由一个持续运行的角色决定"下一步做什么"，而不是每次都靠人显式发起，这是指挥模型本身，不依赖 `pack_board` 具体实现 |
| Attention 消息要用大白话，不暴露协议名/helper 内部细节，除非做决定必须知道（19-20 行一带，见研究文档转述） | 协议 | 对人的沟通要用人类语言而不是内部黑话，是人机边界原则 |
| project import 属于 forge 管理工作，dispatcher 亲自做，绝不派给 pack agent（见研究文档 B4 引用） | 协议 | "什么类型的工作只能由协调角色自己做、不能下放"是分工原则，不依赖具体 verb 名字 |
| 按 card type 选路由，路由表是权威；新产品行为不许走 review、协议/业务规则不许走 utility、新按钮/布局不许走 component（25-39 行） | 协议 | 「一件工作必须经过哪些质量关卡，由变更的性质决定，不是临时拍板」是质量保证策略；具体路由查表机制（`.swarmforge/routes.tsv`）是 harness 细节 |
| 提议下一批卡、求批准，不等操作者主动点名（40-52 行） | 协议 | "主动提议 + 人批准"这个决策循环是指挥模型的核心机制 |
| 已批准的等待卡起进空闲 lane 不需要再过 Attention；但打断一张在跑的卡、`done`/`stop`/`increment-audit` 需要（65-69、84-87 行） | 协议 | 哪一级动作需要人工确认、哪一级不需要，是自动化的授权边界——这条决定了"日常排班要不要打扰人"，是协议核心而不是 UI 细节 |
| notify 驱动重新排班而不是轮询：`git_handoff` 到达、卡完成、New Task、new-project、`allow`、`reverse-cleared`、`clarify` 都是触发点（53-64 行） | 协议（具体 notify 名字是 harness） | "靠事件触发重新规划，不是靠轮询"是协议原则；这七个具体 notify 名字绑定 `pack_web`/`handoffd` 的实现 |
| pack 卡住时 `clarify` 报告给 operator：项目、卡、角色、卡住原因；操作者的答复决定怎么处理（见研究文档 B4） | 协议 | 与 `main` 版、`handoffs.prompt` 同一条「卡住了升级给人、听人的决定」协议，只是发起方从 pack 角色变成了 dispatcher 自己 |
| New Task 打 LT 标记时是指令，直接嵌进计划，不创建卡片（88-91 行） | 协议 | "人工指令"与"自动提议的卡片"是两条不同优先级的输入通道，不该混淆——这是输入源的权威分级，不依赖具体 UI 标记怎么打 |
| 最大化并行度：依赖通常是完成/集成约束而非启动约束；只有具体缺失的产物才该等，要点名那个阻塞（见研究文档 B4"提议 → 求批准"周边段落） | 协议 | 通用任务调度纪律——依赖判定要具体、不能含糊等待，可以完全类比操作系统调度器的思想，不依赖 `pack_board` |

---

## 待定项

**1. `NO_TASK`/`TASK`/`TASK_NAME`/`BATCH`/`BATCH_ITEM`/`MAIL_WAITING`——打印令牌驱动的状态机
（`handoffs.prompt` L69-75、L82-85；`main` 版 lieutenant 的 `[id] text` follow-up 回合制）。**
待定在于：这套「helper 命令跑完、往 stdout 打印固定字符串、agent 解析后决定下一步」的机制，
假设了一个"同步执行、读返回值"的回合制模型。缺的前提：pi 的常驻 SDK session 有没有等价的、
不用靠 parse stdout 的原生事件/hook 机制来表达"认领了一个任务""还有下一个任务在排队"——这正
是 issue #182（pi 常驻 session 撑不撑得住一个 role）、#183（Dashboard 的四件事在 pi 侧各自落在
哪个原生机制上）在问的问题，本票不重复下结论。协议残留（不管选哪种机制都要保留）：认领必须是
一次持久状态转移而不是一个短暂信号，重复通知必须被幂等忽略——这两条已经被
`docs/research/handoff-reconciliation-standards.md` 用外部队列系统（SQS/RabbitMQ/K8s
controller）的先例验证过，值得作为协议需求单独提炼，而不是丢给"待定"就不管了。

**2. `roles.tsv` + worktree 的角色身份解析（`handoffs.prompt` L16、L54-55）。**
待定在于：按 worktree 目录解析角色身份，绑定在"一个角色 = 一个 git worktree = 一个 tmux
window"这套拓扑上。缺的前提：新仓库的 role 拓扑长什么样——是 two-pack 式的固定角色集合，
还是 lieutenant 式一个模板走多种路由——由 issue #188（第一个等价物是 two-pack 还是
lieutenant 打头阵）决定，决定了才能知道"角色身份的单一权威来源"具体该落在哪。协议残留：
发送方与接收方对"这个角色的收件位置在哪"必须有同一个事实来源，不能一个读配置表、一个读进程
cwd——这正是 issue #8 事故的教训，不管新仓库怎么实现角色身份，这条不变量都该保留。

**3. Attention / `pack_dashboard_request.sh clarify` / "不在 pane 里问"这套人工升级通道
（`handoffs.prompt` L12-15；`main` 版与 dispatcher 版 lieutenant 全篇的 clarify 机制）。**
待定在于：issue #184（盘清 pi-governance unattended channel 的职责边界）与这条协议直接重叠——
需要先定"谁在新仓库里充当人工升级的落点"，才能知道这条"卡住了必须走一个专门通道、不能自己在
对话轮次里问"的协议在 pi 上具体经过哪个原生机制。

**4. 被动参谋（`main` 版 L13-14）与 dispatcher（`upstream/lieutenant` 22-23、40-52 行）
两套 lieutenant.prompt，新仓库到底继承哪些字面规则。** issue 正文与
`.claude/projects/.../memory/lieutenant-dispatcher-model-decision.md` 已经把方向定成
dispatcher（"指挥模型要换成 lieutenant 排班"），但具体到"被动版本里'只能建议、不能拍板'这句
话要不要整条删掉，还是改写成 dispatcher 版'主动提议+批准后执行'的对应句"，是这张对照表刻意
不下结论的地方——这是留给后续决策票的产品选择，不是"协议 vs harness"能回答的问题。

**5. dispatcher 版的 card 路由机制（`pack_board create/move/stop`、`.swarmforge/
routes.tsv`、card type 到路由的查表）在新仓库里怎么表达。** 上一节已经把"路由由变更性质决定、
是权威来源"这条协议原则单独摘出来了，但它靠什么机制落地——一张配置表、一段 prompt 里的判定
逻辑、还是 pi 侧某种原生的任务分类——待 issue #188 定了 role 拓扑之后才能回答。
