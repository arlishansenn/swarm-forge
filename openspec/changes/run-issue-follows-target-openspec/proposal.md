## Why

`run issue` 投给 swarm 的 task body 是固定文本，**一个字都没提 OpenSpec**。于是一个装了
OpenSpec 的 managed project，装了也等于没装。

这不是推测，已经在真实运行里失效过一次：`arlishansenn/podsum` 合并 PR #96 装上
`intent-driven` schema，并在 `AGENTS.md` 写明变更走 `proposal -> (specs, design) ->
adr -> tasks`；紧接着 swarm 通过本 verb 做完了 podsum #93，产出 4 个 commit、+414 行、
22 个新测试全绿——而 `openspec/changes/` 下**零产出**。coder 照老路径直接改代码加 TDD，
`AGENTS.md` 里新加的那节对它是死字。

## What Changes

- task body 在**目标项目有** `$ROOT/openspec/config.yaml` 时追加一段 OpenSpec 说明，
  schema 名从该文件的 `schema:` 键读出。
- 目标项目**没有**该文件时，task body 与改动前逐字节相同。
- artifact 顺序**不写进脚本**：只报出 schema 名，让 coder 去读
  `openspec/schemas/<name>/schema.yaml`。

**不能无条件加。** 本 verb 服务任意 managed project，有的项目根本不用 OpenSpec，把「走
OpenSpec 周期」写死进 task body 对它们就是错误指令。从目标项目的运行态推导，与
`SKILL.md` 开头自己立的原则一致，也与 `CHAIN` 从 `roles.tsv` 推导而不是写死 role 名字
是同一个套路。

## Capabilities

### New Capabilities

无新 capability。

### Modified Capabilities

- `issue-to-pr-pipeline`: 新增一条关于 task body 如何从目标项目状态派生的
  requirement。用 **ADDED** 而不是 MODIFIED：这是给既有 capability 加一个新关注点，
  没有改动它已有的任何行为。（另外 `openspec/specs/` 目前还不存在——
  `record-fork-deltas-as-specs` 那个 change 尚未 archive，所以也没有可供 MODIFIED
  引用的既有 spec 文件。）

## Impact

- `scripts/run-issue.sh`：新增一段条件读取与一个变量插值，基础文本一字未动。
- `scripts/test-run-issue.sh`：新增 4 条 case。
- 不影响任何不使用 OpenSpec 的 managed project。
