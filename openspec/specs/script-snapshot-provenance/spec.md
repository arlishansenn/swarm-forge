# script-snapshot-provenance Specification

## Purpose
managed project 与 forge 拿到的 script snapshot 从哪来，以及首跑 bootstrap 怎么落地才不会
在中途被杀时留下半棵树。默认源必须是本 fork——照 upstream 流程装出来的树缺 D-1 与 D-5，
handoff 链会**静默**卡死，而静默正是这条 capability 存在的理由。

## Requirements

### Requirement: script snapshot 来自本 fork

Feature: script snapshot provenance

managed project 与 forge 拿到的 script snapshot SHALL 来自本 fork。`get-swarm-forge` 安装器
的默认源指向本 fork，并保留 `SWARMFORGE_REPO_URL` 覆盖。

照 upstream 流程装出来的树会静默拿到一份 handoff 会卡死的 snapshot：D-1 与 D-5 的修复都不在
upstream。**静默**是这条 requirement 存在的理由——装的时候什么都不报，卡死发生在之后某一跳。

#### Scenario: 默认安装源是本 fork

- **GIVEN** 不设任何环境变量
- **WHEN** 读取安装器的默认源
- **THEN** 它指向本 fork
- **AND** 文件里不残留 upstream 的默认 URL

#### Scenario: 显式覆盖仍然可用

- **GIVEN** 设置了 `SWARMFORGE_REPO_URL`
- **WHEN** 安装器解析源
- **THEN** 用的是设置的那个值——「有意装别的树」仍然可以，只是不再是默认

### Requirement: forge 安装是原子的，并留下 manifest

forge 的 first-run bootstrap SHALL 先在同级 staging 目录装好再 `rename` 换入，并且 manifest
MUST 写在原子安装之后。upstream 的 bootstrap 是 `rm -rf` 目标再 `cp -R`，不是崩溃安全的。

#### Scenario: 安装中途被杀不影响已有的树

- **GIVEN** 根目录已有一份可用的 script snapshot
- **WHEN** 一次 bootstrap 在中途被杀
- **THEN** 原有的树不受影响，且不留下半装的 snapshot 或 manifest

#### Scenario: 安装不改写 launcher 的字节

- **GIVEN** `get-swarm-forge` 下载的 artifact
- **WHEN** 安装它
- **THEN** launcher 的字节与 mode 与 artifact 内完全一致
- **AND** 解压后改写 `ARCHIVE_URL` 的做法会毁掉可执行位，而安装照常报成功
