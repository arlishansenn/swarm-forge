# role-state-reading Specification

## Purpose
TBD - created by archiving change record-fork-deltas-as-specs. Update Purpose after archive.

## Requirements

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

### Requirement: spinner 判据按形状，不按文案

Feature: read swarm

判定一个 role 是否在工作时，SHALL 匹配 spinner 行的**形状**，MUST NOT 依赖某个
backend 当前用的具体措辞。

一个 backend 的 spinner 文案不止一种，而且会变。逐条追下去是必输的比赛：每漏一条，
那个 role 就读成 `IDLE`，而 `IDLE` 是放行信号——`stop swarm` 共用这套判定，会据此
`kill-session`，打断真实工作且不给任何提示。

#### Scenario: 未见过的 participle spinner 也读作 BUSY

- **GIVEN** 某个 role 的 pane 顶部是一行 participle 紧跟省略号的 spinner，下面是空 prompt
- **WHEN** 读它的状态
- **THEN** 结果是 `BUSY`
- **AND** 该判定不依赖那个 participle 具体是哪个词——换一个词，结论不变

#### Scenario: 正在工作的 role 挡住停机

- **GIVEN** 某个 role 的 pane 显示它正在工作
- **WHEN** 运行 `stop swarm`
- **THEN** 它退出 `6` `UNSAFE`，报文点名该 role
- **AND** `close-swarm` 与 `kill-session` 都没有被调用

### Requirement: footer 判据只认它稳定的那部分

Feature: read swarm

丢弃 pane 尾部静态 footer 时，SHALL 只匹配 footer 各变体共有的那部分，MUST NOT 要求
只在某些变体里出现的内容。

Grok 的 footer 在有排队时会多出排队信息、同时**少掉**末尾那个词。要求那个词的模式，
会在 role 最忙的时候恰好认不出 footer——而 footer 认不出就会顶掉 classifier 的窗口，
把状态行挤出视野。

#### Scenario: footer 的排队变体照样被丢弃

- **GIVEN** 某个正在工作的 role，其 footer 是带排队信息的那种变体
- **WHEN** 读它的状态
- **THEN** footer 被丢弃，spinner 行仍在 classifier 的窗口内，结果是 `BUSY`

#### Scenario: 放宽之后空闲的 role 仍然读作 IDLE

- **GIVEN** 某个空闲 role，其 footer 是同一种排队变体
- **WHEN** 读它的状态
- **THEN** 结果是 `IDLE`——放宽 footer 判据不得把每个 role 都读成在工作
