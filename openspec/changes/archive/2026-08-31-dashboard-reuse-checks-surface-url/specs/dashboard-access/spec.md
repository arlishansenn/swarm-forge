## ADDED Requirements

### Requirement: 复用的 browser surface 必须指向本次要开的 URL

Feature: dashboard

复用已有 workspace 时，本 verb SHALL 确认其 browser surface 当前指向的地址等于本次要开的
URL；不相等时 SHALL 把它导航过去。MUST NOT 因为「有一个 browser surface 存在」就原样留下。

报文里的 `URL=` SHALL 与该 surface 实际指向的地址一致。

`pack_web` 每次启动绑新端口，除非项目用了固定端口，所以重启一次 swarm 之后复用出来的
surface **必然**指向已死的旧端口——陈旧是常态而非例外。而这个 verb 唯一的产出就是让人看见
Dashboard：端口归属检查保证端口后面是本项目的 pack_web，liveness gate 保证这个项目在跑，
但都不保证屏幕上渲染的是那个端口。

#### Scenario: 陈旧的 surface 被导航到本次的 URL

- **GIVEN** 已有一个匹配的 workspace，其 browser surface 指向另一个地址
- **WHEN** 运行 `dashboard`
- **THEN** 该 surface 结束时指向本次要开的 URL
- **AND** 报文里的 `URL=` 与它一致
- **AND** 去掉这次校验，本 scenario 失败

#### Scenario: 已经指向正确地址时不做任何改动

- **GIVEN** 已有 workspace 的 browser surface 已经指向本次要开的 URL
- **WHEN** 运行 `dashboard`
- **THEN** 不产生任何 cmux mutation——不导航、不新建 surface、不新建 workspace
- **AND** 仍然报 `REUSED`
