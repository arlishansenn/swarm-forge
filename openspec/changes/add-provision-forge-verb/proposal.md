## Why

upstream README 的「装 helper → 装 forge → `./swarm` → New Project」这条路今天在本 fork
上一条都不能照抄：第 2 步的 URL 指向 `unclebob/swarm-forge`，装出来的 snapshot 没有 D-1/
D-2/D-3/D-5，handoff 链会**静默**卡死（D-9、ADR-0001/0002 要堵的正是这个）；第 3 步的
`./swarm` 从 ssh 会话裸跑会被 window watchdog 在几秒内拆掉整个 forge（issue #10，手工操作
下已复现两次，issue #26 造 `start-swarm.sh` 就是为此）。

于是 operator 今天只能一条条手敲，每敲一次就重新暴露一次这两个陷阱。更糟的是第三个陷阱
是新的：`get-swarm-forge` 装完 forge 后 `swarmforge/scripts/` 存在而
`.swarmforge/scripts-manifest` 不存在，`start-swarm.sh` 判定为 INCOMPLETE 并以 `4` `DRIFT`
拒绝启动——**今天任何一个 forge 都只能靠 `--force` 启动**，而 `--force` 同时关掉的是
issue #29 建立的 digest 校验。一个每次都要 `--force` 的闸门等于没人看的闸门（issue #58 已经
在另一个方向上付过一次这个代价）。

## What Changes

- 新增 operator verb `provision forge` 与随包脚本 `scripts/provision-forge.sh`，一条命令走完
  upstream README 的第 2–4 步：装 forge（`project-manager` 或 `lieutenant`）→ 起 forge →
  在它里面建第一个 project 并拉起该 project 的 swarm。
- 安装一律走本 fork 的 `get-swarm-forge`（`default_repo_url` 已指向 `arlishansenn`），
  且**装完之后自证来源**，不信任自己传了什么。
- 安装成功后由这个 verb 写 `.swarmforge/scripts-manifest`。forge 从此是 MANAGED 状态，
  `start-swarm.sh` 的 digest 校验对 forge 恢复有效，`--force` 不再是启动 forge 的常规路径。
  **`get-swarm-forge` 与 `start-swarm.sh` 都不改。**
- 启动一律委托给 `start-swarm.sh`（`--terminal` 必传、detached、readiness 轮询、project 锁），
  这个 verb 自己绝不拼 `ssh` + `nohup ./swarm &`。
- 第 4 步（New Project）走跑着的 dashboard 的 `POST /api/projects`，在目标主机上访问
  `127.0.0.1`。生产 `pack_web.bb` 的 `-main` 只认 `--serve`，所有 `--test-*` flag 只在测试
  harness 里 dispatch，所以 HTTP 是 headless 建项目的唯一支持路径。**dashboard 仍然只绑
  `127.0.0.1`，这个 verb 不新增任何对外暴露。**
- verb 按阶段可续跑：已装好就跳过装，已在跑就跳过起，各自打 `WARN=` 并继续往下走。不引入
  新的退出码，沿用 `operator-verb-contract` 那一套。
- `CONTEXT.md` 补 `Forge`、`Project slot`、`Host lieutenant` 三个词条——这个 verb 是这批
  词汇第一次进入 operator 的词汇表。

**不在本次范围内：** upstream README 第 5 步（New Task）。驱动任务已经是 `run issue` 的地盘，
把它并进来会让这个 verb 同时拥有两个完成条件。`start-swarm.sh` 的
`SWARMFORGE_OPEN_BROWSER` passthrough（forge 启动时仍会尝试 `open` 一个浏览器，无害的噪音）
也留在外面，它属于 `swarm-start-safety`，与本 verb 的正确性无关。

## Capabilities

### New Capabilities
- `forge-provisioning`: 从空目录到一个跑着的 forge 加一个跑着的 project——安装来源、安装后的
  来源自证、阶段可续跑语义、两次 readiness 等待（tmux socket 与 dashboard HTTP）、以及
  New Project 经由 dashboard HTTP API 的路径。

### Modified Capabilities
- `snapshot-install-safety`: manifest 从此有第二个 writer。今天只有
  `update SwarmForge scripts` 写它，所以 `get-swarm-forge` 装出来的 forge 永远落在
  INCOMPLETE。新 requirement：**装 snapshot 的 verb 负责写描述它的 manifest**，于是
  `start-swarm.sh` 现有的 FRESH/MANAGED/INCOMPLETE 三态判定对 forge 第一次说得出真话，
  而那段判定本身一行不改。

## Impact

- **新增**：`.agents/skills/swarmforge-operator/scripts/provision-forge.sh`、
  `scripts/test-provision-forge.sh`；`SKILL.md` 新增一节 `## Verb: provision forge`。
- **修改**：`CONTEXT.md`（三个新词条）、`SKILL.md` 的 Dashboard 端口表（新 forge 占 `7782`）、
  `docs/fork-deltas.md`（D-7 的第十一个 capability，外加
  `snapshot-install-safety` 一格的说明）。
- **不修改**：`get-swarm-forge`、`start-swarm.sh`、`swarmforge/scripts/` 下任何东西。这是
  刻意的——`get-swarm-forge` 与 `start-swarm.sh` 各自是 upstream 与 fork 的高频冲突面，
  本次改动全部落在新文件里，merge 成本为零。
- **依赖**：目标主机上的 `curl`、`tar`、`zsh`（`get-swarm-forge` 的 shebang），以及
  `start-swarm.sh` 已经依赖的那套 ssh/tmux。不引入新依赖。
- **验收需要真跑**：一次真实安装 + 一次真实 New Project，而不只是 argv 断言。
