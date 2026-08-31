## Why

`dashboard` 报 `STATUS=REUSED`、退出 `0`、报文里 `URL=` 是当前正确的地址，**而复用的那个
cmux browser surface 仍然停在上一个（已死）端口的错误页**。要手工
`cmux browser --surface <ref> goto <url>` 才恢复。一轮操作里遇到两次。

这不是偶发：`pack_web` 每次启动绑新端口（除非用了 `--dashboard-port`），所以**重启一次
swarm，复用出来的 surface 就必然是旧地址**——陈旧才是常态，不是例外。

根因在两处合起来：`browser_surface()` 只按 `type=="browser"` 选，**从不看 url**；而复用
路径只在 surface **缺失**时才修，存在就原样留下。报文却照样打印新的 `URL=`。

来源 issue #99。它与 #82、#100 是同一族：**报告与现实不符，而报告是说谎的那一方**。
#82 报了 `STOPPED` 但没停；#100 报了 `ERROR` 但只是没开机；这条报了新 URL 但画面是旧的。

这个 verb 唯一的产出就是「让人看见 Dashboard」。issue #18 的端口归属检查保证了**端口
后面**是本项目的 pack_web，#100 保证了**这个项目在跑**，但没有任何东西保证**屏幕上**渲染
的是那个端口。链条的最后一环缺着。

## What Changes

- 复用已有 workspace 时，读一次该 browser surface 当前指向的 url；与本次要开的 URL 不一致
  就导航过去，不再原样留下。
- url 本来就一致时不产生任何 cmux mutation——`REUSED` 的意义就是不折腾。
- 报文里的 `URL=` 与 surface 实际指向的地址一致；做不到就不报成功。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `dashboard-access`: 新增一条关于「复用的 surface 必须指向本次的 URL」的 requirement。
  用 **ADDED**：既有四条 requirement 没有一条涉及 browser surface，这是补新关注点，
  不改任何已有行为。

## Impact

- `scripts/open-dashboard.sh`：复用路径增加一次 url 读取与条件导航。
- `scripts/test-open-dashboard.sh`：新增陈旧 surface 与一致 surface 两个 case。
- 不影响新建 workspace 的路径、`3` / `4` 的判定，以及 `--tailnet`。
