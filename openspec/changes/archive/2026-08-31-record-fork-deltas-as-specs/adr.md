## ADR 审查完成

本 change 的 ADR 审查已完成。

## 审查过的在效 ADR

- `adr/0001-script-snapshot-follows-this-fork.md`：managed project 的 script snapshot 跟随
  本 fork。仍然在效，本 change 与之一致。
- `adr/0002-fork-owns-the-complete-pack-artifact.md`：fork 拥有完整 Pack artifact，
  `onboard project` 不改写它。它取代的是 0001 的**实现手段**，不是 0001 的结论；两条都仍然
  约束后续工作。

两条都未被修改，也未被本 change 取代。

## 本 change 新增的 repository-level ADR

- `adr/0003-fork-deltas-are-recorded-as-executable-specs.md`

理由：「fork 相对 upstream 的差异以 behaviour spec 记录，散文清单降级为索引」是一条跨 change
的长期承诺——它决定了此后每一次 upstream merge 的验收方式，也决定了新差异该往哪里写。它不是
本次的战术实现细节，因此按 schema 的判据升格为 ADR。
