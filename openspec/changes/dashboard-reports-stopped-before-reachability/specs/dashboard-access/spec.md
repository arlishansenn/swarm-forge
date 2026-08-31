## MODIFIED Requirements

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
- **THEN** 退出 `3`，报文说明 swarm 没在跑
- **AND** MUST NOT 退出 `5`——把「没开机」报成「verb 坏了」，会让人去查隧道与网络，而
  正确动作只是 `start swarm`
- **AND** 把两个检查的顺序换回改动前的版本，本 scenario 失败

### Requirement: 走 tailnet 时不建隧道也不碰 tailscale

带 `--tailnet` 时，本 verb SHALL 从 `--target` 取 tailscale IP、确认 `http://<ip>:<port>/`
应答 200，并报 `TUNNEL=tailnet`。它 MUST NOT 执行任何 `tailscale` 命令——发布端口是操作者
的一次性动作，那份 serve 配置不归本 verb 创建、修复或清理。

不带该 flag 时行为不变：建 SSH local-forward，报 `TUNNEL=created` 或 `reused`。

端口不应答时，报文 SHALL 区分两种原因，MUST NOT 一律归为「没发布」：端口确实没有发布在
tailnet 上，与端口已发布但后面无人监听，需要的人类动作不同。建议一条已经执行过的命令，
不是含糊，是把人引到死路上。

#### Scenario: 端口没发布时干净退出并给出该敲的命令

- **GIVEN** `--tailnet`，且该端口没有在 tailnet 上发布
- **WHEN** 运行 `dashboard`
- **THEN** 退出 `5`，报文含目标 URL 与该执行的 `tailscale serve` 命令原文
- **AND** 没有建 workspace，没有建隧道，也没有执行任何 `tailscale` 命令

#### Scenario: 端口已发布但无人监听时不建议重跑 tailscale serve

- **GIVEN** `--tailnet`，该端口**已经**发布在 tailnet 上，但后面没有进程在监听
- **WHEN** 运行 `dashboard`
- **THEN** 报文 MUST NOT 建议执行 `tailscale serve`——那条命令已经生效，再跑一次什么都不会改变
- **AND** 报文说明的是真实原因：那个端口后面没有东西在服务
