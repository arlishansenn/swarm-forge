# 0004. ADR 留在 docs/adr/，schema 从本组织的 fork 消费

Status: accepted
Date: 2026-08-31

## Context

ADR 的存放位置此前被两个都写死路径、且都不可配置的东西同时决定，方向相反。

上游 `intent-driven-dev/openspec-schemas` 的 `intent-driven` schema，在 adr artifact 的
instruction 里写死 `<repo>/adr/`，并且明确排除 `openspec/` 内的任何目录。它的归档变更
`2026-05-10-remove-adr-folder-parameter` 表明这个 folder 参数是被刻意移除的——不是遗漏，
是设计。

`mattpocock/skills` 的 `domain-modeling` skill 同样写死 `docs/adr/`，还带一条主动指令：
「If no `docs/adr/` exists, create it when the first ADR is needed」。本仓库的
`docs/agents/domain.md` 是这套约定的仓库内复述，`pi-governance`、`server-tool-extension`
等仓库也都按它把 ADR 放在 `docs/adr/`。

`record-fork-deltas-as-specs` 这个 change 当时选了迁就 schema：把 `docs/adr/` 搬到顶层
`adr/`，它的 `design.md` 还写明「别去『统一』」，理由是留在 `docs/adr/` 会让 adr step 面对
一个空的 `adr/`，从而看不见仍然在效的 ADR。**在当时的前提下，这个判断是对的**：schema 不可
改，那就只能让仓库让步。

那个前提现在没有了。`arlishansenn/openspec-schemas` 是上游的 fork，唯一的有意差异就是把
`<repo>/adr/` 改成 `<repo>/docs/adr/`（覆盖 `intent-driven` 与 `spec-driven-with-adr` 两个
schema 的 `schema.yaml`、`templates/`、README，以及 fork 自身的 spec）。有了它，「adr step
能看见在效的 ADR」和「ADR 在 `docs/adr/`」不再互斥。

两者并存的代价是具体的，不是洁癖：`domain-modeling` 在本仓库触发时会去创建 `docs/adr/` 并从
`0001` 重新起号，而 adr artifact 解析当前在效决策的方式是**遍历单一目录**走 Supersedes 链。
目录一裂，这条链就断，且断得无声。

## Decision

本仓库的 repository-level ADR 留在 `docs/adr/`。

OpenSpec schema 从 `arlishansenn/openspec-schemas` 消费，不从上游消费。重新安装或同步
schema 时用 fork 的 `AGENT_INSTALL.md`；它顶部已有 fork notice，`git clone` 也已指向 fork。

配套 skill 仍从 `intent-driven-dev/skills` 取——那个仓库不含任何 ADR 路径，
`architectural-decision-records` skill 只管格式。

`openspec/changes/record-fork-deltas-as-specs/` 内的文档**保持原文，不回改**。它记录的是
当时前提下做出的决定，改掉它等于伪造决策史；本 ADR 就是那条记录的续集。

## Consequences

`docs/agents/domain.md`、`docs/fork-deltas.md`、
`docs/research/upstream-task-completion-protocol.md`、`openspec/config.yaml` 四处路径引用
改回 `docs/adr/`。0001–0003 三份 ADR 用 `git mv` 迁移，内容一字未改，序列连续。

本仓库与 `podsum` 现在用同一份 fork schema、同一个 ADR 位置，与 `pi-governance`、
`server-tool-extension` 的 `docs/adr/` 也一致。跨仓库不再有两套布局。

代价是多了一个要维护的 fork。upstream 更新时需要 rebase 这一处 delta；delta 只有路径字符串
和随之改写的几句措辞，冲突面很小。真正的风险是有人绕过 fork 直接从上游装——`AGENTS.md` 与
fork 的 `AGENT_INSTALL.md` 各写了一道提示，但没有自动化拦截。

`openspec/changes/record-fork-deltas-as-specs/` 里仍写着 `adr/` 路径。那是历史记录，与当前
布局不符是预期的；判断当前位置以本 ADR 为准。
