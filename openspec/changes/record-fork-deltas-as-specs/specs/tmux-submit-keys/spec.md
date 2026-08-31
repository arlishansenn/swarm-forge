## ADDED Requirements

### Requirement: 提交键按 agent backend 分发

Feature: tmux submit keys

向 agent pane 注入文本后的提交键 SHALL 按该 role 的 backend 选择：claude backend 用 CSI-u
Enter（`-H 1b 5b 31 33 75`），其余 backend 用裸回车（`-H 0d`）。MUST NOT 使用 tmux 的符号
键名 `C-m` / `C-j`。

符号键名会被 tmux 为「协商了 extended keys 的 TUI」重新编码，然后**永远不提交**：文本贴进
去了，回车没生效，agent 看起来 idle，实际在等一个永不到达的提交。

#### Scenario: 唤醒 claude role 用 CSI-u Enter

- **GIVEN** 一个 backend 为 claude 的 role
- **WHEN** handoffd 唤醒它
- **THEN** 提交键是 CSI-u Enter 的字节序列
- **AND** 换成 `C-m` / `C-j`，本 scenario 失败

#### Scenario: 唤醒 codex role 用裸回车

- **GIVEN** 一个 backend 为 codex 的 role
- **WHEN** handoffd 唤醒它
- **THEN** 提交键是裸回车字节
- **AND** 换成符号键名，本 scenario 失败

#### Scenario: dashboard 注入文本时也走同一套提交键

- **GIVEN** 操作者从 Dashboard 注入一段文本
- **WHEN** pack_web 把它送进目标 pane
- **THEN** 文本原样送达，提交键仍按 backend 分发
- **AND** upstream 在 `inject-target!` 里用的是符号键名，本 scenario 对那份实现失败

### Requirement: notify! 必须知道 backend

`handoffd.bb` 的 `notify!` arity SHALL 是 `[socket session agent]` 或
`[socket session agent await?]`。这是上一条 requirement 的直接后果：提交键要按 backend 选，
`notify!` 就必须拿得到 backend。

#### Scenario: 调用点传入 agent

- **GIVEN** handoffd 要唤醒某个 role
- **WHEN** 它调用 `notify!`
- **THEN** 调用点传入该 role 的 agent
- **AND** 换成 upstream 的两参 arity，`deliver!` 整个抛异常、投递路径完全断掉，连 upstream
  自己的 broadcast 测试也会红
