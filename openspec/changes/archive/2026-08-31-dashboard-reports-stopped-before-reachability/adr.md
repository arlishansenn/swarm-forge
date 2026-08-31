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

它做的两件事都是既有承诺的一次修正，不是新的架构选择：

- 「先判断该不该在跑，再判断可达不可达」——退出码表早就规定 `3` 是「目标没在运行」、`5`
  是「verb 自己失败了」。本 change 只是让代码能走到那条既有规定，属于实现追上契约。
- 「不给一条已经执行过的补救命令」——同样出自既有的 verb 契约：失败要说清下一步做什么。
  报一条无效的下一步，是没有满足那条契约，不是要重新决定什么。

按 schema 的判据，两者都够不上 durable decision：既不建立长期承诺，也不与任何在效 ADR
分歧。够不上就不硬凑。
