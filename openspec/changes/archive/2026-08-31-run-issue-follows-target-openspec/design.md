## Context

`run-issue.sh` 的 task body 是一段固定文本，写于本仓库与 managed project 都还没有
OpenSpec 的时候。podsum 装上 schema 之后，第一次真实运行就证明了固定文本的代价：
`AGENTS.md` 里新加的那节，coder 根本不会读到。

在效的 ADR：`adr/0001`（script snapshot 跟随本 fork）、`adr/0002`（fork 拥有完整 Pack
artifact）、`adr/0003`（fork 差异以 behaviour spec 记录）。三条都与本 change 无冲突，
本 change 也不提议改动任何一条。

## Goals / Non-Goals

**Goals**

- 装了 OpenSpec 的 managed project，其 swarm 收到的指令里知道这件事。
- 不用 OpenSpec 的项目，收到的指令与今天逐字节相同。
- schema 名从目标项目读出，不在本仓库里存第二份。

**Non-Goals**

- 不在本 verb 里保存 artifact 顺序或每个 artifact 的要求。
- 不去校验目标项目的 OpenSpec 装得对不对——那不是本 verb 的职责，它只报出事实。
- 不改任何不使用 OpenSpec 的项目的行为。

## Decisions

**从 `$ROOT/openspec/config.yaml` 的存在与否推导，而不是加一个 flag。** flag 需要调用方
记得传，而调用方常常是一条 `for n in 28 29 30; do ... done` 的链。运行态自己知道答案，
就不该问人。这也与 `SKILL.md` 开头立的原则一致：从目标项目的运行态推导，不要分支在名字上。

**只报 schema 名，不报 artifact 顺序。** 顺序是 schema 的属性，写进本 verb 等于在
SwarmForge 里维护第二份 OpenSpec 知识。第二份的失效方式是无声的：schema 加了一个
artifact，本 verb 照旧报旧顺序，没有任何东西会红。

**用 ADDED 而不是 MODIFIED。** 这是给 `issue-to-pr-pipeline` 加一个新关注点，没有改动
它已有的任何行为。顺带一提，`openspec/specs/` 目前不存在——
`record-fork-deltas-as-specs` 尚未 archive，所以也没有可供 MODIFIED 引用的文件。

## Risks / Trade-offs

- [`config.yaml` 存在但 `schema:` 读不出] -> 当作不使用 OpenSpec 处理，即回到逐字节相同
  的老文本。宁可少说一句，也不要往 task body 里塞一个空名字。
- [目标项目装了 OpenSpec 但那一轮不该走它] -> 本 verb 只陈述事实（"本项目用 OpenSpec，
  schema 是 X"），判断留给 coder 与 issue 本身的验收标准。
- [测试可能滑向测措辞] -> 本仓库 `AGENTS.md` 禁止用自动化测试钉 prompt 文本。新增的
  case 断言的是「schema 名有没有出现」这一条件行为，且用一个不存在的 schema 名
  `foo-bar`，使它只可能来自文件读取。没有一条断言针对措辞。

## Migration Plan

无迁移。改动对不使用 OpenSpec 的项目逐字节无影响；对使用的项目，下一次 `run issue`
自然生效。回滚等于还原 `run-issue.sh` 的那两处改动。

## Open Questions

- `record-fork-deltas-as-specs` 一直没 archive，所以 `openspec/specs/` 仍是空的，本仓库
  的 capability spec 目前全都只存在于未归档的 change 里。这不影响本 change，但那个归档
  该做，否则「accepted 的 spec」这一层始终是空的。
