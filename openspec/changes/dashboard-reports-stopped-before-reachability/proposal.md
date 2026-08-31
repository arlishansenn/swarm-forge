## Why

swarm 停机时，`dashboard` 报 `5` `ERROR` 并给出**误导性**说明，而不是契约里写好的
`3` `STOPPED`。`--tailnet` 那条更糟：它给的补救命令**已经做过了**，照做没有任何作用。

实测（podsum，swarm 已停）：不带 flag 得到
`tunnel up but http://127.0.0.1:7780/ did not return 200 in 10s`——听起来像隧道或网络
故障；带 `--tailnet` 得到「that port is not published on the tailnet，去跑
`tailscale serve --bg --tcp 7780 ...`」——而 `tailscale serve status` 里 7780 早就在。

真实原因只是 swarm 没在跑：`pack_web.pid` 不存在，而这正是 `openspec/specs/dashboard-access`
里已经写明该报 `3` 的那一格。代码到不了那一行，因为 HTTP 可达性检查排在归属检查**之前**，
先 `die 5` 了。`stop swarm` 会删 `pack_web.pid`，但不动 `dashboard-url`，所以停机后那个
文件仍在，读端口这一步不会失败。

来源 issue #100。它与 issue #82、#99 是同一族：**报告与现实不符，而报告是说谎的那一方**。
#82 报了 `STOPPED` 但没停；#99 报了新 URL 但画面是旧的；这条报了 `ERROR` 但其实只是没开机。

## What Changes

- pid / `--serve` 归属检查移到 HTTP 可达性检查**之前**。`pack_web.pid` 缺失或其进程已死时
  退 `3` 并说明 swarm 没在跑，不再退 `5`。
- `--tailnet` 的「端口未发布」提示只在**确实没发布**时出现。已发布但无人监听时，报文不再
  建议再跑一次 `tailscale serve`。
- 端口被别的项目的 pack_web 占用时仍然 `4` `DRIFT`（issue #18 的既有行为不动）。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `dashboard-access`: 两条既有 requirement 的行为改变——
  「端口后面必须是本项目自己的 pack_web」补上**检查顺序**这一约束；
  「走 tailnet 时不建隧道也不碰 tailscale」把「端口没发布」的报文限定到真正没发布的情形。
  两条都用 **MODIFIED**，整块拷进 delta 再改。

## Impact

- `scripts/open-dashboard.sh`：调整两段检查的顺序，并给 `--tailnet` 的失败分支加一次
  「是否已发布」的判别。
- `scripts/test-open-dashboard.sh`：新增停机场景在两条路径上的 case。
- 不影响正常运行时的成功路径，也不影响 `4` `DRIFT` 与隧道端口回退。
