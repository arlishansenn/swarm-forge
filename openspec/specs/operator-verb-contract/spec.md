# operator-verb-contract Specification

## Purpose
TBD - created by archiving change record-fork-deltas-as-specs. Update Purpose after archive.

## Requirements

### Requirement: 每个 scripted verb 报告自己的结果

Feature: operator verb contract

每个 scripted operator verb SHALL 把 `STATUS=<WORD>` 作为 stdout 第一行，并按下表退出。
退出码在所有 verb 之间只有一种含义。

| 码 | 含义 |
|---|---|
| `0` | verb 做完了它的事 |
| `2` `USAGE` | 参数不对，什么都没做 |
| `3` | 目标没在运行。绝不代为启动，那是人的决定 |
| `4` `DRIFT` | 记录的状态与真实状态不一致。修之前先问人 |
| `5` `ERROR` | verb 自己失败了 |
| `6` `UNSAFE` | 拒绝执行破坏性操作，因为发现了必须由人先清掉的条件。什么都没改 |
| `7` `STILL_RUNNING` | 撞到的是**调用方**设的 deadline，不是失败。原样重跑即续 |
| `8` `OWNED` | managed project 自己版本控制了 verb 要写的路径，谁赢由人决定。什么都没改 |

upstream 没有 operator verb，也没有这张表：它的动作是人手敲的 ssh 命令，没有可供脚本
分支的结果。

#### Scenario: 失败的 verb 说明该做什么

- **GIVEN** 任意一个 scripted verb 以非零码退出
- **WHEN** 读它的 stdout
- **THEN** 第一行是 `STATUS=<WORD>`，其后是一句给人看的话，说明下一步做什么
- **AND** 没有 machine-readable 的 reason 字段——脚本分支看退出码，句子给人看

### Requirement: 成功也可以报告必须知道的事

verb 做完了事、但发现了操作者必须知道的情况时，SHALL 打印一行或多行
`WARN=<一句话>` 并仍然以 `0` 退出。WARN MUST 只报告「本次为真、以后可能变假」的事实。

永远为真的事实 MUST NOT 用 WARN 报告，要在它的成因处修掉：每次都出现的警告没人读。

#### Scenario: 每次都出现的警告不是警告

- **GIVEN** 某个条件在每一次运行时都成立
- **WHEN** 决定要不要为它打 WARN
- **THEN** 不打，改为在成因处修掉
