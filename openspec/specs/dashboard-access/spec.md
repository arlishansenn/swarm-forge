# dashboard-access Specification

## Purpose
TBD - created by archiving change record-fork-deltas-as-specs. Update Purpose after archive.

## Requirements

### Requirement: 端口后面必须是本项目自己的 pack_web

Feature: dashboard

HTTP 200 只证明**有东西**在应答那个端口，不证明它是本项目的 Dashboard。开任何 workspace
之前，本 verb SHALL 读 `$ROOT/.swarmforge/pack_web.pid` 并确认该进程的 `--serve` 参数等于
`$ROOT`；这项检查 MUST 直接打到 target 或本机，MUST NOT 经隧道——隧道只转发 HTTP，不携带
远端主机的进程身份。

这项检查 SHALL 排在 HTTP 可达性检查**之前**。顺序反过来时，一个只是停机的项目会先在可达性
那一步 `die 5`，永远走不到本条判定——而 `stop swarm` 删 `pack_web.pid` 却留下
`dashboard-url`，所以「读端口」这一步不会失败，停机状态因此被报成 verb 故障。

#### Scenario: 端口被同机别的项目占用时拒绝

- **GIVEN** 端口应答 200，但持有它的 pack_web 的 `--serve` 指向另一个 root
- **WHEN** 运行 `dashboard`
- **THEN** 退出 `4` `DRIFT`，报文点名实际的那个 root，且一次 cmux 调用都没发生

#### Scenario: pid 文件缺失或进程已死是 STOPPED 而不是 DRIFT

- **GIVEN** `pack_web.pid` 不存在，或它记的进程已经不在
- **WHEN** 运行 `dashboard`
- **THEN** 退出 `3`，且 MUST NOT 代为启动 pack_web

#### Scenario: 停机项目在两条路径上都报 STOPPED

- **GIVEN** swarm 已停：`pack_web.pid` 不存在，而 `dashboard-url` 仍留在磁盘上
- **WHEN** 运行 `dashboard`，无论带不带 `--tailnet`
- **THEN** 退出 `3`，报文说明没在跑
- **AND** MUST NOT 退出 `5`——把「没开机」报成「verb 坏了」，会让人去查隧道与网络，而
  正确动作只是 `start swarm`
- **AND** 把归属检查换回可达性之后，本 scenario 失败

### Requirement: 绝不代为启动 pack_web 或 swarm

本 verb SHALL 只连接已在运行的东西。它 MUST NOT 启动 pack_web、MUST NOT 启动 swarm、
MUST NOT 关闭任何 workspace 或 window 作为清理。

#### Scenario: dashboard-url 缺失时停下来

- **GIVEN** `$ROOT/.swarmforge/dashboard-url` 不存在
- **WHEN** 运行 `dashboard`
- **THEN** 退出 `3`，什么都没启动

### Requirement: 走 tailnet 时不建隧道也不碰 tailscale

带 `--tailnet` 时，本 verb SHALL 从 `--target` 取 tailscale IP、确认 `http://<ip>:<port>/`
应答 200，并报 `TUNNEL=tailnet`。它 MUST NOT 执行任何 `tailscale` 命令——发布端口是操作者
的一次性动作，那份 serve 配置不归本 verb 创建、修复或清理。

不带该 flag 时行为不变：建 SSH local-forward，报 `TUNNEL=created` 或 `reused`。

#### Scenario: 端口没发布时干净退出并给出该敲的命令

- **GIVEN** `--tailnet`，且该端口没有在 tailnet 上发布
- **WHEN** 运行 `dashboard`
- **THEN** 退出 `5`，报文含目标 URL 与该执行的 `tailscale serve` 命令原文
- **AND** 没有建 workspace，没有建隧道，也没有执行任何 `tailscale` 命令

### Requirement: 先探 swarm 是否在跑，用与其它 verb 相同的判定

Feature: dashboard

在做任何网络可达性检查之前，本 verb SHALL 用与 `open swarm` / `start swarm` /
`stop swarm` / `read swarm` / `wake role` / `talk role` / `update SwarmForge scripts`
**完全相同**的判定问一次 swarm 是否在跑：读 `$ROOT/.swarmforge/tmux-socket`，再探一次
`list-sessions`。socket 文件存在但其后没有 server，SHALL 判作没在跑。

这些 verb 互不调用，只靠 `.swarmforge/` 下的 runtime 文件协调，所以「文件存在不算活着，
必须探运行时」这条判定是它们唯一的共同语言。本 verb 此前不参与它——只看 `dashboard-url`
与 `pack_web.pid`，而这两个 artifact 寿命不同（前者没有任何 verb 会删），停机后互相矛盾
且无从裁决。

#### Scenario: swarm 没在跑时先报 STOPPED

- **GIVEN** `tmux-socket` 存在，但其后没有活的 tmux server
- **WHEN** 运行 `dashboard`，无论带不带 `--tailnet`
- **THEN** 退出 `3`，报文说明 swarm 没在跑
- **AND** MUST NOT 建隧道、MUST NOT 打 tailnet 地址、MUST NOT 调用 cmux
- **AND** 去掉这道 gate，本 scenario 失败
