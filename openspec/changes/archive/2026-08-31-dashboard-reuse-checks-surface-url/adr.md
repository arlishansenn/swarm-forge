## ADR 审查完成

本 change 的 ADR 审查已完成。

## 审查过的在效 ADR

- `adr/0001-script-snapshot-follows-this-fork.md`
- `adr/0002-fork-owns-the-complete-pack-artifact.md`
- `adr/0003-fork-deltas-are-recorded-as-executable-specs.md`

按各自的 `Supersedes` 字段核过，三条当前都在效，与本 change 均无冲突，也不提议改动。

## 本 change 新增的 repository-level ADR

**没有。本 change 未引入新的 durable architectural decision。**

「报文必须与现实一致」不是新承诺——它是 verb 契约里既有的一条（失败要说清下一步，成功要
如实报告）。本 change 只是把它补到链条最后一环：服务端已经被 issue #18 与 #100 管住了，
客户端看到什么此前无人负责。这属于实现追上契约，不是新的架构选择。够不上就不硬凑。
