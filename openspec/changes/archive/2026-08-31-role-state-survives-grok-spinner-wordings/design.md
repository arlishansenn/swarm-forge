## Context

`lib-wake-talk.sh` 的 `classify` 由 `read swarm` 与 `stop swarm` 共用，本仓库明写这两个
verb 对 role 状态**不允许有分歧**。所以这里的每一个漏判都同时是一个报告缺陷和一个安全
缺陷。

在效的 ADR：`adr/0001`、`adr/0002`、`adr/0003`。三条都与本 change 无关，不提议改动。

## Goals / Non-Goals

**Goals**

- 正在工作的 Grok role 读作 `BUSY`，因而挡得住 `stop swarm`。
- 判据能覆盖没见过的 spinner 文案。
- 空闲 role 仍然读作 `IDLE`——修复不得把安全方向推过头，变成「什么都停不了」。

**Non-Goals**

- 不去枚举每个 backend 的每一种 spinner 文案。
- 不改 `UNKNOWN` 的边界：读不准仍然报 `UNKNOWN`，不猜。
- 不改 `PANE_CLASSIFY_LINES` 的窗口大小。

## Decisions

**加形状，不加文案。** `[A-Za-z]+(ed|ing)(…|...)` 抓的是「participle 紧跟省略号」，
`Thinking…` 与 `Responding…` 都在其中，下一个还没出现的词也在。这正是 SKILL.md 自己
说过的「逐个追是必输的比赛」。

**仍然不把 braille spinner 字符写进判据。** 文件里原有的理由没有失效：unicode chrome
未必逐字节 round-trip，文本才是稳的那部分。而上面那个形状不需要它就够了——加进去只是
多一个可能失效的依赖。

**`FOOTER_RE` 放宽到 `ctrl+o`。** 两种 footer 变体共有的就是它。只丢弃**尾部**匹配行，
所以放宽不会吃掉正文里提到这个按键的内容。代价是一行恰好以 `ctrl+o` 结尾的正文会被
当 footer 丢掉——比"忙的时候认不出 footer"轻得多，而后者已经真实发生过两次。

**修复方向偏向 BUSY。** 误报 BUSY 的代价是多问一次人；误报 IDLE 的代价是无声打断工作。
两者不对称，判据就该不对称。

## Risks / Trade-offs

- [形状匹配把正文里的 "Thinking…" 读成 BUSY] -> classifier 只看最后两行，且偏向 BUSY
  本就是安全方向；多停一次的代价远小于杀错一次。
- [放宽 footer 吃掉正文] -> 只丢尾部行；并加了一条「空闲 role 在同一 footer 变体下仍读
  IDLE」的 case，防止修复把所有 role 推成 BUSY。

## Migration Plan

无迁移。下一次 `read swarm` / `stop swarm` 自然生效。回滚即还原两个正则。

## Open Questions

- 其它 backend 的 spinner 是否也有本形状覆盖不到的变体？目前只有 Grok 的现场样本。
  下次出现同类误判时，先看是不是又一种没被形状覆盖的写法，再决定要不要动窗口大小。
