## ADDED Requirements

### Requirement: task body 跟随目标项目是否使用 OpenSpec

Feature: run issue

投给 swarm 的 task body SHALL 从目标项目的运行态推导它该不该讲 OpenSpec，
MUST NOT 无条件地讲，也 MUST NOT 无条件地不讲。

判据是 `$ROOT/openspec/config.yaml` 是否存在。存在时，task body SHALL 报出该文件
`schema:` 键声明的 schema 名；不存在时，task body SHALL 与不含本 requirement 时逐字节
相同。

本 verb 服务任意 managed project，其中不少不用 OpenSpec：对它们，「走 OpenSpec 周期」
是一条错误指令。这与 `CHAIN` 从 `roles.tsv` 推导而不是写死 role 名字是同一个套路。

#### Scenario: 目标项目声明了 schema

- **GIVEN** 目标项目有 `openspec/config.yaml`，其 `schema:` 键的值是某个名字
- **WHEN** 本 verb 投递 task
- **THEN** payload 里出现那个名字
- **AND** 该名字是从文件读出来的，不是脚本里的常量——换一个项目、换一个名字，payload
  里出现的就是新的那个

#### Scenario: 目标项目不使用 OpenSpec

- **GIVEN** 目标项目没有 `openspec/config.yaml`
- **WHEN** 本 verb 投递 task
- **THEN** payload 与本 requirement 存在之前逐字节相同
- **AND** 任何 schema 名都不出现在里面

### Requirement: artifact 顺序不由本 verb 保存

task body MUST NOT 写出 artifact 的名称或顺序。它 SHALL 只报出 schema 名，并指向
`openspec/schemas/<name>/schema.yaml`。

artifact 顺序是 schema 的属性。在本 verb 里存一份就是 OpenSpec 知识的第二个来源，
schema 一改就漂，而漂了不会有任何东西报错。

#### Scenario: 脚本里搜不到 artifact 顺序

- **GIVEN** 本 verb 的脚本
- **WHEN** 在非注释行里搜 artifact 名与它们的顺序
- **THEN** 搜不到
- **AND** 也搜不到任何硬编码的 schema 名
