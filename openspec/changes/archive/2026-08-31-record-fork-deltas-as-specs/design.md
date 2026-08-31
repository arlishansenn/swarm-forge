## Context

`docs/fork-deltas.md` 是本 fork 现有的差异记录，它有效但只到「可读」为止。真正咬人的失败
形状是 merge 干净通过而行为被换掉：issue #45 的 `in-process-dir`（upstream 全新函数，零
冲突）、issue #67 的四处「定义被 upstream 取代、调用点还是 fork 的」（零冲突，`bb test`
103 failures）。清单里的每条差异其实都已经有测试钉着，但「哪条 scenario 钉哪条差异」这层
映射只存在于散文里。

在效的 ADR：`adr/0001-script-snapshot-follows-this-fork.md`、
`adr/0002-fork-owns-the-complete-pack-artifact.md`。0002 的 Supersedes 指向 0001 的**实现
手段**而非整条决定，两者都仍然约束本 change：script snapshot 归本 fork（0001），且 fork
拥有完整 Pack artifact、onboard 不改写它（0002）。本 change 与两者一致，不提议改动。

## Goals / Non-Goals

**Goals**

- 每条 B 类差异有一组 Gherkin scenario，且 scenario 写成「换成 upstream 的版本就会失败」。
- ADR 有一个符合 schema 约定的位置（`<repo>/adr/`），并保持不可修改。
- merge upstream 之后的验收从「走一遍散文清单」变成「跑一遍 scenario」。

**Non-Goals**

- 不改任何被测代码。本 change 只记录既有行为。
- 不把 D-7（operator skill 整体）转成 spec。它是 A 类，merge 从不碰它。
- 不引入第二套测试栈。scenario 目前由既有的 `bb test` 与 `test-*.sh` 承载；是否抽取成
  cucumber 可执行测试是后续决定。

## Decisions

**用 intent-driven 而不是 behaviour-driven。** 本 fork 已有 ADR，且「script snapshot 归
谁」这类决定会跨 change 长期约束后续工作。intent-driven = behaviour-driven + 持久 ADR，
正好是这两样。behaviour-driven 少了 ADR 那半。

**ADR 移到 `<repo>/adr/`，不留在 `docs/adr/`。** schema 的 adr artifact 明文规定
repository-level ADR 写在 openspec/ 的同级。留在 `docs/adr/` 会让 adr step 面对一个空的
`adr/`，从而看不见 0001 与 0002 这两条**仍然在效**的约束。代价是三个文档里的路径引用要改。

**scenario 的判据写成可证伪形状。** 每条 scenario 尽量带一句「换成 upstream 的版本，本
scenario 失败」。这是把 `docs/fork-deltas.md` 里那句硬判据（「每条差异都必须有一条会因为
upstream 的版本而失败的测试」）搬进可执行载体。

**ADR 放在 `adr/` 与 pi-governance 放在 `docs/adr/` 不冲突，别去「统一」。** pi-governance
用的是 `behaviour-driven` schema，它**没有 adr artifact**，所以那边的 ADR 放哪儿是自由选择，
它的 config 选了 `docs/adr/`。本仓库用 `intent-driven`，它的 adr artifact 明文要求
repository-level ADR 在 `<repo>/adr/`。两边不一样是各自 schema 的要求，不是漂移；以「跨仓库
一致」为由把本仓库改回 `docs/adr/`，会让 adr step 看不见在效的 ADR。

**`docs/fork-deltas.md` 保留，降级为索引与操作手册。** 它仍然承载 merge 流程、两类差异的
成本模型、以及「攒 3-5 个 commit 就合一次」这类经验；这些不是 behaviour，塞进 spec 会让
spec 变成散文。差异本身的真相源改为 spec。

## Risks / Trade-offs

- [spec 与测试各说各话] -> scenario 逐条点名它对应的既有测试（钉子），映射写在
  `docs/fork-deltas.md` 的索引里；两边不一致时以测试为准并修 spec。
- [多一层要维护的文档] -> 只有 B 类差异进 spec；A 类仍留在清单里，因为 merge 不碰它们。
- [`.claude/` 被 gitignore] -> `openspec init` 生成的 Claude Code slash command 落在被忽略
  的目录里，clone 的人拿不到。共享路径是 `.agents/skills/openspec-*`，那些是 tracked 的。
  想让 slash command 也进仓库需要改 `.gitignore`，本 change 不做。
- [scenario 目前不可执行] -> 它们描述的行为已经被既有测试覆盖，所以现在的价值是「merge 后
  逐条对照」而不是「一条命令跑完」。抽取成 cucumber 是后续决定，不在本 change。

## Migration Plan

1. 安装 schema 与 skill，配 `openspec/config.yaml`（已完成）。
2. `git mv docs/adr adr`，改三处路径引用（已完成）。
3. 写本 change 的 8 个 capability spec。
4. `openspec validate record-fork-deltas-as-specs --type change --strict` 通过。
5. `docs/fork-deltas.md` 顶部加索引，指明每条 B 类差异对应哪个 capability。
6. 合并后 archive，spec 落入 `openspec/specs/`。

回滚：本 change 不改被测代码，回滚等于删除 `openspec/`、`adr/` 的移动与文档引用改动。

## Open Questions

- 这些 scenario 要不要抽取成可执行的 cucumber 测试？现在的答案是「先不」——本仓库的测试栈
  是 babashka + bash，引入 Node/cucumber 是第三套栈。等 scenario 与既有测试出现第一次真实
  漂移时再回答。
- D-7 要不要也转成 capability？它是 A 类，merge 不碰，但它的契约现在只在 `SKILL.md` 里。
