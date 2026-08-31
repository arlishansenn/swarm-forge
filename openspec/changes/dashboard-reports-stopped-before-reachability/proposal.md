## Why

swarm 停机时，`dashboard` 报 `5` `ERROR` 并给出**误导性**说明，而不是契约里写好的
`3` `STOPPED`。`--tailnet` 那条更糟：它给的补救命令**已经做过了**，照做没有任何作用。

实测（podsum，swarm 已停）：不带 flag 得到
`tunnel up but http://127.0.0.1:7780/ did not return 200 in 10s`——听起来像隧道或网络
故障；带 `--tailnet` 得到「that port is not published on the tailnet，去跑
`tailscale serve --bg --tcp 7780 ...`」——而 `tailscale serve status` 里 7780 早就在。

**但把这条读成「两块代码放反了」是看小了。** 把十一个 verb 摊开看，它们互不调用，全部靠
managed project 的 `.swarmforge/` 里那几个 runtime 文件协调，而其中六个共用同一条判定：
读 `tmux-socket` 拿 socket 路径，再探一次 `list-sessions`——**文件存在不算活着，必须探
运行时**。`open swarm`、`start swarm`、`stop swarm`、`read swarm`、`wake role`、
`talk role`、`update SwarmForge scripts` 都这么做。

`dashboard` **是唯一一个不问这个问题的 verb**，也是唯一一个一个共享 lib 函数都不用的
verb：它只看 `dashboard-url` 与 `pack_web.pid`，两次远端调用都是自己内联的。所以那条判定
从来没有传导进它。

两个 artifact 的寿命还不一样：`dashboard-url` 由 pack_web 写，**没有任何 verb 删它**；
`pack_web.pid` 由 pack_web 写、由 `stop swarm` 删。停机后两个输入互相矛盾，而这个 verb
没有第三个来源打破平局，于是先撞上网络检查、报 `5`。

来源 issue #100。它与 #82、#99 是同一族：**某个 verb 信了一个 artifact，没有和另一个交叉
验证**。#82 报了 `STOPPED` 但没停；#99 报了新 URL 但画面是旧的；这条报了 `ERROR` 但只是
没开机。

## What Changes

- `dashboard` 接上六个兄弟共用的 liveness gate：读 `tmux-socket` 并探 `list-sessions`。
  swarm 没在跑 → `3` `STOPPED`，**排在一切之前**。
- pid / `--serve` 归属检查移到 HTTP 可达性检查**之前**。`pack_web.pid` 缺失或其进程已死时
  退 `3`，不再退 `5`。
- **BREAKING（行为）**：swarm 已停但 pack_web 仍在跑的项目，此前会被打开，现在会被
  `3` 拒绝。这是有意的——这个 verb 开的是**某个 swarm 的** Dashboard，swarm 不在就没有可
  看的东西；而 `stop swarm` 自 issue #82 起本来就会连 pack_web 一起停，这一格只可能出现在
  绕过该 verb 停机的情况下。
- `--tailnet` 的「端口未发布」报文**不动**。顺序修好之后它只在 swarm 确认在跑时才可能出现，
  那时 pack_web 确实在 loopback 上监听，「没发布」就是正确诊断。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `dashboard-access`: 一条既有 requirement 改行为（归属检查的位置），并新增一条关于
  liveness gate 的 requirement。前者用 **MODIFIED** 整块拷贝再改，后者用 **ADDED**。

## Impact

- `scripts/open-dashboard.sh`：接上 `lib-wake-talk.sh` 的 `read_file` / `tmux_remote`，
  新增 liveness gate，并把归属检查前移。
- `scripts/test-open-dashboard.sh`：新增停机场景在两条路径上的 case，以及 socket 失活的 case。
- 不影响 `4` `DRIFT`、成功路径与隧道端口回退。
