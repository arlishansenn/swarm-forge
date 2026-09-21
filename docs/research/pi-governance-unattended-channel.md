# pi-governance unattended channel 职责盘点：吃掉的边界画在哪

对应 issue [swarm-forge#184](https://github.com/arlishansenn/swarm-forge/issues/184)。

## 方法与范围

一手来源：`/Users/admin/project/pi-governance` 的源码、`docs/adr/`、git log 与
GitHub issue（remote 是 `origin https://github.com/arlishansenn/pi-governance.git`，
`gh` 命令均以 `-R arlishansenn/pi-governance` 或在该 clone 内执行）。对照物是本仓的
`.agents/skills/swarmforge-operator/scripts/run-issue.sh`。凡未能在源码或 issue 里
直接核实的，标注「未找到记录」，不猜测。

**已确认的既定裁决**（先说清楚，避免下文重复论证）：

- pi-governance 自己的 ADR 已经回答了一半的问题：[ADR-0027](file:///Users/admin/project/pi-governance/docs/adr/0027-swarm-forge-replaces-l1-l2-orchestration.md)
  裁定 `l1-agent`/`l2-agent` 的运行时编排**搁置**，多 agent 编排改由 swarm-forge 承担，
  理由是「两套编排就有两个『哪个才是权威』的问题」——与本票的前提（一套调度者，不要
  两套）同源。该 ADR 明确**不**裁决 `l2ctl`/`deploy.py`/两个运行根的拆除时机，只裁决
  编排权。
- issue #184 问的是 unattended channel 这一条**具体路径**（`issue-agent.zsh` daemon），
  它比 l1/l2 通用编排更窄，ADR-0027 没有专门点名它；本文档在 ADR-0027 定的方向下，
  对这一条路径逐项判断。

## 核心表：职责 × 去留

标注 `issue-agent.zsh:L` 均指该文件行号（698 行，`9146426`..`17f7ba6` 共 17 次修订，
2026-08-10 至 2026-09-02）。

### 调度类（决定「现在该不该认领、认领哪一单」）

| 职责 | 去留 | 理由 | 证据位置 |
|---|---|---|---|
| 轮询节拍 + lock 防重入（`mkdir` 原子锁，陈旧阈值 7200s） | **新仓库吃掉** | 这是「一套调度者」的核心机制，新仓库的 lieutenant 排班模型必须自己有等价物；旧实现绑定 launchd/systemd，不可原样搬 | `issue-agent.zsh:652-664`；launchd 绑定见 `openspec/specs/issue-agent/spec.md`「daemon 必须在 GUI login session 域内运行」一条 |
| 一轮至多一单、串行 | **改造后保留** | 设计教训值得保留（避免多单并发写同一 workspace/同一 tmux 会话），但新仓库的并发单位是「project swarm」而非「常驻 l2 实例」，天然支持多项目并行，不必照搬「全局一单」这条硬约束 | `issue-agent.zsh:16-17`（文件头注释）、`poll_once` 命中即 `return`：`issue-agent.zsh:636-640` |
| 仓库清单（`config/issue-agent-repos.list`，一行一个 owner/repo，靠 `config/machines.list` 的角色列避免多机争抢） | **新仓库吃掉（换形态）** | 概念要留（哪些仓库归这套通道管），但新仓库天然多项目（`projects/<name>/`），载体应该是项目登记表而不是独立的 repo 清单 | `issue-agent.zsh:132-143`；实测清单目前只有一行 `arlishansenn/pi-governance`（`config/issue-agent-repos.list`），角色表见 `config/machines.list` |
| halt/pause 状态机（跨轮存活的停摆标记 vs 人为暂停标记，两者独立） | **新仓库吃掉** | 「一次失败堵住通道是明示接受的代价」是经过事故验证的设计立场（见下表 Q5），新调度者需要同等粒度的停摆/暂停语义，但存储介质（文件 vs swarm 自己的状态存储）要按新架构重做 | `issue-agent.zsh:34-40`, `529-539`；术语见 `CONTEXT.md:236-246`（Channel halt / Channel pause / Channel block 三态定义） |
| 候选查询 + `candidate_limit=20` | **新仓库吃掉** | 分页/上限是防止「一轮扫太多张单」的防御性设计，概念可搬，具体上限是本仓库经验值，不必照抄 | `issue-agent.zsh:80-81, 587-599` |
| 依赖闸门：认领前查 GitHub native `blocked_by` | 见下方「GitHub 协议类」——这是对 GitHub 数据的**读取**，但触发的是调度决策，两个类目都沾边 | 判断「这单能不能开工」是调度职责，但查询手段（`repos/$repo/issues/$number/dependencies/blocked_by`）是 GitHub 协议 | `issue-agent.zsh:164-175`（`issue_is_blocked`）、注释引用 #113 |
| 按 native parent 分组、branch 名从 parent 派生（`slugify`） | 见下方「GitHub 协议类」 | 分组决策依赖 GitHub 的 parent 字段，命名规则是协议的一部分 | `issue-agent.zsh:177-206` |
| status 文件单行词表（`ok\|idle\|paused\|halted:*\|blocked:*\|error*`） | **新仓库吃掉** | 「观测不说谎」是本票口径下最值钱的设计遗产：新调度者不管用什么存储，都需要一套同等粒度、机器可读、每种跳过路径都留痕的状态词表 | `issue-agent.zsh:19-23`（文件头）, `671-678`（落盘） |
| `gh` 的有界重试（区分 transient 网络错误与真错误，不吞 stderr） | **改造后保留** | 只要新调度者仍然直接调 `gh`，这条重试纪律（区分 transient pattern、写 stderr 不污染 stdout、POST 类调用的幂等性论证）就该原样借鉴；具体 pattern 列表是本机代理环境的经验值，换机器/换代理要重新验证 | `issue-agent.zsh:92-128`；踩坑记录见 commit `726974b`（#? 间歇 TLS 超时）与 `26807c4`（#147 GraphQL 503 措辞） |
| 日志滚动（1MB 截断） | **废弃** | 纯运维细节，新仓库大概率已有自己的日志基础设施（swarm dashboard 的日志面），不构成需要专门迁移的职责 | `issue-agent.zsh:666-668` |

### git 操作类（在 Workspace 里做什么）

| 职责 | 去留 | 理由 | 证据位置 |
|---|---|---|---|
| Workspace 形态校验（`.git` 是文件即 worktree、origin 归一化比对 owner/repo） | **改造后保留** | 「校验工作副本确实服务本轮仓库」这条防御在多项目场景下更重要，但新仓库的 worktree 模型是「bare clone + 每角色一个 worktree」（`docs/vision.md:110-114`），不是「一个常驻 l2 实例绑一个 detached-HEAD workspace」，校验对象要换 | `issue-agent.zsh:267-275` |
| 脏工作副本检测（排除交付产物文件） | **改造后保留** | 概念普适（认领前必须确认没有别人的未提交改动），但排除清单（`.l2-result.json`、`.l2-task.txt`）是 l2ctl 专属产物，新仓库要换成自己的交付文件名 | `issue-agent.zsh:279-283` |
| `checkout_work_branch`（daemon 切分支，实例/角色不自己切） | **新仓库吃掉** | 这是 [ADR-0011](file:///Users/admin/project/pi-governance/docs/adr/0011-daemon-git-carve-out-on-unattended-workspace.md) 的核心机制保证：分支由派活方切好，执行体只在其上干活，「永不 merge」必须是机械保证而非 prompt 级约束——这条纪律对任何无人值守执行体都成立，新仓库应该原样吃掉这个**责任划分**（谁切分支），具体命令因 worktree 模型不同而要改写 | `issue-agent.zsh:297-307`；ADR 原文见上 |
| daemon 对 Workspace 持有的窄 git 权限（fetch / `checkout -B agent/*` / 只读查询 / `push origin agent/*`，禁碰默认分支、禁 merge、禁 force-push） | **新仓库吃掉** | 同上，这是机械化的安全边界设计，价值不依赖具体 runtime | ADR-0011 全文；push 落地在 `issue-agent.zsh:412` |
| 已 merge work branch 的自动回收（`reclaim_merged_branches`，只删自己命名规则下的分支，判据是 PR 的 `merged` 状态，删不掉记日志不阻塞） | **改造后保留** | 「谁产出的分支谁负责收」这条责任边界值得保留（不依赖仓库层 auto-delete，因为那个开关对人的 PR 也会生效），命名判据要换成新仓库自己的分支模式 | `issue-agent.zsh:208-257`；`branch_is_ours` 的正则：`issue-agent.zsh:215-217` |

### GitHub 协议类（跟 GitHub 打交道的契约本身）

问题 4 已经给出预判：**这一层最可能原样保留**——它是协议不是编排。逐项核实：

| 职责 | 去留 | 理由 | 证据位置 |
|---|---|---|---|
| Trigger label 状态机：`agent:go` →（认领）→ `agent:running` →（终态）→ `agent:done` / `agent:failed` | **原样保留（约定值不变，执行体换）** | 标签名和状态机是「跟仓库打交道的契约」，换掉背后的调度者不需要换标签语义；新仓库的 daemon 只要继续贴/摘同样四个 label 即可与既有 issue 历史、既有人类习惯兼容 | `issue-agent.zsh:63-66`（常量）, `147-157`（`claim_issue`/`finish_issue`）；术语定义 `CONTEXT.md:224-226`（Trigger label，明确与分诊结论 `ready-for-agent` 是两轨，不合并） |
| Work branch 命名：`agent/<parent issue number>-<slug>`，无 parent 退化为 `agent/issue-<n>`，同 parent 多单叠在同一分支共用一个 PR | **原样保留** | parent 是结构化字段、数字定身份、slug 只给人看——这条设计经受过「parent 标题后改不影响已建分支」的检验；新仓库若继续对接 GitHub native parent/sub-issue，没有理由发明新命名法 | `issue-agent.zsh:177-206`；术语 `CONTEXT.md:232-234`（Work branch） |
| PR 开法：同组复用已有 open PR（追加到 PR **描述**而非 comment，因为 `Closes` 关键字只在描述/commit message 生效）、`Closes #N`、"人工 review 后再 merge" 的免责声明 | **原样保留** | `Closes` 语义是 GitHub 平台事实，`run-issue.sh` 也独立踩过同一个坑（见 Q6 对比）；这是协议层面双方都验证过的正确写法，没有理由重新发明或退化 | `issue-agent.zsh:415-438` |
| Issue comment 回流（完成/失败两种模板，附执行结论） | **原样保留** | 让人不用进 PR 也能看到「发生了什么」，是无人值守场景的最低可观测性要求，跟执行体是谁无关 | `issue-agent.zsh:448-486` |
| 依赖闸门查询：GitHub native `blocked_by` REST 端点 | **原样保留** | 「查不到答案宁可不做」与「用结构化字段而非人工提 label」这条设计（#113 第 3 点）是协议层面的正确用法，新调度者一样要遵守 native dependency 而不是发明自己的 blocker 标签 | `issue-agent.zsh:164-175` |
| `gh_retry` 的 transient 错误模式清单（TLS 超时、503/504、GraphQL 措辞差异） | **改造后保留** | 协议层面的「哪些 gh 失败是安全重试的」这条知识值得继承，但具体网络环境（本机→unified proxy→GitHub 的 3-8% 间歇失败率）是这台机器的经验值，换机器要重新测 | `issue-agent.zsh:92-128`；数据来源 `research/issue-agent-polling-vs-webhooks.md` |
| 分支回收使用 GitHub REST API（`repos/$repo/branches`、按分支查 `merged` 状态的 PR、`DELETE git/refs/heads/*`）而非本地 git push --delete | **原样保留** | 用 API 而非本地 git 操作，是为了让「删除」这个动作可审计、可重试、不依赖本地 remote 状态是否新鲜；协议选型正确，值得继承 | `issue-agent.zsh:221-257` |

### l2 实例生命周期类（怎么让常驻 Pi/Claude 实例干活）

| 职责 | 去留 | 理由 | 证据位置 |
|---|---|---|---|
| `instance_workspace` 路径解析（`$L2_RUNTIME_HOME/<id>/workspace`） | **废弃** | 新仓库不使用 `l2ctl`/`$L2_RUNTIME_HOME` 这套运行根，完全是 pi-governance 自己的部署形态 | `issue-agent.zsh:261-263`；运行根定义见 `CONTEXT.md:85-96` |
| `render_prompt`：带引号 heredoc 防止 issue 正文被 shell 二次求值（#135 事故：不加引号时模板里的反引号被当命令替换执行） | **设计教训，非代码迁移** | 具体实现（zsh 带引号 heredoc）绑死这套 shell 脚本，但踩过的坑是通用的——**任何**把不可信文本（issue 标题/正文）拼进要执行的任务文件的地方都有同样风险；新仓库若也是「把 issue 正文喂给某个 agent 的任务文件」，需要独立验证自己的拼接路径有没有同样漏洞，不能假设「用了别的语言就没事」 | `issue-agent.zsh:318-348`（注释 320-324 直接引用 #135）；对照 `run-issue.sh` 用 `%q`/`printf '%q'` 转义外部输入（`run_remote`/`in_root` 注释，`run-issue.sh:178-187`）——两边独立收敛到同一条原则：不可信文本必须转义或隔离，不能裸拼进要执行的字符串 |
| `dispatch_and_wait`：调 `l2ctl dispatch` 后轮询 `l2ctl status`，解释退出码 0=结果就绪/2=会话死/3=交付契约违反（连续 N 轮静止）/5=超时 | **废弃** | 退出码语义完全绑定 `l2ctl` 自己的实现（`scripts/l2ctl.zsh:340-393` `cmd_status`：`state=result/dead/running/silent`），新仓库没有 l2ctl 就没有这套退出码可解释 | `issue-agent.zsh:351-369`；对照 `scripts/l2ctl.zsh:340-393` |
| `preflight_instance`：认领前 `l2ctl check`，退 3（drift）自主 refresh+stop，退 4（runtime-mismatch）停摆报人 | **废弃（但决策原则可参考）** | 同上，绑定 l2ctl/deploy.zsh 的检查体系（`scripts/l2ctl.zsh:771-782`）；但「机械可修的漂移自己修，需要人决定的（销毁重建）报人不动手」这条判断原则，是任何长期运行的执行体宿主都会遇到的问题，值得作为设计参考而非代码参考 | `issue-agent.zsh:499-522`；对照 ADR-0009「机器面今天没有销毁入口……是人的决定」 |
| `l2ctl read` 拉取交付摘要（`tail -40`） | **废弃** | 同样绑定 l2ctl 的结果文件契约 | `issue-agent.zsh:395` |
| Issue-runner 模板本身（`instance_kind: unattended`、`permissionMode: bypassPermissions`、`WebFetch`/`WebSearch` 硬拒绝、只准写 `.l2-result.json`） | 见 Q3 | 这是 pi/Claude Code 特定的 agent 部署声明，见下文单独展开 | `config/l2/templates/issue-runner.md` |

## 逐条展开

### 1. 职责清单（汇总说明）

见上表。四大类里，**GitHub 协议类**几乎全员「原样保留」（标签值、分支命名模式、PR/Closes
惯例、依赖查询手段、gh 错误重试的错误分类原则），**l2 实例生命周期类**几乎全员「废弃」
（因为退出码语义与结果文件契约完全绑死 `l2ctl`），**调度类**多数是「新仓库吃掉」——概念
必须搬（一次一单、halt/pause、观测词表），但载体（launchd 锁文件、单仓库清单）要按新架构
重做，**git 操作类**多数是「改造后保留」——责任边界（谁切分支、谁能删分支、脏工作副本判据）
是普适设计，但落地对象要从「detached-HEAD 的 l2 workspace」换成 swarm-forge 的 worktree
模型。这印证了 issue 本身的预判：四类的去留确实不一样，而且不一样的方式还挺系统——离
GitHub 越近的职责越稳定，离 pi/l2ctl 运行时越近的职责越要推倒重来。

### 2. 认领前的前置检查

`poll_once` 按固定顺序逐条检查，命中即返回并落对应 `round_state`，顺序本身是
spec 定死的（`issue-agent.zsh:19-23` 注释；对照 `openspec/specs/issue-agent/spec.md`）：

| 顺序 | 检查 | 挡的是什么事故 | 位置 |
|---|---|---|---|
| 1 | `halt_file` 存在 | 交付契约已被违反过一次，继续认领会用同一个故障把整个队列烧成 failed；必须人删标记或 `channel resume` 才恢复 | `issue-agent.zsh:529-533` |
| 2 | `pause_file` 存在 | 人主动要求停止认领（已在跑的单不受影响），与 halt 是两个独立标记 | `issue-agent.zsh:535-539` |
| 3 | 仓库清单非空 | 未配置仓库时不该报错，只是空转 | `issue-agent.zsh:541-543` |
| 4 | 常驻实例的 workspace 目录存在 | daemon 不自建工作副本（那是 `l2ctl deploy` 的职责，#123 的顺序依赖），目录缺失意味着实例还没部署，不能替它建 | `issue-agent.zsh:545-551` |
| 5 | workspace 的 origin 与本轮某个已声明仓库匹配（`workspace_serves_repo`） | 防止把一个实例的 workspace 误用于另一个仓库的单；比较的是 owner/repo 段，兼容三种 URL 写法 | `issue-agent.zsh:267-275, 553-564` |
| 6 | workspace 干净（排除交付产物文件） | 「脏」= 有人的东西在里面；实例自己上一单遗留的结果文件不算脏，否则第一单跑完通道就永远停摆 | `issue-agent.zsh:279-283, 566-570` |
| 7 | `preflight_instance`（`l2ctl check`） | 常驻实例配置漂移（可自动 refresh 修）或 runtime 不符（需要人销毁重建）；check 不是认领闸门，不可用时留痕照常认领 | `issue-agent.zsh:499-522, 572-575` |
| （回收，非闸门） | `reclaim_merged_branches`，排在所有闸门之后、认领任何单之前 | 回收要调 GitHub API，提前做就破坏了「实例缺席或对不上仓库时本轮一步不碰 tracker」这条既有契约 | `issue-agent.zsh:577-582` |
| 8 | 依赖闸门（native `blocked_by`，逐候选单检查） | 人一次放行一整组带依赖的 ticket，顺序交给机器判，而不是让人盯着逐张提升 label | `issue-agent.zsh:601-612` |

### 3. `issue-runner` 模板的硬约束

来源 `config/l2/templates/issue-runner.md`（47 行）：

- `instance_kind: unattended`（frontmatter L4）——决定它是「不逐单建立、Agent Workspace
  停在 detached HEAD、每单的 Work branch 由 daemon 派活前切好」这一类实例，与人指派实例
  （`assigned`，终身绑一条自己的分支）互斥，两种约定不共存于同一实例（`CONTEXT.md:41-47`
  Unattended instance 词条）。
- `permissionMode: bypassPermissions`（L7）——除硬拒绝外全部自动批准，不弹提示、不等人；
  文档原话「代价是没有第二道闸门替你兜底：每一次调用的后果都会真的发生」（`issue-runner.md:36-38`）。
  这是无人值守的必然要求：没有人在场按确认键。
- `disallowedTools: [WebFetch, WebSearch]`（L18-20）——**硬拒绝**，即使在
  `bypassPermissions` 下也不放行；理由是「无人值守下没有人能判断一次外网取回的东西该不该信」
  （`issue-runner.md:40-42`）。这是无人值守场景特有的信任边界：任务文本可信（来自受
  branch-protection 保护的 issue tracker），但执行期间临时抓取的外部内容不可信。
- 只准写 `.l2-result.json`，`status` 取 `ok`/`failed`，没有这个文件外层判「交付契约被违反」
  （`issue-runner.md:44-47`；机制侧对应 `l2ctl.zsh:390-392` 的 `state=silent`，退出码 3）。
  这是**唯一的**上行通道——ADR-0008「交付只走结果文件」：「屏幕不是通道……画面只能原样转交给人，
  不被解释、也不用来判断任务成败」。

为什么是这些：全部可以追到「无人值守 = 没有人能实时纠错」这一个源头——不能等人批权限
（`bypassPermissions`）、不能信外部内容（硬拒绝 WebFetch/WebSearch）、不能靠读屏幕判断
成败（唯一交付通道是结果文件）。三条约束互相独立地服务同一个前提，没有一条是可选的。

### 4. GitHub 侧的协议

已在核心表「GitHub 协议类」逐项列出。与 GitHub Actions 的分工：`docs/github-workflow.md`
定义的 Merge gate（`lint-specs` + `smoke-gate`，跑在自托管 macmini runner 上）和 unattended
channel 是**两个独立的东西**，`CONTEXT.md:211-222`（Merge gate 词条）专门写明「不要用『CI』
一个词盖住两者：通道产出 PR，门禁决定 PR 能不能进」——通道跑在贴了 `issue-agent` 角色的机器上、
永不 merge；门禁跑在 GitHub Actions runner 上、不认领也不派活。两者共用同一台 macmini 纯属
机器复用，不是同一层。这个分工关系本身就是「新仓库要不要吃掉」这个问题的一个天然边界：
**通道要不要换（本票主题），门禁不受影响**——不管谁负责认领和派活，PR 一样要过
`lint-specs`/`smoke-gate` 才能进 `main`（`docs/github-workflow.md:8-14`）。

### 5. 现在在生产里跑着什么

- **承担机器**：`config/machines.list` 标 `macmini` 为 `issue-agent` 角色（全机队至多一台，
  由 `hostname -s` 与清单比对得出，不再靠 `machine.env`——那份不入库，重装机器会静默丢失）。
- **目标仓库**：`config/issue-agent-repos.list` 目前只有一行 `arlishansenn/pi-governance`——
  也就是说，这套通道现在只对**它自己所在的仓库**生效，是自举式的日常开发流程，没有服务
  别的项目。
- **跑了多久**：代码首次出现于 `9146426`（2026-08-10，#99 修订），最近一次改动
  `17f7ba6`（2026-09-02，#227 运行根收编）。真实产出证据（`gh issue list --label agent:done`）：
  最早 2026-08-10（#109/#110），最近 2026-08-21（#220），跨度约 11 天，共 7 张 `agent:done`
  的 issue；另有 2 张 `agent:failed`（#146、#148）。**2026-08-21 之后到今天（09-21）
  没有新的 `agent:done`/`agent:failed`——未找到记录说明这段时间通道是被 pause 了、
  没有 issue 贴 `agent:go`，还是有别的原因**，本文档只如实报告这个空档，不猜测。
- **事故记录**：`agent:done` 里有三张本身就是修这套通道自己的事故——#149（分支回收因
  `gh api repos/<repo>/branches` 恒定 404 从未生效）、#150（认领失败的一轮仍把 status
  写成 `ok`，违反「观测不说谎」）、#135（README 未写清执行体实例名与覆盖方式，同时是
  #135 那次 heredoc 转义事故的档案号）。另有 commit 级事故记录：#147（gh 的 GraphQL 503
  措辞与 REST 不同，只匹前者导致重试实际只生效一次）、#180（连续静止判定阈值从「单次」
  改为「N 轮」）。ADR 记录见 ADR-0009/0011/0012（daemon 的 git 权限与调用方身份）。
- **停机窗口**：由于目标仓库只有 pi-governance 自己一个、且认领节拍是 5 分钟一轮
  （`launchd`），切换/停用这套通道的影响面很小——把 `config/machines.list` 里
  `macmini` 的 `issue-agent` 角色摘掉，或者对通道说 `channel pause`，新增的
  `agent:go` label 就不会被认领，已在跑的单跑完不受影响（`CONTEXT.md:240-242`
  Channel pause 词条）。**没有找到证据表明有除 pi-governance 自己之外的项目依赖它**，
  因此对新仓库来说，这更像是「把一套验证过的设计迁移走」而不是「小心翼翼地不打断一条
  生产管线」。

### 6. 与 `swarmforge-operator` 的 `run-issue.sh` 对比

两者确实是同一类问题（把一张 GitHub issue 无人值守地跑通到一个可 review 的 PR）的两个
独立实现，但架构假设完全不同：

| 维度 | `issue-agent.zsh`（pi-governance） | `run-issue.sh`（本 fork operator） |
|---|---|---|
| 触发方式 | 主动轮询带 `agent:go` label 的 issue 列表（poll，push 式认领） | 被调用方直接指定一个 issue 号，一次调用只处理一单（拉式，调用方决定跑哪张） |
| 执行体 | 常驻 `l2-agent` 实例（tmux 会话 + `l2ctl dispatch/status`），本机 GUI login session 域 | swarm 的角色链（coder → cleaner 等），经 SSH 到 `TARGET` 主机 + `pack_web` 的 HTTP API（`.swarmforge/board/tasks.tsv`、`/api/tasks`、`/api/state`） |
| 完成判据 | `l2ctl status` 的退出码 + 结果文件 `.l2-result.json` | Board 上的 lane 是否变成 `done`（`run-issue.sh:463-465` 明确写「The Board lane is the ONLY completion judge」），再靠 `accept-work.sh` 解析 delivery record 拿 commit |
| 分支/PR | 按 native parent 分组、daemon 切分支、同组复用 PR，`Closes #N` | 按 issue 号+slug 生成分支名（`feat/issue-<N>-<slug>`），BASE 取「最新 open PR 的 head」而非固定 `main`（服务 podsum 那种线性 `blocked by` 依赖链），PR body 显式要求由读过 diff 的主体（建议派 `to-pr` skill 的 subagent）写，脚本自己只写 `Closes #N`/`task`/`commit`/`completed_at` 这些下游要解析的字段 | 
| 幂等/续跑 | 单轮内一次性跑完（成功/超时/静止三态之一），没有「同一张单第二次调用」的续跑设计——重试是靠下一轮轮询自然重来 | 显式 RESUMABLE 设计：card/branch/PR 三个独立标记逐个读，覆盖 `--max-wait` 被杀掉后重跑的场景（`run-issue.sh:15-59` 大段头注释） |
| 阻塞处理 | 依赖闸门在**认领前**查 native `blocked_by`，闸门内 issue 直接跳过不认领 | `refuse_if_blocked` 在跑之前和轮询中都查 swarm 的 clarification/approval 队列，命中就直接 `UNSAFE` 退出，不无限空转 |
| 不可信文本处理 | 任务模板用带引号 heredoc，issue 正文原样代入但不经 shell 二次求值（#135 修复） | 所有拼进远程命令的外部输入一律 `printf '%q'` 转义（`run_remote`/`in_root` 一节注释），同一条原则的另一种实现 |
| 组织形态 | 中心化：一个仓库、一个常驻实例、一个 daemon | 分布式/多机：`--root`/`--target`/`--local` 参数化，天然服务多个被管项目（`podsum` 是实测案例） |

**能借鉴的设计教训**（CLAUDE.md 已裁定 `swarmforge-operator` 这套本身不跟进，但机制层面
的判断仍然成立）：
1. **完成判据必须是一个单一、机器可读、有名字的信号**，不能靠猜——`issue-agent.zsh` 用
   `l2ctl status` 退出码，`run-issue.sh` 用 Board lane，两者都明确拒绝「读屏幕/读进程状态」
   这类不可靠信号。
2. **两个异步事件之间的窗口要显式处理，不能假设同步**——`run-issue.sh` 专门处理「Board
   lane 已 `done` 但 delivery record 还没落盘」的窗口（issue #63），`issue-agent.zsh`
   对应处理「`l2ctl status` 静止但还没到结果文件」的窗口（连续 N 轮阈值，#180）。这是同一
   类问题在两套系统里各自独立踩出来的坑。
3. **不可信文本必须转义/隔离**，参见上表最后一行——两边独立收敛到同一原则。
4. **阻塞判据要显式查询，不能靠超时空转**——两边都有「认领前查一次、跑的过程中还要再查」
   的模式（`issue_is_blocked` vs `refuse_if_blocked`）。

### 7. 不该被吃掉的部分

`scripts/join-project.zsh`、`scripts/deploy.py`、l1-l2 部署这套，与 unattended channel
的关系是**依赖而非重叠**：

- `join-project.zsh` 只做「让治理开始参与一个项目」这一件事——建立 Canonical clone 与
  l1 的 Agent Workspace worktree（`scripts/join-project.zsh:1-144` 全文；`CONTEXT.md:201-203`
  Joined project 词条）。它跟 unattended channel 之间**没有直接调用关系**：`issue-agent.zsh`
  全文没有出现 `join-project`，channel 依赖的是「常驻实例的 workspace 已经存在」这个前提
  （`issue-agent.zsh:545-551` 明确「daemon 不自建工作副本，那条线归 l2ctl deploy」），而
  workspace 存在的前提又是这个项目已经被 `join-project` 接入过（否则连 Canonical clone
  都没有，`l2ctl deploy` 也无从下手）。也就是说：**channel 依赖 deploy，deploy 依赖
  join-project，但 channel 不直接依赖 join-project**——是一条传递依赖，不是同一层。
- `deploy.py`/`l2ctl.zsh` 物化并检查 `l2-agent` 实例（`AGENTS.md` Resource map:
  「物化、检查并就地刷新隔离的 l2-agent runtime instance」）。daemon 是它的**第二个
  程序调用方**（ADR-0012 明确裁定），但只调用其中 `dispatch`/`status`/`read`/`check`/
  `refresh`/`stop` 六个动词（`issue-agent.zsh:353,357,395,501,506,510`），且这六个动词的
  语义完全由 `l2ctl.zsh` 自己定义，channel 只是消费方。
- **新仓库会不会必须继续依赖它们**：不会，前提是新仓库不使用 `l2-agent`/`l2ctl` 这套
  runtime——ADR-0027 已经确认「多 agent 干活的编排改由 swarm-forge 承担」，swarm-forge
  自己的 worktree/角色模型（bare clone + 每角色一个 worktree，`docs/vision.md:110-114`
  「运行层协调模型」一节，标注为 operation 层约定而非治理机制）与 `l2ctl` 是两套并行、
  不共享代码的机制。**换句话说：`join-project`/`deploy.py` 不是「不该被吃掉」意义上
  「必须留着当地基」，而是「跟本票问题（unattended channel 的去留）压根不在同一条依赖链
  的下游」——新仓库如果吃掉了 unattended channel 的调度职责，并不会因此对 `deploy.py`
  产生新的依赖；它们原本服务的是 pi-governance 自己的 l1/l2 编排（已被 ADR-0027 搁置），
  与 swarm-forge 的编排是平行世界。

## 迁移路径草图与风险

**草图**（按核心表的判断，从最稳定到最不稳定排序）：

1. **先把 GitHub 协议原样搬进新仓库的调度者**：四个 label 值、`agent/<parent>-<slug>`
   命名模式、PR 复用+`Closes`惯例、native `blocked_by` 依赖查询、`gh` 的 transient 错误
   分类原则。这一步几乎是抄作业，风险最低，因为协议层不依赖 l2ctl。
2. **重建调度骨架**：轮询/认领节拍、halt/pause 语义、观测词表、一次一单（或按新仓库的
   多项目并发模型放宽），但存储介质、锁机制换成新仓库自己的运行时约定。
3. **重建 git 操作层**：把「daemon 切分支、执行体只在其上干活、永不 merge 是机械保证」
   这条 ADR-0011 的责任划分，对应到 swarm-forge 的 worktree 模型上——谁扮演旧架构里
   「daemon」的角色（现在看应该是 lieutenant 或某个角色专属脚本），谁负责 fetch/checkout/
   push，禁止面要不要收窄到某个角色而不是全体。
4. **彻底不迁移 l2 生命周期代码**，只带走两条设计原则：不可信文本必须转义/隔离
   （#135 教训）、机械可修的漂移自己修/需要人决定的报人不动手（ADR-0009 的判断原则）。
5. **`issue-runner` 模板的三条硬约束按等价问题重新推导**，不要照抄字面配置——新仓库的
   执行体如果也是无人值守、也没有人实时纠错，那「不能等人批权限」「不能信外部抓取内容」
   「唯一交付通道」这三个源头问题依然成立，需要按新仓库自己的 harness（Claude Code /
   其他）重新定位对应的配置项。

**风险**：

- **协议层「原样保留」的前提是新仓库继续使用 GitHub issue + native parent/dependency
  作为任务来源**。如果新仓库的任务来源换成别的（例如完全走 swarm 自己的 Board，像
  `run-issue.sh` 那样），那么「原样保留」这条判断整体不成立，需要重新设计任务分组和
  依赖表达方式——这正是 Q6 对比表里两条不同路线的分歧点，属于本票范围之外的架构选择，
  但会直接决定这份迁移草图第 1 步能不能真的照搬。
- **生产空档未解释**（2026-08-21 之后没有新的 `agent:done`/`agent:failed`，见 Q5）。
  在迁移前应该先确认这不是因为通道已经因为某个未记录的原因停摆——如果是停摆状态，
  「原样保留」的协议惯例可能已经过时或被绕过，需要先核实现状再迁移，而不是假设
  文档描述的行为就是现在的行为。
- **「新仓库吃掉」调度类职责时容易把「一次一单」这条全局硬约束带过去**，但新仓库
  天然多项目/多角色并发，如果照搬全局串行会浪费掉新架构的并发能力；反过来完全去掉
  它又会失去「同一工作副本不被两轮同时派活」这条保护——需要新设计一套「并发单位是什么」
  的判断（大概率是「每个 project swarm 内部一单，跨 project 可并发」），这条设计本身
  不在 pi-governance 的既有代码里，是新仓库需要自己补的空白，不是「吃掉」能解决的。
- **`gh_retry` 的 transient 错误模式列表是这台机器的经验值**（本机→unified proxy→
  GitHub 的间歇失败率，`research/issue-agent-polling-vs-webhooks.md`），换机器/换网络
  环境后这份清单需要重新验证，不能假设新仓库运行的机器有同样的网络特征。
