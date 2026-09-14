# 0005. operator runbook 住在 `docs/`，不住在 README

Status: accepted
Date: 2026-09-14

## Context

本 fork 的 operator 文档（十二个 verb 表、`open swarm` 契约、切到固定端口、dashboard
端口分配、`run issue` 契约、测试清单）此前是 `README.md` 的最后 232 行，中文，插在
upstream 的 `Adding A Terminal Backend` 与 `Window Behavior` 之间。它是纯追加：0 删除，
不改 upstream 的任何一行。

2026-09-14 这次 merge 里 upstream 的 `275f0c9`「Write main README as the GitHub landing
page」把 README 整份重写，459 行变 215 行，21 个章节换成 10 个全新章节。fork 那 232 行
所依附的两个邻居章节都不存在了。

两件事因此同时成立：

- **定位打架。** upstream 现在明确把 README 当 GitHub landing page。一份 691 行、后半段
  是中文操作手册的 README 不是 landing page。
- **冲突面每次都在。** 那 232 行与 upstream 的内容零重叠，所以它每次都只能靠人把整块
  搬到新 README 的某个位置上——`-X theirs` 会静默吃掉它，而这正是 `docs/fork-deltas.md`
  存在的理由所要防的那种丢失。这一次就被吃掉了一次，靠 merge 前把整块存下来才还原。

`docs/` 下已经住着 `fork-deltas.md` 与 `adr/`，是 fork 独有文档的既有去处。upstream 从不
往 `docs/` 写东西，所以放进去的文件冲突面是零。

## Decision

operator runbook 搬到 `docs/operator-runbook.md`，正文逐字保留，只在顶部加一段说明它
为什么在这儿。README 里留一节六行的英文指路，位置在文件末尾。

放末尾是有意的：upstream 的编辑集中在自己那些章节里，追加在最后一节之后的块，merge
时落在 upstream 最后一个 hunk 的外面。

## Consequences

- upstream 以后再动 README，这份 runbook 不再参与冲突。README 侧要调和的只剩那六行。
- 多一跳。从 GitHub 首页看不到 operator 面，要点一次链接。可接受：真正的读者是本仓库里的
  agent 会话，它读的是 `.agents/skills/swarmforge-operator/SKILL.md`，不是 README。
- `docs/fork-deltas.md` 的 A 类 delta D-7 多一条载体。D-7 的真相源仍然是那十个 capability
  spec 与 `SKILL.md`；runbook 是给人读的那一份，不是契约。
- README 末尾那六行是新的 fork 差异，但**不单列为一条 D-x**：它是 D-7 的一个指路牌，
  丢了不会让任何行为出错，只会让人找不到文档。merge 时按普通 fork 改动对待。
