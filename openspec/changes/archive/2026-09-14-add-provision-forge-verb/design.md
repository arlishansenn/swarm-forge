## Context

upstream README 的 forge 流程是五步：装 helper、装 forge、`./swarm`、dashboard 上
New Project、dashboard 上 New Task。本 fork 今天没有任何一个 verb 覆盖它——
`swarmforge-operator` 的十二个 verb 全部假设「被管 project 已经存在并且已经装好了」，
而 forge 那条路是从**空目录**开始的。

operator 今天只能照 README 手敲，于是每敲一次就重新暴露三个陷阱：

1. **来源。** README 第 2 步的 URL 指向 `unclebob/swarm-forge`。从那棵树装出来的 forge
   缺 D-1（收件箱按 `roles.tsv` 解析）与 D-5（handoffd 对账与重试），handoff 链在唤醒键被
   TUI 吞掉时静默卡死。ADR-0001（决定仍在效）与 ADR-0002（实现手段）说的就是这件事。
2. **启动。** 第 3 步的 `./swarm` 从 ssh 会话裸跑，`detect-terminal-backend` 会因为
   `osascript` 存在而选中 `terminal-app`，背后没有真实 window，watchdog 几秒内拆掉整个
   forge（issue #10，已复现两次；issue #26 造 `start-swarm.sh` 正是为此）。
3. **manifest。** `get-swarm-forge` 装完 forge，`swarmforge/scripts/` 立刻存在而
   `.swarmforge/scripts-manifest` 从不存在。`start-swarm.sh:196-208` 把这个组合读作
   INCOMPLETE（`SNAPSHOT_PRESENT=1` + `MANIFEST_PRESENT=0` + `PROJECT_OWNED=0`），以
   `4` `DRIFT` 拒绝。**今天任何一个 forge 都只能靠 `--force` 启动**，而 `--force` 同时关掉
   issue #29 建立的 digest 校验。

在效的 ADR（按 Supersedes 链算）：0001（决定在效，实现手段被 0002 取代）、0002、0003、
0004、0005。本设计与这五条一致，不需要 supersede 任何一条。

## Goals / Non-Goals

**Goals:**

- 一条命令走完 upstream README 第 2–4 步，并在实现里吃掉上面三个陷阱。
- 让 forge 第一次成为 `start swarm` 眼里的 MANAGED 状态，`--force` 退回到它本来的例外地位。
- 改动全部落在**新文件**里，`get-swarm-forge` 与 `start-swarm.sh` 一行不动。

**Non-Goals:**

- 第 5 步 New Task。`run issue` 已经是驱动任务的 verb。
- `start-swarm.sh` 的 `SWARMFORGE_OPEN_BROWSER` passthrough。forge 启动时仍会尝试 `open`
  一个浏览器，那是噪音不是缺陷，且属于 `swarm-start-safety`。
- 让 `update SwarmForge scripts` 认识 forge。它今天更新的是被管 project 的 snapshot；forge
  的 snapshot 更新是另一个 verb 的题目。
- 端口分配自动化。`7780`-`7789` 那张表是手工约定，没有东西推导或强制它，本次也不改这一点。

## Decisions

### 决定 1：verb 叫 `provision forge`，覆盖第 2–4 步

既有十二个 verb 里，十一个是 `<single verb> <noun>`（`onboard project`、`open swarm`、
`start swarm`、`read swarm`、`wake role`、`talk role`、`accept work`、`run issue`、
`stop swarm`、`attach role`、`update SwarmForge scripts`），第十二个 `dashboard` 是个裸
noun。**没有一个是 phrasal verb**，所以新 verb 也不能是。

`onboard project` 已经占了「装东西进一个目录」这个名字，而 `docs/fork-deltas.md` 明写它是
upstream 当年没方案时的临时做法。两者的对象也不同：`onboard project` 装 pack 进一个**已有
的 product 仓库**，`provision forge` 从空目录建一个**能装很多 product 的 forge**。
`provision` 在 ops 里的意思正好就是「造出来并弄到可用」，一个词覆盖装、起、建第一个
project 这三件事。

两个更顺口的备选都有具体缺陷，不是输在语感上：

- **`start forge`** —— 与既有 `start <noun>` 模式完全吻合，但和 `start swarm` 在同一个条件
  上的行为相反：`start swarm` 撞见已在跑的 swarm 是 `6` `UNSAFE` 且无 override，而本 verb
  撞见已在跑的 forge 要跳过启动继续往下走（决定 6 的可续跑语义）。同一个动词、同一个
  条件、一个拒绝一个放行，是给读的人埋雷。
- **`bootstrap forge`** —— `bootstrap` 在这个 skill 里已经是一个**状态名**：
  `start-swarm.sh` 的 `FRESH_BOOTSTRAP` 指 launcher 自己首跑时下载 snapshot，`SKILL.md`
  与三个 `test-*.sh` 都按这个窄义在用。拿它当 verb 名会让同一个词在同一份文档里指两个
  范围不同的东西。

覆盖到第 4 步而不是第 3 步，因为第 3 步的 `./swarm` 只起 dashboard 与 host lieutenant，
**不起任何 project agent**。停在第 3 步交付的是一个空 forge，operator 还得再走一趟
dashboard。第 4 步的 `POST /api/projects` 内部就是 `forge/instantiate!` 加
`forge/open-project!`（`pack_web.bb:1707-1711`），project 的 swarm 在那里才被拉起——这才是
一个可以开始干活的状态。

另一个备选是拆成 `install forge` 与 `open project` 两个 verb。否掉的理由是这两步之间有一个
必须等待的窗口（dashboard HTTP 就绪），拆开就等于把这个等待交给人，而人会以为
`STATUS=STARTED` 就是可以 POST 了。

### 决定 2：manifest 由这个 verb 写，不改 `get-swarm-forge`，也不改 `start-swarm.sh`

三条路都能让 forge 不再 DRIFT：

| 路 | 做法 | 否掉的理由 |
|---|---|---|
| A | `get-swarm-forge` 装 forge 时写 manifest | 它是 `main` 上 upstream 也拥有的安装器，改它每次 merge 都是冲突面；而且它还装 pack，pack 路径今天**刻意**不写 manifest（FRESH 状态），一起改会动到 `onboard project` 的语义 |
| B | `start-swarm.sh` 认第四种形状（`projects/` 存在 ⇒ forge），跳过 digest 校验 | 把「检查不了」写成「不检查」。forge 的 `swarmforge/scripts/` 正是 D-9 最该盯的那棵树，一棵损坏的 forge 树会静默启动 |
| **C（选中）** | **`provision-forge.sh` 装完之后自己写 manifest** | — |

C 是最小的 diff，也是唯一让 digest 校验**活下来**的一条。`start-swarm.sh` 的三态判定本身
是对的，缺的只是一个 writer；`update-swarmforge-scripts.sh` 已经证明这个角色是「装树的人
顺手写」而不是「启动的人事后猜」。digest 用 `lib-wake-talk.sh` 的
`remote_scripts_digest`，manifest 格式沿用 `SOURCE_COMMIT=` / `SOURCE_REPO=` / `DIGEST=`
三行，`read_manifest` 只认 `DIGEST=`。

`SOURCE_COMMIT` 写什么：`get-swarm-forge` 走的是 `archive/refs/heads/<ref>.tar.gz`，tarball
不带 commit id。写 `SOURCE_REPO=<repo_url>#<branch>`、`SOURCE_COMMIT=unknown`。这不是偷懒
的遗憾——`read_manifest` 从来只读 `DIGEST=`，另外两行是给人看的出处记录。

### 决定 3：来源自证靠内容判据，不靠参数回显

「我传了 `arlishansenn` 所以装的就是 fork」不是证据。判据必须落在**落地的文件内容**上，
而且必须是「换成 upstream 的版本就会失败」的形状：

- `swarmforge/scripts/handoffd.bb` 含 `reconcile-once!` —— D-5 的标记。
- `swarmforge/scripts/handoff_lib.bb` 含 `roles.tsv` —— D-1 的标记（upstream 的
  `inbox-dir` 用进程 cwd，不读 `roles.tsv`，issue #45）。

文件是否存在不是判据：`handoff_lib.bb` 与 `handoffd.bb` 在 upstream 也有，只是内容不同。
两个 grep 各钉一条 delta，两条都不过就在**起 forge 之前**失败。

天花板要说明白：这是两个 marker，不是全树等价性证明。upstream 哪天自己加了同名函数，判据
就会误判为 fork。真正的等价性证明要拿本 fork 同一分支的 tarball 重新算一次 digest 做比对，
那是一次多余的下载；等到 marker 真的失效再换。

### 决定 4：启动委托 `start-swarm.sh`，`--terminal` 由调用方传，默认 `none`

`provision-forge.sh` 自己绝不拼 `ssh` + `nohup ./swarm &`。它调 `start-swarm.sh`，因而白拿
detached 启动、readiness 轮询、project 锁与「已在跑就拒绝」那道闸。`--terminal` 在
`start-swarm.sh` 里是必传的，这里也照样必传，只是给一个 `none` 默认——forge 跑在远端主机上，
没有人会去看它的终端窗口，而 `auto` 恰恰是 issue #10 的复现路径。

manifest 在启动**之前**写：写晚了 `start-swarm.sh` 就会先看到 INCOMPLETE。

### 决定 5：New Project 走 `127.0.0.1` 上的 dashboard HTTP API

生产 `pack_web.bb` 的 `-main` 只认 `--serve`；`--test-new-project` 一类 flag 只在
`test/swarmforge/pack_web_test.bb:49` 被 dispatch。直接 `bb forge.bb` 调
`instantiate!` 也不行——`open-project!` 需要跑着的 forge 的状态（open-projects 记录），
绕过 HTTP 就等于让两个写者同时改同一份状态。所以 HTTP 是唯一支持路径。

dashboard 绑 `127.0.0.1` 是有意的，所以这个 verb `ssh` 进目标主机在本地 `curl`。
README 那条「绝不用其它方式把 dashboard 暴露出去」禁的是**对外暴露**，主机内自访不在其内；
这个 verb 不建隧道、不写 `tailscale serve`、不碰 `pack_web` 绑什么。

### 决定 6：按阶段可续跑，不新增退出码

装、起、建三个阶段各自先问「已经做过了吗」：

| 阶段 | 已完成的判据 | 已完成时 |
|---|---|---|
| 装 | forge root 有 `swarm` 与 `swarmforge/scripts` | 跳过，`WARN=`；manifest 缺失则补写 |
| 起 | `tmux-socket` 有活 server（与其它 verb 同一次探活） | 跳过，`WARN=` |
| 建 | `projects/<name>` 已存在 | `6` `UNSAFE`，零改动 |

于是「被中断了怎么办」的答案是**同一条命令再跑一遍**，不需要 `--resume`，也不需要新的
STATUS 词。`6` `UNSAFE` 用在 project 重名上与 `start swarm` 的「已在跑」同源：真实状态与
记录一致，只是这件事必须由人决定。

### 决定 7：两次 readiness，第二次复用 `open-dashboard.sh` 的握手预算

`start-swarm.sh` 的 readiness 只保证 tmux socket 上有 server（60 次 × 1s），**不保证
HTTP 端口在听**。POST 之前还要等 `.swarmforge/dashboard-url` 出现并且那个端口握手成功。
预算直接照抄 `open-dashboard.sh` 的 20 次 × 0.5s——那份预算等的正是同一件事（一次 TCP
握手），不新造一套数字。

## Risks / Trade-offs

**来源 marker 会随 upstream 漂移** → upstream 加了同名函数就误判为 fork。判据写在一处、
带注释点名天花板；`bb test` 的 fork-delta spec 会先于它失效被发现（D-1/D-5 各自有 spec）。

**manifest 的 `SOURCE_COMMIT=unknown` 让出处不可追** → 只影响人读，`read_manifest` 只读
`DIGEST=`。要可追就得放弃 tarball 改用 `git clone`，代价远大于收益。

**forge 的 snapshot 更新之后 manifest 会过期** → 那时 `start swarm` 会正确地报
`4` `DRIFT`，这正是想要的行为。今天没有「更新 forge snapshot」的 verb，所以恢复手段是
重跑本 verb 的安装阶段；这个缺口在 `## Open Questions` 里点名。

**`7782` 是手工分配的** → 那张表没有任何东西推导或强制。本 verb 要求调用方显式传
`--dashboard-port`，不猜；忘了传就是随机端口，`dashboard --tailnet` 用不了。

**一次完整 provision 会在目标主机上真的起进程** → 测试脚本必须能在不起真 forge 的情况下跑
argv 与状态机断言（沿用 `start-swarm.sh` 的 `SWARM_LAUNCHER` stub 思路），真装真建那一次
留给人工验收。

## Migration Plan

不涉及既有 project 的迁移：这是一个新 verb，新脚本，新 capability。

已经存在的、靠 `--force` 启动的 forge（如果有）可以手工补一份 manifest 回到 MANAGED——
digest 就是 `scripts_digest swarmforge/scripts` 的输出。本次不为此写迁移脚本，因为
macmini 上今天只有 podsum 一个装了 SwarmForge 的目录，而它是 pack 不是 forge。

回滚：删掉 `provision-forge.sh` 与它那节 `SKILL.md` 即可，没有任何既有 verb 依赖它。

## Open Questions

- **forge 的 snapshot 怎么更新？** `update SwarmForge scripts` 今天只认被管 project。
  forge 装好之后本 fork 的 `main` 往前走了，forge 的 snapshot 就旧了，而现在它有 manifest，
  所以 `start swarm` 会正确地拦住它。恢复手段目前是重跑安装阶段。这值得单开一张票，不在
  本次范围内。
- **`lieutenant` 分支的 fork 差异刚移植完、还没在真 forge 上跑过。** 如果验收时拿
  `lieutenant` 当对象出了问题，先怀疑移植而不是本 verb。建议验收用 `project-manager`。
