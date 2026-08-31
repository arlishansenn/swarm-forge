# swarm-start-safety Specification

## Purpose
TBD - created by archiving change record-fork-deltas-as-specs. Update Purpose after archive.

## Requirements

### Requirement: 终端 backend 必须由人明确选择

Feature: start swarm

`start swarm` SHALL 要求 `--terminal`，MUST NOT 自行探测后默默启动。可选值是
`SWARMFORGE_TERMINAL` 的规范 backend，另加 `auto` 这个哨兵——`auto` 表示「我知道有自动
探测，我明确选它」，且 MUST NOT 被原样转发成 `SWARMFORGE_TERMINAL` 的值。

从没有真实终端的 ssh 会话里启动时，`osascript` 存在就足以让自动探测选中 `terminal-app`，
而窗口 watchdog 找不到那个窗口，几秒内把整个 swarm 拆掉。这个失败在人手操作下重现过两次。

#### Scenario: 缺 --terminal 就什么都不启动

- **GIVEN** 命令行没有 `--terminal`
- **WHEN** 运行 `start swarm`
- **THEN** 退出 `2` `USAGE`，launcher 一次都没被调用

#### Scenario: auto 不作为字面值转发

- **GIVEN** `--terminal auto`
- **WHEN** launcher 启动
- **THEN** 它的环境里没有 `SWARMFORGE_TERMINAL`，自动探测照常运行

### Requirement: 已在运行的 swarm 拒绝二次启动

socket 上有活的 tmux server 时，`start swarm` SHALL 退出 `6` `UNSAFE`，且这条 MUST NOT
有任何 override。socket 文件在但没有活 server，不算「已在运行」——那正是本 verb 要恢复的
停机状态。

#### Scenario: 陈旧 socket 不算已在运行

- **GIVEN** `tmux-socket` 文件存在但其后没有活的 server
- **WHEN** 运行 `start swarm`
- **THEN** 它继续启动，而不是拒绝

### Requirement: 启动是脱离的，成功以 runtime 文件为准

launcher SHALL 以脱离方式启动，因此本 verb MUST NOT 检查 launcher 自己的退出码；它只信
launcher 应当产生的 runtime 文件。

#### Scenario: launcher 在启动它的进程返回之后仍然活着

- **GIVEN** launcher 需要比本 verb 返回控制权更长的时间
- **WHEN** 本 verb 已经返回，且 launcher 收到 SIGHUP
- **THEN** launcher 仍然跑完并写下它的 runtime 文件
