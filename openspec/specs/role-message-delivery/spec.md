# role-message-delivery Specification

## Purpose
TBD - created by archiving change record-fork-deltas-as-specs. Update Purpose after archive.

## Requirements

### Requirement: 送进去要确认真的送到了

Feature: wake role / talk role

向某个 role 注入文本时，本 verb SHALL 确认文本真的落进了它的输入行，再发提交键，
MUST NOT 只发一次就当作成功。

#### Scenario: 提交键始终没落地时报失败

- **GIVEN** 注入的文本没有出现在目标 pane 的输入行
- **WHEN** 本 verb 完成
- **THEN** 它报失败，而不是报送达

#### Scenario: 未知 role 与死 socket 都是响的失败

- **GIVEN** role 名不存在，或 socket 后面没有活的 server
- **WHEN** 运行本 verb
- **THEN** 它以非零码退出并说明原因

### Requirement: 绝不用符号键名提交

本 verb MUST NOT 用 `C-m` 或 `C-j` 提交。理由与提交键的分发规则同源，见
`tmux-submit-keys`。

#### Scenario: 提交用的是字节而不是键名

- **GIVEN** 任意一次注入
- **WHEN** 检查发出的 tmux argv
- **THEN** 其中没有 `C-m`，也没有 `C-j`
