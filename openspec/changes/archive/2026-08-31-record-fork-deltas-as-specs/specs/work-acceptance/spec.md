## ADDED Requirements

### Requirement: 只报告尚未入库的工作

Feature: accept work

`accept work` SHALL 报告 master 的 `inbox/completed/` 里、且其 commit 还没进目标分支的
那些任务；已经入库的 commit MUST 被排除。同一条 handoff 在链路多次换手时 MUST 只报一次。

#### Scenario: 已入库的 commit 不再出现

- **GIVEN** 某个已完成任务的 commit 已经在目标分支上
- **WHEN** 运行 `accept work`
- **THEN** 该任务不出现在报告里

#### Scenario: 两次运行不改动任何 inbox 文件

- **GIVEN** 任意 handoff 状态
- **WHEN** 连续运行两次 `accept work`
- **THEN** 所有 `inbox/` 树下的文件逐字节未变——它是 report verb

### Requirement: 卡住的 handoff 要报出来，但只在真的卡住时

停滞时间超过阈值的 `inbox/new` 或 `inbox/in_process` 积压 SHALL 以 `WARN=` 报出，并带上
数量与 worktree 名。**尚未**超过阈值的文件 MUST NOT 触发 WARN——每次都出现的警告没人读。

#### Scenario: 新到的 handoff 不触发警告

- **GIVEN** 一个刚刚投进 `inbox/new`、尚未超过阈值的 handoff
- **WHEN** 运行 `accept work`
- **THEN** 没有 WARN

#### Scenario: 陈旧积压带数量与 worktree 名

- **GIVEN** 某个 role 的 `inbox/new` 里有超过阈值的积压
- **WHEN** 运行 `accept work`
- **THEN** 有一行 `WARN=`，含积压数量与该 worktree 名
