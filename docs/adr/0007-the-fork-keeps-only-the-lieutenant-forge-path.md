# 0007. 本 fork 只保留 lieutenant forge 一条安装与派活路径

Status: accepted
Date: 2026-09-17

## Context

本 fork 长期同时维护两条血统。判据是 `swarmforge/scripts/card_type.bb` 是否存在：

| 分支 | 血统 |
|---|---|
| `main`、`two-pack`、`four-pack`、`six-pack`、`project-manager` | main |
| `lieutenant` | lieutenant |

`origin/lieutenant` 相对 `upstream/lieutenant` 已经 **0 落后、9 超前**（issue #135 的一次性
移植）。它带来的不只是几个新脚本，而是一套**完全不同的派活模型**：`lieutenant.prompt` 从
11 行的被动参谋变成 90+ 行的 planner & dispatcher，靠 `.swarmforge/routes.tsv` 的 card type
路由，靠 `Merge-from` 与 `back-one`/`back-all` 让后一张卡看得见前一张卡的 tree。

`docs/research/upstream-lieutenant.md` 当时的结论是一句警告：本 fork 的 `run issue` 扮演的
**正是分支版 dispatcher lieutenant 的角色，两者是替代关系，不是互补关系**。

两条血统同时活着的代价，都落在 operator skill 上：

- `SKILL.md` 1603 行里 `run issue` 一段独占 511 行。
- `ship project` 每讲一条规矩，都要先说清「这跟 `run issue` 有什么不同」。
- `run issue` 在 lieutenant 机制下**必然卡死**：`pack_web_tasks.bb` 的 `create-task!` 硬写
  `--waiting`，HTTP 层没有 move 端点，卡永远不启动（issue #152）。
- 它同时**多余**：stacked BASE 与 `Merge-from` + 反向传播解的是同一个问题。两套机制解一个
  问题，不是冗余保险，是互相打架。

## Decision

**本 fork 只保留 lieutenant forge 一条安装与派活路径。** 为 Pack 路径服务的三个 operator
verb 退休：

- `onboard project` —— 把 Pack 装进一个已有的 product 仓。
- `update SwarmForge scripts` —— 把本仓脚本装进 managed project。
- `run issue` —— issue 驱动、无人值守、stacked 分支。

**随之放弃 `two-pack` / `four-pack` / `six-pack` 三种 topology。** lieutenant forge 只有一个
项目模板 `.swarmforge/project-pack`（specifier、coder、cleaner、architect、hardender、QA
六个角色，四种 card type），`forge.bb` 的 `pack-dir [root _pack]` 直接忽略 pack 名。

product 仓从此通过 forge 的 `POST /api/projects` 从 GitHub clone 进 `<forge>/projects/<name>`，
不再有「把 Pack 装进一个已有目录」这条路。

## Consequences

**这条决定放弃的能力，明确记在这里，免得下次架构 review 重新提议补回来：**

- **轻量 topology 没了。** 两角色的 `two-pack` 比六角色便宜得多，是最容易被重新提议的东西。
  真的需要时，恢复路径是**把它写成 lieutenant forge 的一个 card route**（`swarmforge.conf`
  的 `card <type> <role>...` 行），不是把 `onboard project` 复活。
- **开工前的 staleness 守卫没了。** `run issue` 建分支前会 `git fetch` 并
  `merge --ff-only`，本地 BASE 不是 `origin/BASE` 祖先就拒绝。Dashboard 这条路上没有对应的
  闸门。`ship project` 只在事后报 `behind N`，那时活已经建立在过期起点上。**这是本次接受的
  最实在的一处退步。**
- **stacked 分支没了。** 它的替代品是 lieutenant 的 `Merge-from` + `back-one`/`back-all`：
  上游摞 tree，本 fork 原来摞 branch。替代品只在 lieutenant 血统上存在，所以**任何仍然跑
  main 血统的 managed project 都不再有这个能力**。
- **三条 product 分支失去消费者。** `origin/two-pack`、`four-pack`、`six-pack` 不删——删分支
  是单独一次决定，留着不产生维护成本——但没有任何 verb 再消费它们。

**不受影响的：**

- 十个 operator verb 保留：`provision forge`、`open swarm`、`dashboard`、`start swarm`、
  `stop swarm`、`read swarm`、`wake role`、`talk role`、`accept work`、`ship project`。它们读
  的是 managed project 的 runtime state，两条血统都适用。
- 自己版本控制 `swarmforge/` 的 managed project 不被搁浅：它从没用过 `onboard project`，也
  一直被 `update SwarmForge scripts` 以 `8` `OWNED` 拒绝。
- ADR-0001（snapshot 来自本 fork）、ADR-0002（fork 拥有完整 artifact，安装是纯解压）、
  ADR-0006（装 snapshot 的 verb 写 manifest）三条决定全部仍在效，只是措辞里 Pack 那一侧的
  举例收窄到 `get-swarm-forge` 与 forge 的 project-pack。

**已知风险：** lieutenant forge 在本 fork 还没跑通过一张卡到 PR。本决定删掉的是当前唯一被
验证过的派活路径。缓解只有两条——删除全在 git 里可整体 `revert`，以及 `provision forge` 的
验收 forge 已经起过。

## Supersedes

无。本 ADR 不推翻任何在效决定，只收窄它们的适用范围。
