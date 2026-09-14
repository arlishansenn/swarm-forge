## ADDED Requirements

### Requirement: 一条动词走完装 forge、起 forge、建第一个 project

Feature: provision forge

本 verb SHALL 覆盖 upstream README 的第 2–4 步：把一个 forge product
（`project-manager` 或 `lieutenant`）装进空目录、把它起起来、在它里面建第一个 project。
它 MUST NOT 覆盖第 5 步（New Task）——驱动任务是 `run issue` 的地盘。

第 3 步的 `./swarm` 只起 dashboard 与 host lieutenant，不起任何 project agent；project 的
swarm 在第 4 步的 `open-project!` 里才被拉起。本 verb 报成功 SHALL 意味着这两件事都发生了。

#### Scenario: 一次成功的完整 provision

- **GIVEN** 目标主机上有一个空目录
- **WHEN** 带 forge product、project 名与 pack 运行本 verb
- **THEN** 它退出 `0`，报出 forge root、dashboard URL 与 project 名
- **AND** 那个 project 目录存在，并且被记为 open

#### Scenario: 不建 project 时停在第 3 步

- **GIVEN** 调用方没有给 project 名
- **WHEN** 运行本 verb
- **THEN** 它装好并起好 forge 之后就退出 `0`，一个 project 都不建

### Requirement: 安装只从本 fork 取，并且装完自证来源

安装 SHALL 使用本 fork 的 `get-swarm-forge`，其 `default_repo_url` 指向
`arlishansenn/swarm-forge`。装完之后，本 verb SHALL 校验落地的 script snapshot 确实来自本
fork，MUST NOT 因为「我传的参数是对的」就认定来源是对的。

upstream 的 README 与 helper 都指向 `unclebob/swarm-forge`。从那棵树装出来的 forge 没有
D-1（收件箱按 `roles.tsv` 解析）也没有 D-5（handoffd 对账与重试），handoff 链在唤醒键被
TUI 吞掉时**静默**卡死——没有报错，只是不动了。这正是 D-9 与 ADR-0001/0002 要堵的陷阱。

#### Scenario: 装到的是 upstream 的树就失败

- **GIVEN** `SWARMFORGE_REPO_URL` 被指向 upstream，或安装落地的 snapshot 缺少 fork 的 handoff 修复
- **WHEN** 运行本 verb
- **THEN** 它在起 forge 之前就失败并点名来源不对
- **AND** 绝不调用 launcher

#### Scenario: 默认不传任何来源参数时装的就是本 fork

- **GIVEN** 调用方没有设 `SWARMFORGE_REPO_URL`
- **WHEN** 运行本 verb
- **THEN** 落地的 snapshot 通过来源校验

### Requirement: 启动一律委托给 `start swarm`，绝不裸跑 `./swarm`

本 verb MUST NOT 自己拼 `ssh` 加 `nohup ./swarm &`，SHALL 调用 `start swarm` 那条路径，
因此必然带上显式的 terminal backend、detached 启动、readiness 轮询与 project 锁。

从 ssh 会话裸跑 `./swarm` 时，`osascript` 存在这一点就足以让 `detect-terminal-backend`
选中 `terminal-app`，而背后没有真实 window，window watchdog 几秒内就把整个 forge 拆了
（issue #10，手工操作下已复现两次）。upstream 没有这条委托，它假设人就在那台机器前面。

#### Scenario: terminal backend 永远是显式的

- **GIVEN** 目标 forge 装好了，调用方从一个 ssh 会话运行本 verb
- **WHEN** 启动阶段执行
- **THEN** launcher 收到的是一个显式选定的 terminal backend，而不是自动探测的结果

#### Scenario: 启动未就绪就不往下走

- **GIVEN** launcher 被调用但 runtime 文件始终没有确认就绪
- **WHEN** readiness 预算用尽
- **THEN** 本 verb 以失败退出，并且一个 project 都没建

### Requirement: 建 project 走跑着的 dashboard 的本地 HTTP API

建 project SHALL 经由跑着的 `pack_web` 的 `POST /api/projects`，在**目标主机上**访问
`127.0.0.1`。本 verb MUST NOT 把 dashboard 以任何方式暴露到该主机之外，也 MUST NOT 改动
`pack_web` 绑什么。

生产 `pack_web.bb` 的 `-main` 只认 `--serve`；`--test-new-project` 一类 flag 只在测试
harness 里 dispatch，所以 HTTP 是 headless 建 project 的唯一支持路径。`127.0.0.1` 绑定是
有意的，主机内自访不违反它。

#### Scenario: POST 之前先等 dashboard 真的应答

- **GIVEN** `start swarm` 已经报告 swarm 起来了
- **WHEN** 本 verb 准备建 project
- **THEN** 它先等 `.swarmforge/dashboard-url` 出现并且那个端口握手成功，然后才 POST

#### Scenario: dashboard 始终不应答就不 POST

- **GIVEN** dashboard 在握手预算内始终没有应答
- **WHEN** 预算用尽
- **THEN** 本 verb 以失败退出，并点名 forge 已经起着、project 还没建

#### Scenario: 不新增任何对外暴露

- **GIVEN** 一次完整的 provision
- **WHEN** 它跑完
- **THEN** 目标主机上没有被本 verb 新建的端口转发、代理或 `tailscale serve` 配置

### Requirement: 按阶段可续跑，不引入新的退出码

装、起、建三个阶段各自 SHALL 先问「这一步是不是已经做过了」，做过就跳过并打一行
`WARN=`，然后继续往下走。被中断的一次运行，恢复手段 SHALL 是把同一条命令再跑一遍。
本 verb MUST NOT 引入 `operator-verb-contract` 之外的退出码。

#### Scenario: 装好但没起的 forge 上再跑一次

- **GIVEN** 上一次运行装完 forge 就被中断了
- **WHEN** 用同样的参数再跑一次
- **THEN** 它跳过安装并打 `WARN=`，从启动阶段继续，最终退出 `0`

#### Scenario: 已经在跑的 forge 上再跑一次

- **GIVEN** forge 的 swarm 已经在跑
- **WHEN** 用同样的参数再跑一次
- **THEN** 它跳过启动并打 `WARN=`，继续去建 project

#### Scenario: project 名已经被占

- **GIVEN** 那个 forge 里已经有同名 project
- **WHEN** 运行本 verb
- **THEN** 它以 `6` `UNSAFE` 退出，说明该换个名字或从 dashboard 打开它，且没有改动那个 project
