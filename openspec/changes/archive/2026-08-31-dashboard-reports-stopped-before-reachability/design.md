## Context

十一个 operator verb 互不调用。协调全部发生在 managed project 的 `.swarmforge/` 下的
runtime 文件上，而其中六个共用同一条判定：读 `tmux-socket`，再探一次 `list-sessions`。
socket 文件在、后面没有 server —— 一律当没在跑。这条「文件存在不算活着」的规则是从窗口
watchdog 拆掉整个 swarm 那次事故长出来的，今天是这些 verb 唯一的共同语言。

`dashboard` 游离在外：它不读 `tmux-socket`，也不用任何共享 lib 函数（其余每个 verb 至少用
`read_file`）。它自己内联两次远端调用，只看 `dashboard-url` 与 `pack_web.pid`。

那两个 artifact 寿命不同：`dashboard-url` 由 pack_web 写，**没有任何 verb 删它**；
`pack_web.pid` 由 pack_web 写、由 `stop swarm` 删。停机之后前者陈旧、后者准确，两个输入
互相矛盾，而这个 verb 没有第三个来源裁决。

在效的 ADR：`adr/0001`、`adr/0002`、`adr/0003`，三条与本 change 均无关，不提议改动。

## Goals / Non-Goals

**Goals**

- `dashboard` 使用与其它 verb 相同的 liveness 判定，不再是孤儿。
- 停机的项目在两条路径上都报 `3` `STOPPED`。
- `4` `DRIFT` 与成功路径行为不变。

**Non-Goals**

- 不让 `dashboard` 代为启动 pack_web 或 swarm。
- 不改 `stop swarm` 是否该删 `dashboard-url`。留着它是有意的（`run issue` 靠它读端口）。
- 不动隧道回退到空闲端口的逻辑。
- **不改 `--tailnet` 的「端口未发布」报文。** 见下。

## Decisions

**接上共用的 liveness gate，而不是只调两块代码的顺序。** 只调顺序能修好症状，但这个 verb
仍然是唯一一个不问「swarm 在不在跑」的。下一次有人改那条共用判定（例如 issue #92 改
`BUSY_RE`、issue #58 改 footer），改动会传导进六个 verb 而独独漏掉它——这正是它这次掉队
的原因。接上之后它和兄弟们说同一种话。

**gate 排在最前，归属检查紧随其后，两者都在可达性之前。** 两个问题是不同的：gate 问「这个
项目在跑吗」，归属检查问「这个端口是谁的」。前者答否就没有后者可问。

**不跑 `tailscale serve status` 去判别「已发布 vs 已发布但没人听」。** 最初的设计想这么做，
但它撞上 `dashboard-access` 已有的一条 requirement——「MUST NOT 执行任何 `tailscale`
命令」，还有两条测试断言钉着。而且它是多余的：顺序修好之后，那段报文只在 swarm 确认在跑
时才可能出现，此时 pack_web 确实在 loopback 上监听，「没发布」就是正确诊断。少写一段代码
又不破坏既有约束，两头都赚。

**代价，明写：swarm 已停但 pack_web 仍在跑的项目，现在会被 `3` 拒绝，此前会被打开。** 这是
有意的——本 verb 开的是**某个 swarm 的** Dashboard，swarm 不在就没有可看的东西。而且自
issue #82 起 `stop swarm` 会连 pack_web 一起停，所以这一格只可能出现在绕过该 verb 停机的
情况下。

**另一处代价：** 不带 `--tailnet` 的 ssh 路径，其两道检查现在都发生在建隧道之前。issue #78
当时保留旧序是为了「ssh 路径逐字节不变」，本 change 有意打破——那次保留正是这个 bug 的
来源。可观察差别只有一个：会被 `4` DRIFT 拒绝的项目不再先留下一条 ssh 隧道。那是改进。

## Risks / Trade-offs

- [多两次远端调用] -> 都在失败路径与前置检查上，且 `read_file` / `tmux_remote` 与其它 verb
  同源，不引入新的连接方式。
- [ssh 路径块序变了] -> 既有的 `4` DRIFT 与成功用例必须保持绿，作为没有回归的证据。
- [pack_web 独活的项目被拒] -> 上面已明写为有意取舍；报文说明 swarm 没在跑，人知道下一步
  是 `start swarm`。

## Migration Plan

无迁移。行为改变只发生在此前会报 `5` 的失败路径，以及 swarm 已停而 pack_web 独活这一格。
回滚即移除 gate 并还原两段顺序。

## Open Questions

- `stop swarm` 要不要顺手删掉 `dashboard-url`？删了能让读端口这一步自己失败。但别的 verb
  依赖它读端口，本 change 不动；如果以后发现陈旧 `dashboard-url` 在别处也造成误判，再单独
  决定。
