## ADDED Requirements

### Requirement: 读不准就报 UNKNOWN，绝不报 IDLE

Feature: read swarm

role 的 pane 状态 SHALL 只分 `BUSY` / `IDLE` / `UNKNOWN` 三种。无法判定时 SHALL 报
`UNKNOWN`，MUST NOT 报 `IDLE`。

`IDLE` 会让 `stop swarm` 放行、让连投的下一步继续；把「不知道」说成「空闲」，安全闸就
在最需要它的时候失效。

#### Scenario: 空白 pane 是 UNKNOWN

- **GIVEN** 某个 role 的 pane 没有可判定的内容
- **WHEN** 读它的状态
- **THEN** 结果是 `UNKNOWN`，不是 `IDLE`

#### Scenario: 认不出的报错文本仍然附上原文

- **GIVEN** pane 里是一段本 verb 不认识的报错
- **WHEN** 读它的状态
- **THEN** 结果是 `UNKNOWN`，且原始文本仍然出现在报告里

#### Scenario: 报出 UNKNOWN 本身是成功

- **GIVEN** 部分或全部 role 读到 `UNKNOWN`
- **WHEN** `read swarm` 结束
- **THEN** 它以 `0` 退出——准确地报告 `UNKNOWN` 是成功，不是失败

### Requirement: 分类必须跟着真实 pane 形状走

判定 SHALL 以 pane 的实际形状为准，MUST NOT 假设最后一行非空即为提示符。

某些 backend 会把状态栏放在提示符**下面**，于是每个 role 都被读成 `UNKNOWN`，`stop swarm`
的 preflight 每次都拒绝，`--force` 变成唯一能停机的路径——一个永远会响的闸没人读。

#### Scenario: 提示符下方有状态栏的 pane 仍能读出 IDLE

- **GIVEN** 一个空闲 role，其 pane 最后一行是状态栏、提示符在它上面
- **WHEN** 读它的状态
- **THEN** 结果是 `IDLE`，且 `stop swarm` 不需要 `--force` 就能停

### Requirement: 读状态绝不写 pane

`read swarm` 是 report verb，它 MUST NOT 调用 `send-keys`。

#### Scenario: 读一次不产生任何注入

- **GIVEN** 任意 swarm 状态
- **WHEN** 运行 `read swarm`
- **THEN** 一次 `send-keys` 都没有发生
