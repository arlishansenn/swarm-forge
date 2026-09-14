# ADR Review Manifest

- Status: completed
- Review date: 2026-09-14

## Review Summary

本 change 的 ADR review 已完成。`design.md` 的七个决定逐条对照过在效 ADR：其中六个是战术
实现选择（verb 命名、启动委托、HTTP API 路径、可续跑语义、readiness 预算、来源 marker 的
具体形状），不构成长期架构承诺，不立 ADR。第七个——**manifest 归谁写**——确立了一条会约束
未来所有安装路径的边界，立为 ADR-0006。

## In-Force ADRs Reviewed

按 `Supersedes` 链走完 `docs/adr/`，当前在效的是全部五条：

- `0001-script-snapshot-follows-this-fork.md` —— **决定仍在效**（snapshot 跟随本 fork），
  实现手段被 0002 取代。本 change 的「来源自证」直接服务这条决定。
- `0002-fork-owns-the-complete-pack-artifact.md` —— fork 拥有它安装的完整 artifact，安装
  动作退化成纯解压、不事后 patch。本 change 遵守：`provision forge` 只调 `get-swarm-forge`
  并写一份 manifest，绝不改写落地文件的内容。
- `0003-fork-deltas-are-recorded-as-executable-specs.md` —— fork 差异以可证伪的 behaviour
  spec 记录。本 change 的两份 spec 照此写成「换成 upstream 的版本就会失败」的形状。
- `0004-adr-location-follows-forked-schema.md` —— repository-level ADR 落在 `docs/adr/`。
  ADR-0006 照此存放。
- `0005-operator-runbook-lives-outside-the-readme.md` —— operator 文档不进 README。本 change
  的新 verb 一节写进 `SKILL.md`，不碰 README。

没有任何一条需要 supersede。

## New Durable ADRs Created

- `docs/adr/0006-the-installer-writes-the-manifest.md` —— 装 script snapshot 的 verb 负责写
  描述它的 manifest；`start swarm` 的三态判定与 `get-swarm-forge` 都不改。
