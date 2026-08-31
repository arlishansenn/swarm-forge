## ADDED Requirements

### Requirement: handoff 收件箱路径由 roles.tsv 派生

Feature: handoff inbox resolution

handoffd 按 `roles.tsv` 的 worktree 列投递 handoff。agent 侧解析收件箱路径时，SHALL 使用
同一列，MUST NOT 使用进程 cwd（`System/getProperty "user.dir"`）。

两个事实来源一旦不一致，daemon 往 A 投、agent 在 B 找，**双方都不报错**，handoff 链无声
停住。pi-governance 的 QA role 为此停了一天多：收到 6 次唤醒、跑了 6 次
`ready_for_next.sh`、6 次 NO_TASK，而文件一直躺在它自己的 worktree inbox 里。

#### Scenario: 从任意目录都找得到本 role 的收件箱

- **GIVEN** 一个 role 的 worktree 记在 `roles.tsv` 里
- **AND** 进程的 cwd 不是那个 worktree
- **WHEN** 该 role 跑 `ready_for_next`
- **THEN** 它读到的是 `roles.tsv` 指定的那个 worktree 下的 inbox
- **AND** 换成按 cwd 解析的实现，本 scenario 失败

#### Scenario: 非转发闸门也从 role worktree 读

- **GIVEN** `in-process` 目录决定 handoff 是否可转发
- **WHEN** `swarm_handoff` 判断非转发闸门
- **THEN** 它从 `roles.tsv` 的 role worktree 读该目录
- **AND** 按 cwd 解析时，只要 cwd 恰好等于 sender worktree 就会侥幸通过——所以本 scenario
  MUST 在 cwd 不等于 sender worktree 的条件下执行
