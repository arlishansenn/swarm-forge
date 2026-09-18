## Why

ADR-0007 把本 fork 定在 lieutenant forge 一条路径上。那条路径的设计是**操作都在 Dashboard
上做**：卡由 Host lieutenant 或人在网页上切，Attention、approvals、clarifications、
pane capture、open/close project、teardown 全在网页里。

按 `pack_web` 的实际端点把十个 operator verb 逐个对账之后，三个已经被网页覆盖，一个不该
再是独立 verb：

- **`read swarm`** —— `role_heats` + `work_in_flight` + pane capture 就是它报的东西，而且是
  活的。
- **`stop swarm`** —— `POST /api/projects/close` 覆盖 project，`/api/teardown` 覆盖整个
  forge。**而且它现在是错的**：`stop-swarm.sh` 跑 `close-swarm` 杀 session，碰不到 forge 的
  `open-projects` 记录，于是 forge 继续认为这个 project 开着。状态漂移是静默的。
- **`start swarm`** —— `POST /api/projects/open` 覆盖 project。但 forge 自己要先起来、那时
  还没有 Dashboard，所以脚本作为 `provision forge` 的内部步骤保留，撤掉 verb 名。
- **`accept work`** —— `run issue` 删除后它只剩 `ship-project.sh` 一个调用方，中间还隔着一层
  自由文本。一个 adapter 是假想的 seam。

## What Changes

- 删除 `read-swarm.sh`、`test-read-swarm.sh`、`stop-swarm.sh`、`test-stop-swarm.sh`。
- `start-swarm.sh` 与 `test-start-swarm.sh` **保留**，但从 `SKILL.md` 的 verb 列表里撤下，
  改写成 `provision forge` 的内部步骤。
- 把 `accept-work.sh` 的逻辑折进 `ship-project.sh`，删除 `accept-work.sh` 与
  `test-accept-work.sh`，**它的 76 个用例整体迁入 `test-ship-project.sh`**。
- `open swarm` 与 `talk role` 只改定位，不动代码：前者的卖点收窄成「要交互式附着，不是只
  看」，后者收窄成「跟 project role 说话，网页只能跟 Host lieutenant 说」。
- 立 ADR-0008 记下 `dashboard` 与 `wake role` 是网页的两个盲区（接入、输入）。

## Capabilities

- `role-state-reading` —— **整体移除**，主体是 `read swarm`。
- `swarm-stop-safety` —— **整体移除**，主体是 `stop swarm`。
- `swarm-start-safety` —— **保留，一条不删**。`start swarm` 只是不再作为公开 verb 出现；它的
  安全规则（已在跑拒绝、project 锁、snapshot 三态判定、脱离终端启动）仍然由
  `provision forge` 依赖。capability 描述的是行为，不是菜单项。
- `work-acceptance` —— **保留全部 requirement，只改主体**。终端交付记录怎么读、已交付怎么
  排除、卡住的链条怎么 WARN，这些行为原样存在，只是从 `accept work` 搬进 `ship project`。

## Impact

- **十 → 六个 verb**：`provision forge`、`dashboard`、`open swarm`、`wake role`、`talk role`、
  `ship project`。`scripts/` 从 20 个文件降到 14 个。
- **能力损失：无。** 退役的三个由 Dashboard 覆盖，合并的那个行为原样保留。
- **停 project 的正确动作变了**：从 `stop swarm` 变成 Dashboard 的 close，或
  `POST /api/projects/close`。这是本次唯一需要操作者改习惯的地方，`SKILL.md` 要写明，
  否则人会继续找一个已经删掉的动词然后以为 forge 坏了。
- **已知风险**：lieutenant forge 在本 fork 仍未跑通一张卡到 PR（ADR-0007 已记）。回退路径是
  `git revert`。
