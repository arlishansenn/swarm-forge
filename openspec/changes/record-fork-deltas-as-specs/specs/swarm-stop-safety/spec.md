## ADDED Requirements

### Requirement: 停机前先报告会打断什么

Feature: stop swarm

`stop swarm` SHALL 在停机之前读每个 role 的 pane 状态与每个 worktree 的 git 状态；任一
role 读到 `BUSY` 或 `UNKNOWN`、或任一 worktree 脏，SHALL 退出 `6` `UNSAFE` 并逐条列出，
且 MUST NOT 调用 close-swarm 或 `kill-session`。

无法核实是否干净时（路径读不到、不是 git 仓库、ssh 抖动）MUST 按不安全处理，绝不当作干净。

upstream 的停机是裸 `close-swarm`：没有宽限、不看 role 状态、不看未提交的工作，等于拔电源。

#### Scenario: 有 role 忙就什么都不碰

- **GIVEN** 某个 role 的 pane 读到 `BUSY`
- **WHEN** 运行 `stop swarm`
- **THEN** 退出 `6`，报文点名该 role，且 `kill-session` 与 close-swarm 都没被调用

### Requirement: 没有真的停下来就不能报 STOPPED

close-swarm 在 target 上执行失败时，本 verb MUST NOT 打印 `STATUS=STOPPED`，也 MUST NOT
以 `0` 退出；SHALL 退出 `5` `ERROR` 并带上 close-swarm 自己的 stderr 与试过的路径。

close-swarm 跑在 **target** 上，而它的默认路径是 operator 自己那台机器。target 的 home
不是那个路径时命令根本不存在，而失败曾被 `|| true` 吞掉：报 `STATUS=STOPPED`、退出 `0`，
六个 tmux session 一个没停。

#### Scenario: close-swarm 不存在时是响的失败

- **GIVEN** 配置的 close-swarm 路径在 target 上不存在
- **WHEN** 运行 `stop swarm`
- **THEN** 退出 `5`，报文含 close-swarm 的 stderr 与试过的路径，且不含 `STATUS=STOPPED`
- **AND** swarm 仍在运行——报文没有对此撒谎

#### Scenario: --force 只豁免 preflight，不豁免「停没停成」

- **GIVEN** 传了 `--force`
- **WHEN** close-swarm 执行失败
- **THEN** 仍然退出 `5`

### Requirement: pack_web 不会比 swarm 活得更久

一次成功的停机之后，本 verb SHALL 按 `pack_web.pid` 停掉该 `$ROOT` 的 pack_web，并报告
`PACK_WEB=stopped|absent`。

close-swarm 只知道 tmux。留着的 pack_web 加上之后用固定端口重启，会让同一个 `$ROOT` 有
两个活的 pack_web——正是 Dashboard 的端口归属检查要拒绝的局面。

#### Scenario: 停机后 pack_web 不再存活

- **GIVEN** `$ROOT` 有一个正在运行的 pack_web，其 pid 记在 `pack_web.pid`
- **WHEN** 一次停机成功完成
- **THEN** 该进程不再存活，pid 文件被删除，报文含 `PACK_WEB=stopped`
