## ADDED Requirements

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
