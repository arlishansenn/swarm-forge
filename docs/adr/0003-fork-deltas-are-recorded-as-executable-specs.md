# 0003. fork 相对 upstream 的差异以 behaviour spec 记录

Status: accepted
Date: 2026-08-31

## Context

本 fork 长期跟随 `unclebob/swarm-forge` 的 `main`，同时保留自己的一批修复。这些差异此前
只记在 `docs/fork-deltas.md` 这份散文清单里。

清单挡不住 merge。git 的冲突检测是行级的：upstream 在**全新代码**里重犯一个本 fork 已经
修过的 bug 时，没有文本重叠，merge 干净通过，测试也可能照绿。这不是假想。

- issue #45：upstream 新增的 `in-process-dir` 用进程 cwd 解析收件箱，正是本 fork 在
  issue #8 修掉的双事实来源 bug。git 一个冲突都没报，因为那是它全新加的函数。
- issue #67：merge 零冲突、干净通过，`bb test` 却是 103 failures / 82 errors——四处
  「定义被 upstream 的版本取代、调用点还是 fork 的」。
- 同一次 merge 还产生过一个哑的变体：`handoff_lib.bb` 里出现两个 `state-dir`，Clojure
  后定义胜出，所以 runtime 侥幸正确、测试全绿。

清单里写着一条硬判据——「每条差异都必须有一条会因为 upstream 的版本而失败的测试」——但那
句话本身没有可执行的载体。哪条测试钉哪条差异，这层映射只存在于散文里，而走一遍散文清单
靠人回忆「这条应该是什么样」，人会累。

## Decision

fork 相对 upstream 的每条 B 类差异（落在 upstream 也在改的文件里的那些），以 OpenSpec
`intent-driven` schema 的 behaviour spec 记录：一个 capability 一个 `spec.md`，requirement
用 SHALL / MUST NOT，行为写成 Gherkin scenario。

每条 scenario 尽量写成**可证伪**的形状，即带一句「换成 upstream 的版本，本 scenario
失败」。这是把上述硬判据从散文搬进载体。

`docs/fork-deltas.md` 保留，但降级：它承载 merge 流程、两类差异的成本模型、以及
「攒 3-5 个 upstream commit 就合一次」这类经验，并作为「差异 → capability」的索引。
差异本身的真相源改为 spec。

选 `intent-driven` 而不是 `behaviour-driven`，是因为本 fork 已经有跨 change 长期约束后续
工作的决定（ADR-0001、ADR-0002），而 intent-driven 正是 behaviour-driven 加持久 ADR。

repository-level ADR 放在仓库根的 `adr/`，与 `openspec/` 同级，因为 schema 的 adr artifact
明文如此规定。原来的 `docs/adr/` 因此移到 `adr/`；两份既有 ADR 内容一字未动。

## Consequences

**得到的：** upstream merge 之后的验收从「走一遍散文清单、靠人判断每条差异还在不在」变成
「跑一遍 scenario」。新差异有明确的落点：先写 spec，再写钉住它的测试。差异与钉子的映射
从散文变成结构。

**付出的：** 多一层要维护的文档。缓解办法是只有 B 类差异进 spec——A 类落在 upstream 没有
的文件里，merge 从不碰它们，留在清单里就够。

**还没解决的：** 这些 scenario 现在**不可执行**。它们描述的行为已被既有的 `bb test` 与
`test-*.sh` 覆盖，所以当前价值是「merge 后逐条对照」，不是「一条命令跑完」。抽取成
cucumber 会引入第三套测试栈（本仓库是 babashka + bash），代价大于当下收益。等 scenario
与既有测试出现第一次真实漂移时再重新决定；那时应记一条新 ADR，而不是改本条。

**范围之外：** D-7（`swarmforge-operator` skill 整体）没有转成 capability。它是 A 类，
契约写在它自己的 `SKILL.md` 里。
