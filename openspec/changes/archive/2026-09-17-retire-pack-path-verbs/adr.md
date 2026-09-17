# ADR Review Manifest

- Status: pending
- Review date: 2026-09-17

## Review Summary

`design.md` 的五个决定逐条对照在效 ADR。其中四个是战术选择（一起删还是分批、卡名分支跟着
删、按 requirement 摘 capability、#152 随本 change 关闭），不构成长期架构承诺，不立 ADR。
第五个——**放弃 Pack 路径与三种 topology，本 fork 只保留 lieutenant forge 一条安装路径**——
约束的是未来所有安装与派活方式，立为 ADR-0007。

## In-Force ADRs Reviewed

- `0001-script-snapshot-follows-this-fork.md` —— **决定仍在效**。snapshot 仍然必须来自本
  fork，本 change 只是去掉 Pack 分支那一条到达方式，`get-swarm-forge` 那一条原样保留。
  措辞要收窄，决定不动。
- `0002-fork-owns-the-complete-pack-artifact.md` —— **决定仍在效**。fork 仍然拥有它安装的
  完整 artifact，安装仍然是纯解压、不事后 patch。这条对 `origin/lieutenant` 同样成立。
  「Pack」在文中要改指 forge 的 project-pack。
- `0003-fork-deltas-are-recorded-as-executable-specs.md` —— 不受影响。本 change 正是按它
  行事：删能力也走 spec。
- `0004-adr-location-follows-forked-schema.md` —— 不受影响，新 ADR 落 `docs/adr/`。
- `0005-operator-runbook-lives-outside-the-readme.md` —— 不受影响；runbook 要同步删掉三个
  verb 的条目。
- `0006-the-installer-writes-the-manifest.md` —— **决定仍在效，且本 change 明确保住它**：
  `snapshot-install-safety` 里承载它的那条 requirement 不删。

## New Durable ADRs Created

- `docs/adr/0007-the-fork-keeps-only-the-lieutenant-forge-path.md`
