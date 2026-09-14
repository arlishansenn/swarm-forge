# 0006. 装 script snapshot 的 verb 负责写描述它的 manifest

Status: accepted
Date: 2026-09-14

## Context

issue #29 给 `start swarm` 加了 drift preflight：把被管 project 已装的
`swarmforge/scripts/` 重算一次 digest，与 `$ROOT/.swarmforge/scripts-manifest` 比对，不一致
就 `4` `DRIFT`、绝不调用 launcher。issue #35 把判定细分成三态——FRESH（两者都不在）、
MANAGED（两者都在）、INCOMPLETE（只有一个在）。

当时 manifest 只有一个 writer：`update SwarmForge scripts`。这在 pack 那条路上是自洽的，
因为 `onboard project` 装的 pack 分支**不含** `swarmforge/scripts`，落地后两个 artifact
都不在，是干净的 FRESH，首跑 bootstrap 归 launcher 管。

forge 那条路打破了它。`get-swarm-forge` 装 forge 时 `copy_shared_scripts_and_articles`
立刻把 `swarmforge/scripts/` 拷进去，而它不写 manifest（`grep -n manifest get-swarm-forge`
为空）。于是每一个新装的 forge 都落在 INCOMPLETE：snapshot 在、manifest 不在、forge root
又不是 git repo 所以 `PROJECT_OWNED=0`。**任何 forge 都只能靠 `--force` 启动**，而
`--force` 同时跳过 digest 比对——那道为 issue #29 而建的闸门，在 forge 上从第一天起就是关的。

每次都触发的闸门等于没人看的闸门。issue #58 已经在另一个方向上付过一次这个代价，
issue #87 的 `.gitignore` 块也是同一条教训的产物。

三条路能修它：改 `get-swarm-forge` 让它写 manifest；改 `start swarm` 认第四种形状
（`projects/` 存在 ⇒ forge）并跳过校验；或者让装 forge 的那个 verb 自己写。第二条把
「检查不了」写成「不检查」，而 forge 的 `swarmforge/scripts/` 正是 D-9 最该盯的那棵树。
第一条要改 upstream 也拥有的安装器，而且它同时服务 pack 路径，改它会一并动到
`onboard project` 刻意保留的 FRESH 语义。

## Decision

**装 script snapshot 的 verb，在同一次运行里写下描述那棵树的 manifest。**

这条对所有安装路径成立，不只对 forge：谁把树落地，谁就负责让
`$ROOT/.swarmforge/scripts-manifest` 的 `DIGEST=` 与它一致；装失败就不写，绝不留下「半装的
树带着一份说它没问题的 manifest」。

推论有三条。一，`start swarm` 的三态判定**不改**——那三个状态本身是对的，缺的是 writer，
不是多一个状态。二，`get-swarm-forge` 不改——它是 upstream 也拥有的文件，而这个责任落在
调用它的 verb 上同样成立。三，`onboard project` 今天不装 snapshot，所以它今天不写
manifest；哪天它开始装了，它就得开始写。

## Consequences

forge 从第一次启动起就是 MANAGED 状态，digest 校验在 forge 上真正生效，`--force` 退回它
本来的地位：人在知情前提下的一次例外，不是启动的常规做法。

代价是 manifest 的 writer 从一个变成多个，「谁写的」这件事不再能靠文件本身回答。
`read_manifest` 只读 `DIGEST=`，`SOURCE_REPO=` 与 `SOURCE_COMMIT=` 是给人看的出处记录，
所以这个代价停在可读性上，不影响正确性。tarball 安装路径拿不到 commit id，那两行会是
`SOURCE_REPO=<repo_url>#<branch>` 与 `SOURCE_COMMIT=unknown`。

还有一个缺口被这个决定照出来但没有被它填上：forge 装好之后本 fork 的 `main` 往前走了，
forge 的 snapshot 就旧了，而现在它有 manifest，所以 `start swarm` 会**正确地**拦住它。
`update SwarmForge scripts` 今天只认被管 project，不认 forge，所以恢复手段暂时是重跑安装。
这需要单独一张票。
