# 0009. Operator verb 拥有 seam，已有脚本作为 adapter

Status: accepted
Date: 2026-09-18
Supersedes: 无

## Context

Issue #177 的目标是把 `swarmforge-operator` 重写为以 verb 为核心的 skill。现有脚本已有回归测试，重写它们会扩大风险；只删 skill 中的 issue 引用或增加文档结构 checker，又不能提供可替换的执行入口。

用户确认六个 verb 先接固定输出的 fake adapter，再逐个接入现有脚本作为 real adapter，并用同一份 contract 测试验证替换。spec 是设计留档；skill 是执行代码，除了备注，不允许引用 spec 作为执行前提。

ADR-0005 确定 runbook 住在 docs，ADR-0007/0008 确定 lieutenant Forge 与六个公开 verb 的范围。本决定只确定这些 verb 内部的替换位置，不重新决定产品路径或恢复退役 verb。

## Decision

每个 verb 用独立的 executable wrapper 提供 seam，通过 `SF_ADAPTER=fake|real` 选择固定 adapter。已有 `.sh` 保持原路径与行为；wrapper 不复制业务判断，也不在 real 失败时回退 fake。实施时发生过一条经用户授权的例外：`ship-project.sh` 把 `git push` 的 stdout 转到 stderr，使 `STATUS=` 回到 stdout 首行；退出码与失败处理不变。

同一组成功 contract assertions 从 seam 调用两个 adapter。fake 只给固定结果且标明未执行真实操作；real 使用隔离 fixture，另有证据证明旧脚本确实执行。fake 通过不等于 real 移植完成；real 接入完成后才切换默认 adapter 与 skill 的操作入口。

SKILL.md 自足描述 verb 用途、输入、调用和结果处理，不要求 agent 读取 issue/spec 才能操作。测试执行 wrapper/adapter，不检查 prompt 措辞，不从 spec 生成或加载执行契约。spec 与 ADR 仅供开发者留档、review 与追溯。

未选择一个总 dispatcher，也未选择 checker 中的强弱检查分流。前者扩大每次移植的共同改动面；后者测试的是文档状态，不能证明已有脚本可被替换。六个 seam 与 fake 在完成移植后保留，attach role 不进入本轮迁移。

## Consequences

每次只接入一个 verb，可以独立 review 和回退；原有七套回归继续保护真实实现。代价是新增六个薄 wrapper 与六个固定 fake，以及维护 real fixture 的成本。

固定 fake 只覆盖约定的成功结果，不能证明安装、角色输入或发布真正发生，也不模拟完整错误状态机。real contract 验证、委托证据和旧回归缺一不可。

如果 real 行为不能满足约定 contract，本票不能借重构修改已有脚本；该 verb 保持未完成并报告差异。spec 留档不能用来伪装 runtime 已遵守某条承诺。没有新的领域术语需要加入 CONTEXT.md。
