## ADR 审查完成

本 change 的 ADR 审查已完成。

## 审查过的在效 ADR

- `adr/0001-script-snapshot-follows-this-fork.md`
- `adr/0002-fork-owns-the-complete-pack-artifact.md`
- `adr/0003-fork-deltas-are-recorded-as-executable-specs.md`

按各自的 `Supersedes` 字段核过，三条当前都在效，与本 change 均无冲突，也不提议改动。

## 本 change 新增的 repository-level ADR

**没有。本 change 未引入新的 durable architectural decision。**

「判据按形状不按文案」与「不确定时偏向 BUSY」都不是新承诺：前者是 SKILL.md 已有的
「逐个追文案是必输的比赛」，后者是 `lib-wake-talk.sh` 里既有的注释与 `stop swarm` 一贯的
安全方向。本 change 是把两条既有原则应用到一处漏掉的地方，不是重新决定什么。
