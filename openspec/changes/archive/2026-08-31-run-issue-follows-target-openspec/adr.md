## ADR 审查完成

本 change 的 ADR 审查已完成。

## 审查过的在效 ADR

- `adr/0001-script-snapshot-follows-this-fork.md`
- `adr/0002-fork-owns-the-complete-pack-artifact.md`
- `adr/0003-fork-deltas-are-recorded-as-executable-specs.md`

按各自的 `Supersedes` 字段核过：0002 取代的是 0001 的实现手段而非其结论，三条当前都在效。
本 change 与三条都无冲突，也不提议改动任何一条。

## 本 change 新增的 repository-level ADR

**没有。本 change 未引入新的 durable architectural decision。**

「从目标项目的运行态推导，而不是在本仓库里写死」不是新承诺，而是 `SKILL.md` 开头既有原则
的一次应用——`CHAIN` 从 `roles.tsv` 推导、`BASE` 每次从 `gh pr list` 现读、dashboard URL
永远现读，都是同一条原则的既有实例。再记一条 ADR 只会稀释 `adr/` 的信噪比：那里应该只有
需要跨 change 重新论证的决定，不是每一次遵守已有原则的记录。
