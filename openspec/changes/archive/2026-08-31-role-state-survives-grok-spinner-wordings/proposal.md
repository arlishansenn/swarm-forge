## Why

`read swarm` 把正在工作的 Grok role 读成 `IDLE`。`stop swarm` 共用同一套判定，于是
preflight 全绿、直接 `kill-session`，**打断真实工作且不给任何提示**。

在 coder2 的 pi-governance 上，一次 `read swarm` 六个 role 全报 `IDLE`，而当时
specifier 是 `⠧ Responding… 5.7s`、coder 是 `⠦ Thinking… 1.4s`，两个都在跑。

根因是 `BUSY_RE` 只列了三种文案，Grok 的 `Thinking…` 与 `Responding…` 一种都不匹配：
不含 `esc to interrupt`；`Thinking… 1.4s` 没有 ` for `，所以 `<participle> for Ns`
够不着；也不含 `Waiting for response`。BUSY 一条不命中，紧邻下方的空 prompt 命中 IDLE。

**方向比 issue #58 更糟。** 那一条让每个 Grok role 读成 `UNKNOWN`——烦，但安全；这一条
读成 `IDLE`，而 `IDLE` 是放行信号。

## What Changes

- `BUSY_RE` 增加一条**形状**判据：participle 紧跟省略号（`Thinking…` / `Responding…`），
  单字符省略号与三个点都接受。不逐个追文案。
- `FOOTER_RE` 不再要求末尾的 `transcript`。Grok 排队时 footer 变成
  `· 1 queued · /queue · ctrl+o`——**多了排队信息、少了那个词**，于是要求该词的模式在
  role 最忙的时候恰好认不出 footer，#58 的失败换条路又回来。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `role-state-reading`: 新增两条 requirement。用 **ADDED**：给既有 capability 补新的
  关注点，没有改动它已有的任何行为判定。

## Impact

- `scripts/lib-wake-talk.sh`：两个正则各加一条/放宽一处。
- `scripts/test-read-swarm.sh` +4 case，`scripts/test-stop-swarm.sh` +1 case。
- `read swarm` 与 `stop swarm` 共用这段判定，两者一起受益——它们本来就不允许分歧。
