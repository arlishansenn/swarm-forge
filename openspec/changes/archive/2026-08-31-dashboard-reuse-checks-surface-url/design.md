## Context

`open-dashboard.sh` 的复用路径今天这样写：

```sh
SURF=$(browser_surface "$WS_UUID")
if [ -z "$SURF" ]; then ... cmux new-surface --url "$URL" ... ; fi
```

而 `browser_surface()` 从 `surface.list` 里挑第一个 `type=="browser"` 的，**不看 url**。
所以「有 surface」就等于「不用管它指向哪」，而紧接着的报文照样打印新的 `URL=`。

issue #18 让这个 verb 确认端口后面是本项目的 pack_web；issue #100 让它先确认这个项目在跑。
两条都保证了「服务端是对的」，没有一条保证「客户端看到的是它」。本 change 补最后一环。

在效的 ADR：`adr/0001`、`adr/0002`、`adr/0003`，均与本 change 无关，不提议改动。

## Goals / Non-Goals

**Goals**

- 复用出来的 surface 指向本次的 URL。
- 报文的 `URL=` 与 surface 实际指向的地址一致。
- 已经正确时零 mutation。

**Non-Goals**

- 不校验页面**内容**渲染成什么样，只校验 surface 的目标 url。
- 不关闭或重建 workspace——这个 verb 从不做清理，那条边界不动。
- 不改新建 workspace 的路径（它本来就带着正确的 URL 建）。

## Decisions

**用 `cmux browser --surface <ref> get-url` 读，不用 `surface.list` 里的 `url` 字段。**
两者回答的不是同一个问题：`get-url` 是「这个 surface 现在在哪」，而 `surface.list` 的字段
记的是创建时给的地址。人手工导航过、或本 verb 自己导航过之后，只有前者一定是最新的。用后
者做判据，最好的情况是每次都误判为陈旧从而重复导航（违反「零 mutation」那条），最坏是把
一个已经被人导航正确的 surface 又拽回去。多一次 cmux 调用换一个不会漂的判据，值得。

**只在复用路径上读。** 新建路径的 surface 是用本次 URL 建的，没有可疑之处，不必付这次调用。

**不一致就 `goto`，不重建。** 重建会丢掉那个 surface 上的浏览状态，而且新建/删除是比导航
重的 mutation。`goto` 是最小的、且正好是人工恢复时用的同一条命令。

**导航失败不静默。** 若 `goto` 之后 url 仍与目标不符，本 verb 不报成功——这正是本 change
要终结的那种「报文与屏幕不一致」。

## Risks / Trade-offs

- [复用路径多一次 cmux 调用] -> 只在复用时发生；换来的是报文不再说谎。
- [`get-url` 在页面未就绪时可能返回中间值] -> 判据是「与目标不符就导航」，多导航一次是幂等
  的；真正要避免的是**从不**导航。
- [人手工把 surface 导航到别处后，本 verb 会把它拽回] -> 这是本 verb 的职责：它开的是这个
  项目的 Dashboard。若将来需要「尊重人工导航」，那是另一个决定，不在本 change。

## Migration Plan

无迁移。行为改变只发生在复用路径且 url 不一致时。回滚即移除那次校验与导航。

## Open Questions

- `surface.list` 的 `url` 字段在一次 `goto` 之后是否会更新？本 change 不依赖它，所以不阻塞；
  但如果它会更新，将来可以省掉那次 `get-url` 调用。
