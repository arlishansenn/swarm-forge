## Why

本 fork 有两条血统。六条 product 分支里，只有 `lieutenant` 带 `card_type.bb`——
`origin/lieutenant` 相对 `upstream/lieutenant` 已经 **0 落后、9 超前**（#135 的一次性移植），
`card_type.bb`、`apply-merge-from!`、`back-one`/`back-all` 全部就位。`main`、`two-pack`、
`four-pack`、`six-pack`、`project-manager` 五条都是 main 血统，没有这套东西。

操作者已决定全面转向 lieutenant forge。Pack 路径失去理由，为它服务的三个 operator verb
随之失去消费者，而它们不是零成本的存量：`SKILL.md` 1559 行里 `run issue` 一段独占 511 行，
`ship project` 每讲一条规矩都要先说清「这跟 `run issue` 有什么不同」。

三个 verb 各自的理由：

- **`onboard project`** —— 把 Pack 装进一个已有的 product 仓，是 `two-pack`/`four-pack`/
  `six-pack` 三种 topology 的唯一入口。lieutenant forge 只有一个模板
  `.swarmforge/project-pack`，`forge.bb` 的 `pack-dir [root _pack]` 直接忽略 pack 名。
- **`update SwarmForge scripts`** —— 把本仓的 `swarmforge/scripts/` 装进 managed project。
  forge 路径上 `forge.bb` 的 `refresh!` 在每次 `open-project!` 里 `overlay-pack!`，这个 verb
  没有活干。它唯一的消费者是「从 upstream pack onboard 过来、要拉到本 fork 脚本上」的
  project；自己版本控制 `swarmforge/` 的 project 一直是被它以 `8` `OWNED` 拒绝的。
- **`run issue`** —— 在 lieutenant 机制下**既坏又多余**。坏：`pack_web_tasks.bb` 的
  `create-task!` 硬写 `--waiting`，HTTP 层没有 move 端点，卡永远不启动（#152）。多余：它的
  stacked BASE 与上游的 `Merge-from` + `back-one`/`back-all` 解同一个问题——「下一张卡看不见
  上一张卡的代码」，上游摞 tree，它摞 branch，两套并存互相打架。它的 `issue-<N>-<slug>`
  身份也已不承重：`ship project` 现在从卡文本读 `#N`。

## What Changes

- 删除三个 operator verb 及其脚本与测试套件：`onboard-project.sh`、
  `update-swarmforge-scripts.sh`、`run-issue.sh`，以及 `test-onboard-project.sh`、
  `test-onboard-start-stop-e2e.sh`、`test-update-swarmforge-scripts.sh`、`test-run-issue.sh`。
- 删除 `SKILL.md` 对应的三段正文，并清掉 `ship project` 一段里所有以 `run issue` 为参照系的
  措辞。
- 删除 `ship-project.sh` 的 `closes_numbers()` 里那条卡名分支（`issue-<N>-<slug>`）——它只
  服务 `run issue` 铸的卡，卡文本的 `#N` 覆盖同一需求。
- 移除两个整体失去主体的 capability，并从另外两个里只摘掉属于被删 verb 的 requirement。
- 立一份 ADR 记下「放弃 Pack 路径与三种 topology」，免得下一次架构 review 重新提议补回
  `two-pack`。
- 关闭 #152：`run issue` 在 Forge 下的三处断点随 verb 一起消失，不再需要修。

## Capabilities

- `issue-to-pr-pipeline` —— **整体移除**。6 条 requirement 全部是 `run issue` 的行为。
- `project-onboarding` —— **整体移除**。2 条 requirement 全部是 Pack 下载与 launcher 安装。
- `snapshot-install-safety` —— **摘掉 3 条**（安装原子性、脏 source checkout 拒绝、自管树的
  `8` `OWNED` 归属判定），全部以 `update SwarmForge scripts` 为主体。**保留 2 条**：
  「自管 snapshot 的项目不做 drift 判定」是 `start swarm` 的行为，「装 script snapshot 的 verb
  负责写描述它的 manifest」（ADR-0006）约束的是 `provision forge`。
- `script-snapshot-provenance` —— **两条都保留但收窄**，把 Pack 分支 launcher 那一半措辞去掉，
  只留 `get-swarm-forge` 与 forge launcher 那一半。决定本身（snapshot 来自本 fork，安装原子
  且留 manifest）对 forge 路径照样成立。

## Impact

- **能力损失，刻意接受**：`two-pack`/`four-pack`/`six-pack` 三种 topology 不再可用；所有
  managed project 变成 lieutenant forge 的 6 角色 `project-pack`。`origin/two-pack`、
  `origin/four-pack`、`origin/six-pack` 三条 product 分支失去消费者（本 change 不删分支，
  只是不再有 verb 消费它们）。
- **能力损失，刻意接受**：不再有「把 Pack 装进一个已有的 product 仓」这条路。product 仓
  通过 forge 的 `POST /api/projects` 从 GitHub clone 进 `<forge>/projects/<name>`。
- **不受影响的 verb**：`provision forge`、`open swarm`、`dashboard`、`start swarm`、
  `stop swarm`、`read swarm`、`wake role`、`talk role`、`accept work`、`ship project`。它们读
  的是 managed project 的 runtime state，两条血统都适用。
- **不被搁浅的 project**：自己版本控制 `swarmforge/` 的 managed project 从没用过
  `onboard project`，也一直被 `update SwarmForge scripts` 拒绝，删除对它无影响。
- 文档面：`docs/adr/0001`、`0002`、`0006` 的措辞、`docs/operator-runbook.md`、`README.md`、
  `docs/fork-deltas.md`、`provision-forge.sh` 的边界注释。
