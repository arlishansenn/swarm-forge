## Why

Issue #177 要把 `swarmforge-operator` 重写为以 Operator verb 为核心的 skill 2.0：每个 verb 拥有可替换 adapter 的 seam，逐个接入已有脚本。触发点是运行指令混入大量 issue 沿革；只删票号或增加文档 checker，不能完成这次 module 重组。upstream 没有这组 operator 入口，本 change 只改变 fork 自有 skill。

## What Changes

- 为六个 verb 建立各自的 wrapper seam、固定结果的 fake adapter 和同一份可运行于 fake/real 的 contract 测试；先让六个 fake 路径全绿，再逐个接入现有 `.sh`。
- 移植顺序固定为 provision forge、dashboard、ship project、wake role、talk role、open swarm；attach role 不移植。
- 原地重写 `SKILL.md`，围绕 verb 的用途、输入、调用入口、结果与失败处理组织内容。保留必要安全约束，不把 issue 或 spec 阅读作为执行前提，不引入 `Kind:` 或文档结构 checker。
- 现有生产脚本保持行为不变（唯一例外：用户已授权的 `ship-project.sh` 的 `git push` stdout 转 stderr 一行，见 tasks 阶段 5），现有七套回归继续运行。README 与 runbook 最后改为指向 skill 的入口，不再维护重复的 verb 契约表。

## Capabilities

### New Capabilities

- `operator-verb-adapters`: 六个 verb 的可替换执行入口、fake 的隔离、real 的接入，以及逐 verb 的替换验证。

### Modified Capabilities

无。本次不改变 Forge、Managed project 或 Dashboard 的业务行为，也不重开旧 capability 的历史决定。新 spec 记录新增 seam 的行为，不成为 skill、wrapper、adapter 或测试执行时的输入。

## Impact

- 主要范围：`.agents/skills/swarmforge-operator/SKILL.md` 与该目录下新增的 wrapper、fake adapter、contract 测试和必要的测试 fixture。
- 六个已有 adapter：`provision-forge.sh`、`open-dashboard.sh`、`ship-project.sh`、`wake-role.sh`、`talk-role.sh`、`open-swarm.sh`。`start-swarm.sh` 与 `lib-wake-talk.sh` 仍是既有内部实现，不另包装成公开 verb。
- 文档留档：本 change 与新的 repository ADR；最终导航调整限 `README.md`、`docs/operator-runbook.md`。不修改 `CONTEXT.md`、`AGENTS.md`，不加测试框架。
- 不执行真实 Forge provision、角色输入或 GitHub 发布来验收：real adapter 在隔离 fixture 中执行，其外部依赖受控。fake 测试通过只证明替身路径，不算 real 移植完成。

## Baseline 与完成判据

需求来源为 #177 与本次会话已确认决定，review 基线为 `main @ 5f6816d`。#176 已合并、#158 已关闭，前置归档已满足。

最终应证明六个 seam 的同一组 contract assertions 在 fake 与 real 上均通过、七套既有回归通过、旧脚本没有行为改动，并人工验收 skill 的六个 verb 已改为调用各自 seam。「旧脚本没有行为改动」含一条经用户授权的例外（`ship-project.sh` 的 push 输出重定向）。旧脚本的约束针对基线已有文件，不包括新增 wrapper/fake/test；注释与 usage 文案改动仍需逐项人工审核，不擅自收紧为一字节不可改。
