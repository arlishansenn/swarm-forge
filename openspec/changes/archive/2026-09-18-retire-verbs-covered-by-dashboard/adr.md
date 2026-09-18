# ADR Review Manifest

- Status: pending
- Review date: 2026-09-17

## Review Summary

`design.md` 的五个决定逐条对照在效 ADR。其中四个是战术选择（撤 verb 名但留脚本、折进去而不
改 library、用例整体迁入、capability 按行为而非菜单项保留），不构成长期架构承诺，不立 ADR。

第五个不在决定列表里，而在**被排除的那一半**：`dashboard` 与 `wake role` 为什么不能一起删。
它约束的是未来每一次「网页都有了，全删吧」的 review，立为 ADR-0008。

## In-Force ADRs Reviewed

- `0001-script-snapshot-follows-this-fork.md` —— 不受影响。
- `0002-fork-owns-the-complete-pack-artifact.md` —— 不受影响。
- `0003-fork-deltas-are-recorded-as-executable-specs.md` —— 本 change 正是按它行事：退 verb
  也走 spec，而且明确保留 `work-acceptance` 与 `swarm-start-safety` 两份可验收载体。
- `0004-adr-location-follows-forked-schema.md` —— 不受影响，新 ADR 落 `docs/adr/`。
- `0005-operator-runbook-lives-outside-the-readme.md` —— 不受影响；runbook 同步删两个 verb
  的条目。
- `0006-the-installer-writes-the-manifest.md` —— 不受影响；`swarm-start-safety` 一条不删。
- `0007-the-fork-keeps-only-the-lieutenant-forge-path.md` —— **本 change 是它的直接后果**。
  0007 定下「只走 lieutenant forge」，本 change 把 operator skill 按那条路径的实际端点面
  重新裁剪。不推翻，只延伸。

## New Durable ADRs Created

- `docs/adr/0008-the-dashboard-cannot-reach-itself-or-type.md`
