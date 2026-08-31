## ADDED Requirements

### Requirement: 未领取的 handoff 会被重投

Feature: handoff daemon redelivery

handoffd SHALL 对未领取的 handoff 做电平对账并重发唤醒，MUST NOT 只投一次。upstream 的
投递是一次性的：唤醒丢了就永久卡住。

机制包含 retry ladder、resume floor、busy role 跳过、每轮唤醒预算，以及 cap 耗尽后经
`SWARMFORGE_ALERT_CMD` 告警。

#### Scenario: 唤醒失败的 handoff 留在 inbox 并重试

- **GIVEN** 一个 handoff 已投递但唤醒失败
- **WHEN** handoffd 跑下一轮
- **THEN** 该 handoff 仍在 `inbox/new`，并被再次唤醒
- **AND** 换成一次性投递，本 scenario 失败

#### Scenario: 唤醒失败不隔离该 role

- **GIVEN** 一次唤醒失败
- **WHEN** handoffd 处理这次失败
- **THEN** 它只记日志，该 role 下一轮仍然参与投递

#### Scenario: 重试预算耗尽时告警一次

- **GIVEN** 某个 handoff 的 retry cap 已经用尽
- **WHEN** handoffd 再次遇到它
- **THEN** `SWARMFORGE_ALERT_CMD` 被执行恰好一次
- **AND** 该命令自身失败不会让 handoffd 崩溃

#### Scenario: 所有 tmux 调用都可被测试接缝拦下

- **GIVEN** 设置了 `SWARMFORGE_TMUX_STUB`
- **WHEN** handoffd 需要调用 tmux
- **THEN** 每一次调用都经过 `tmux!`，因而都被 stub 记录
