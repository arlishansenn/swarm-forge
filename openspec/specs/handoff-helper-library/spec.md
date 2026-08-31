# handoff-helper-library Specification

## Purpose
TBD - created by archiving change record-fork-deltas-as-specs. Update Purpose after archive.

## Requirements

### Requirement: handoff helper 只有一份

Feature: handoff helper library

`ready_for_next.bb`、`done_with_current.bb` 等 leaf 脚本 SHALL 通过
`(:require [handoff-lib :as hl])` 取用 `command` / `git-root` / `project-root` / `role` /
`receive-mode`，MUST NOT 各自存一份拷贝。

五份拷贝漂移过一次，那次正是 D-1 事故的放大器。`handoff_lib.bb` 尾部有 `*file*` 守卫，
否则 require 即执行 CLI 并退出；所有 `.sh` wrapper 带 `--classpath "$SCRIPT_DIR"`。

#### Scenario: leaf 脚本从 library 取 helper

- **GIVEN** 一个 leaf handoff 脚本
- **WHEN** 它需要解析 role 或 project root
- **THEN** 它调用 `handoff_lib.bb` 里的那一份实现
- **AND** 把 helper 拷回脚本本地，测试红

#### Scenario: require handoff_lib 不会执行它的 CLI

- **GIVEN** 另一个脚本 require `handoff-lib`
- **WHEN** 该脚本被加载
- **THEN** `handoff_lib.bb` 的 CLI 入口不执行，进程不退出

#### Scenario: 同一个 helper 在文件里只定义一次

- **GIVEN** `handoff_lib.bb`
- **WHEN** 检查 `state-dir` 一类 helper 的定义次数
- **THEN** 每个 helper 恰好定义一次
- **AND** 这条专治一种哑失败：merge 之后 upstream 版与 fork 版**并存**，Clojure 后定义胜出
  所以 runtime 侥幸正确、测试全绿，只有数定义次数才看得见
