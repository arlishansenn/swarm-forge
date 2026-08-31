## ADDED Requirements

### Requirement: 端口后面必须是本项目自己的 pack_web

Feature: dashboard

HTTP 200 只证明**有东西**在应答那个端口，不证明它是本项目的 Dashboard。开任何 workspace
之前，本 verb SHALL 读 `$ROOT/.swarmforge/pack_web.pid` 并确认该进程的 `--serve` 参数等于
`$ROOT`；这项检查 MUST 直接打到 target 或本机，MUST NOT 经隧道——隧道只转发 HTTP，不携带
远端主机的进程身份。

#### Scenario: 端口被同机别的项目占用时拒绝

- **GIVEN** 端口应答 200，但持有它的 pack_web 的 `--serve` 指向另一个 root
- **WHEN** 运行 `dashboard`
- **THEN** 退出 `4` `DRIFT`，报文点名实际的那个 root，且一次 cmux 调用都没发生

#### Scenario: pid 文件缺失或进程已死是 STOPPED 而不是 DRIFT

- **GIVEN** `pack_web.pid` 不存在，或它记的进程已经不在
- **WHEN** 运行 `dashboard`
- **THEN** 退出 `3`，且 MUST NOT 代为启动 pack_web

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
