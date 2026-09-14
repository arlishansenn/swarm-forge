# snapshot-install-safety Specification

## Purpose
把一份 script snapshot 放进一个根目录、以及之后判断那棵树还是不是它应该的样子，这两件事的
安全规则。覆盖：安装的原子性、脏 source checkout 的拒绝、managed project 自己版本控制那棵树
时的归属判定，以及 manifest 归谁写——`start swarm` 的 FRESH/MANAGED/INCOMPLETE 判定只有在
装树的 verb 同时写下描述它的 manifest 时才说得出真话（ADR-0006）。

## Requirements

### Requirement: 安装是原子的，失败整体回滚

Feature: update SwarmForge scripts

装进 managed project 之前，本 verb SHALL 先在本地完整 staging 并校验（required helper 与
terminal adapter 齐全），再原子替换。任何一步失败 SHALL 整体回滚，MUST NOT 留下半装的
script snapshot 或 manifest。

#### Scenario: staging 缺件时目标一个字节都不变

- **GIVEN** staging 出来的树缺一个 required helper
- **WHEN** 运行本 verb
- **THEN** 它点名那个文件并失败，`$ROOT` 逐字节未变

### Requirement: source checkout 脏就拒绝，且无 override

`swarmforge/scripts` 下有未提交改动时 SHALL 拒绝。这条 MUST NOT 有任何 override，
`--force` 也不行——没提交的 source checkout 从来不是安全的发布物。

#### Scenario: --force 也救不了脏的 source

- **GIVEN** source checkout 的 `swarmforge/scripts` 下有未提交改动
- **WHEN** 带 `--force` 运行
- **THEN** 仍然拒绝

### Requirement: managed project 自己版本控制的树不被静默覆盖

目标路径被 managed project 自己 track 时，本 verb SHALL 退出 `8` `OWNED` 并列出每一个会被
写到的 checkout，包含 role worktree copy；MUST NOT 安装，除非收到显式的覆盖 flag。

有的 managed project 把 `swarm` 与 `swarmforge/` 提交在仓库里。装上去不是更新，是接管，
而且曾经在静默中发生：一次运行改写 31 个 tracked 文件、新增 5 个，在**六处**——根加五个
role worktree copy。verb 报成功；随后的 drift 检查发现两边一致，因为那时两者描述的都是
fork 的版本。

#### Scenario: 被 track 时拒绝且零改动

- **GIVEN** managed project 自己 track 着 `swarmforge/scripts`
- **WHEN** 不带覆盖 flag 运行本 verb
- **THEN** 退出 `8`，逐条列出会被写到的每一处，且一个 tracked 文件都没被改动

#### Scenario: 覆盖 flag 与 --force 是两回事

- **GIVEN** 只传了 `--force`
- **WHEN** 目标路径被 track
- **THEN** 仍然退出 `8`——`--force` 管的是过期的锁，不是「无视挡路的一切」

### Requirement: 自管 snapshot 的项目不做 drift 判定

`start swarm` 的 snapshot 状态判定 SHALL 认第四种情况：managed project 自己版本控制了
script snapshot。此时 manifest 描述的不是那棵树，MUST NOT 因两者不一致而报 `4` `DRIFT`。

前三种状态都预设 snapshot 是 operator 装的。自管的项目回滚到自己的版本之后会每次启动都
DRIFT，`--force` 又一次成为常规路径。

#### Scenario: 自管的树带着不匹配的 manifest 也能启动

- **GIVEN** managed project 自己 track 着 script snapshot
- **AND** manifest 与那棵树不一致
- **WHEN** 运行 `start swarm`
- **THEN** 它正常启动，并在报文里说明这次走的是自管那条路

#### Scenario: operator 装的树仍然照常判定 drift

- **GIVEN** script snapshot 是 operator 装的，manifest 与它不一致
- **WHEN** 运行 `start swarm`
- **THEN** 仍然退出 `4` `DRIFT`，launcher 一次都没被调用

### Requirement: 装 script snapshot 的 verb 负责写描述它的 manifest

任何把 script snapshot 落进目标根目录的 verb，SHALL 在同一次运行里写下
`$ROOT/.swarmforge/scripts-manifest`，其 `DIGEST=` 与刚落地的那棵树一致。
MUST NOT 留下「snapshot 在、manifest 不在」的状态交给下一个 verb 收拾。

今天只有 `update SwarmForge scripts` 写 manifest，而 `get-swarm-forge` 装 forge 时
`swarmforge/scripts/` 立刻存在、manifest 从不存在。`start swarm` 的三态判定把这个组合读作
INCOMPLETE 并以 `4` `DRIFT` 拒绝，于是 `--force` 成了启动任何 forge 的唯一办法——而
`--force` 同时关掉的正是 issue #29 建立的 digest 校验。每次都触发的闸门等于没人看的闸门，
issue #58 已经在另一个方向上付过一次这个代价。

这条 requirement MUST NOT 通过修改 `start swarm` 的三态判定来满足。那三个状态本身是对的；
缺的是一个 writer。

#### Scenario: 装完 forge 之后 manifest 与树一致

- **GIVEN** 一个空目录
- **WHEN** 某个 verb 往它里面装一个 forge
- **THEN** `.swarmforge/scripts-manifest` 存在，其 `DIGEST=` 等于 `swarmforge/scripts/` 的 digest

#### Scenario: 装完的 forge 不用 `--force` 就能启动

- **GIVEN** 一个刚装好、尚未启动的 forge
- **WHEN** 不带 `--force` 运行 `start swarm`
- **THEN** 它判定为 MANAGED、校验 digest 通过并正常启动

#### Scenario: 装完之后被改动的树仍然照常报 drift

- **GIVEN** 一个装好并写了 manifest 的 forge
- **AND** 之后有人改动了 `swarmforge/scripts/` 下的文件
- **WHEN** 不带 `--force` 运行 `start swarm`
- **THEN** 它退出 `4` `DRIFT`，launcher 一次都没被调用

#### Scenario: 安装失败就不写 manifest

- **GIVEN** 安装在落地 snapshot 之前或之中失败
- **WHEN** 那次运行结束
- **THEN** `.swarmforge/scripts-manifest` 不存在——半装的树绝不带着一份说它没问题的 manifest
