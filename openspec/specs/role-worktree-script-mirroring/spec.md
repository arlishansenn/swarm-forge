# role-worktree-script-mirroring Specification

## Purpose
TBD - created by archiving change record-fork-deltas-as-specs. Update Purpose after archive.

## Requirements

### Requirement: script snapshot 到 role worktree copy 是完整镜像

Feature: role worktree script mirroring

`sync-worktree-scripts!` SHALL 先删除目标目录再整树复制，MUST NOT 做覆盖式合并。

覆盖式复制会把 role worktree copy 里的过期脚本留下，下次启动跑的是旧代码。

#### Scenario: 目标里的过期文件不会存活

- **GIVEN** 某个 role worktree copy 里有一个 source 已经删掉的脚本
- **WHEN** 执行一次 mirror
- **THEN** 该脚本在 role worktree copy 里消失
- **AND** 换成覆盖式合并，本 scenario 失败

### Requirement: 镜像一致性检查包含可执行位

`scripts-mirror-matches?` SHALL 在 `diff -rq` 之外单独比对可执行位集合。

`diff -rq` 只比内容：一个丢了 `+x` 位的文件能过 diff，然后在启动时 exec 失败。

#### Scenario: 内容相同但可执行位丢失时判为不一致

- **GIVEN** role worktree copy 与 script snapshot 内容逐字节相同
- **AND** 其中一个文件在 copy 侧丢了可执行位
- **WHEN** 执行一致性检查
- **THEN** 结果是 MISMATCH
- **AND** 只比内容的实现会判为 MATCH，本 scenario 失败
