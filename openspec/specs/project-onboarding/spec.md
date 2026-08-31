# project-onboarding Specification

## Purpose
TBD - created by archiving change record-fork-deltas-as-specs. Update Purpose after archive.

## Requirements

### Requirement: launcher 原样安装，绝不解压后改写

Feature: onboard project

`onboard project` SHALL 把 Pack artifact 里的 swarm launcher 原样安装，MUST NOT 在解压后
改写它的任何内容。

早先的做法是解压后改写 `ARCHIVE_URL`。那次改写正是 launcher 可执行位被毁的来源——`mv` 把
mktemp 的 `0600` 搬了过去，而 verb 照常报成功，managed project 上真实中过。**不碰这个文件**
才是保住字节与 mode 的办法，而不是更小心地把它写回去。

#### Scenario: launcher 的字节与 artifact 一致

- **GIVEN** 从 Pack 分支下载的 artifact
- **WHEN** onboard 完成
- **THEN** managed project 里的 launcher 与 artifact 内的那份逐字节相同

#### Scenario: launcher 仍然可执行，且 mode 来自 artifact

- **GIVEN** artifact 里的 launcher 是可执行的
- **WHEN** onboard 完成
- **THEN** 安装后的 launcher 仍然可执行，其 mode 与 artifact 内一致
- **AND** 一份起始就不可执行的 fixture 才能钉住这条——起始就可执行的 fixture 永远抓不到
  被毁掉的可执行位

### Requirement: 从本 fork 的 Pack 分支下载

下载源 SHALL 是本 fork 的 Pack 分支，且脚本里 MUST NOT 残留 upstream 的 URL。理由见
`script-snapshot-provenance`。

#### Scenario: 脚本里没有 upstream URL 残留

- **GIVEN** onboard 脚本
- **WHEN** 检查它的下载源
- **THEN** 指向本 fork，且没有 upstream 的 URL 残留
