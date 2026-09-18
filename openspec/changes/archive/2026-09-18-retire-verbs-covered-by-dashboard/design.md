## Context

`pack_web` 在 lieutenant 血统上被拆成十来个 `pack_web_*.bb`，端点面比 main 血统大得多：
`/api/state`（含 `role_heats`、`work_in_flight`、`approvals`、`clarifications`、
`delivery_failures`、`board_allows`）、`/api/projects/open|close`、`/api/teardown`、
`/api/board/allow`、`/api/approvals/*`、`/api/clarifications/*`、`/api/chat`，外加
`pack_web_pane.bb` 的 pane capture 页。

本 change 的每一条判断都来自**逐个端点对账**，不是「网页看起来很全」。两条关键的反向发现：

- **`pack_web_pane.bb` 从头到尾只有 `capture-pane`。** `inject-role!` 存在，但只被 notify
  内部调用（`new-task`、`allow`、`reverse-cleared`），**没有任何 HTTP 端点接受任意文本送进
  role pane**。`wake role` 因此不可替代。
- **chat rail 只通 Host lieutenant**：`post-chat` → `notify-lieutenant!` →
  `inject-role! forge "lieutenant"`。`talk role` 因此不可替代。

## Goals / Non-Goals

**Goals**

- 让 operator skill 只保留网页做不到的那些动作。
- 把「网页做不到什么」写成可查的决定，而不是每次 review 重新论证一遍。
- 合并 `accept work` 与 `ship project`，去掉一层会静默错位的文本接口。

**Non-Goals**

- 不删 `start-swarm.sh`。forge 的引导需要它。
- 不改 `ship project` 的任何门与判据。合并是搬运，不是重设计。
- 不新增 `read attention` 一类的新 verb。lieutenant 血统的 Attention、approvals、
  clarifications 在命令行上确实没有出口，但那是独立一张票。

## Decisions

### 1. `start swarm` 撤 verb 名但留脚本

它有一个网页永远解不了的引导问题：forge 自己要先起来，Dashboard 才存在。`provision forge`
已经在委托它（`--terminal` 必传、detached、readiness 轮询、project 锁全在那边）。

撤 verb 名还有第二个作用：**不让操作者再拿它去启动一个 forge 管的 project**。那会走
`run-main!`，而 `run-main!` 会 `start-pack-web!`；forge 自己起它走的是 `run-project!`，
**不起**。于是多出一个 forge 不知道的 dashboard。

### 2. `accept work` 折进去，不是改成 library

折进去的理由是**只有一个消费者**。改成 `lib-accept-work.sh` 只是把文本接口换成函数接口，
文件数不变，而「为什么有两个文件」这个问题还在。

### 3. 76 个用例整体迁入，不重写

`accept-work.sh` 的难点是隐蔽的：master worktree 必须恰好一行、终端 handoff 有两种信号、
按 `completed_at` 去重时要把小数秒补齐到 9 位再比（整秒时生产者会把小数整个省掉，
`...:55Z` 与 `...:55.000001Z` 都会出现）、已交付排除要在被管 project 自己的仓上跑
`merge-base --is-ancestor`、`inbox/new` 5 分钟与 `inbox/in_process` 30 分钟是两个不同阈值。

**这些都是用例在守，不是注释在守。** 迁入时逐条搬，搬完两边用例数相加对得上。

### 4. `work-acceptance` capability 保留，只改主体

行为一条没变，变的是谁执行。删 capability 会把那些判据一起删掉，而它们正是合并之后
`ship project` 必须继续满足的东西。**降级方向必须是少删，不是多删**——与 #155 那次
`snapshot-install-safety` 的处理同一条规矩。

### 5. `swarm-start-safety` 一条不删

理由同上：capability 描述的是行为，不是菜单项。

## Risks / Trade-offs

- **`ship-project.sh` 涨到约 700 行。** 换掉的是一层会静默错位的文本接口，接受。
- **操作者要改习惯**：停一个 project 从 `stop swarm` 改成 Dashboard 的 close。
- **迁移用例时可能漏。** 缓解：迁完对用例数，并对合并后的脚本做变异测试——把去重、
  已交付排除、master 唯一性各改坏一次，确认都会红。

## Migration Plan

1. spec 先行：本 change 的 artifact 单独一个 PR，合进 `main`。
2. 实现：删两个 verb、合并 accept work、改 `SKILL.md` 与文档、写 ADR-0008，第二个 PR。
3. 归档本 change，关闭 #158。

顺序按 `openspec-git-discipline`。

## Open Questions

无。
