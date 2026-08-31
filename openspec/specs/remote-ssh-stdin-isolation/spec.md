# remote-ssh-stdin-isolation Specification

## Purpose
TBD - created by archiving change record-fork-deltas-as-specs. Update Purpose after archive.

## Requirements

### Requirement: 所有 remote ssh 调用带 -n

Feature: remote ssh stdin isolation

operator skill 里每一处非交互 ssh 调用 SHALL 带 `-n`。

ssh 非交互运行且不带 `-n` 时，仍会抽干并转发自己 stdin 上的东西，哪怕远端命令根本不读。
`while read ... done <<< "$VAR"` 循环里的第一个 ssh 调用会把 here-string 喝光，**循环被
截断成只跑一轮**——后面的 role 或 worktree 被静默跳过，而那正是安全闸要检查的对象。

#### Scenario: 循环里的 ssh 不吞掉调用方的 stdin

- **GIVEN** 一个按行遍历 role 的循环，行数据来自 here-string
- **AND** 循环体内对每个 role 发起一次 ssh 调用
- **WHEN** 该循环执行
- **THEN** 每一行都被处理，一行不漏
- **AND** 去掉 `-n`，循环只跑一轮，本 scenario 失败

#### Scenario: 测试用的 ssh stub 必须真的抽干 stdin

- **GIVEN** 验证上述行为的测试
- **WHEN** 它替换 ssh
- **THEN** 该 stub 在没有 `-n` 时真的读空自己的 stdin
- **AND** 只记录 argv 的 naive stub 抓不到这个 bug，因而不满足本 scenario
