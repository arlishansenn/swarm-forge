## ADDED Requirements

### Requirement: pack_web 可绑固定端口

Feature: dashboard port binding

`start-pack-web!` SHALL 读取 `SWARMFORGE_DASHBOARD_PORT`，非空时把它作为端口参数传给
pack_web；变量不设时 MUST NOT 多传任何参数。

固定端口是 tailnet 上可发布地址的前提：随机端口没有稳定 URL 可发布。而「不设变量时一个
参数都不多传」是这条差异能做得很小、merge 冲突面很窄的原因。

#### Scenario: 不设变量时行为与 upstream 一致

- **GIVEN** 不设 `SWARMFORGE_DASHBOARD_PORT`
- **WHEN** 构造 pack_web 的启动 argv
- **THEN** argv 只有 script、`--serve`、working dir 三项，没有端口参数
- **AND** pack_web 因而继续由内核随机分配端口

#### Scenario: 设了变量就绑那个端口

- **GIVEN** `SWARMFORGE_DASHBOARD_PORT` 设为某个端口号
- **WHEN** 构造 pack_web 的启动 argv
- **THEN** 该端口号作为第四项出现在 argv 里

#### Scenario: dashboard-url 反映实际绑定的端口

- **GIVEN** pack_web 以固定端口启动
- **WHEN** 它写 `.swarmforge/dashboard-url`
- **THEN** 文件内容正好是 `http://127.0.0.1:<该端口>`
- **AND** 该 URL 因此在重启之间保持不变
