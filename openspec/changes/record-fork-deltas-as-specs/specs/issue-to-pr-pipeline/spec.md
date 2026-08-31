## ADDED Requirements

### Requirement: 同一张 issue 绝不投第二次

Feature: run issue

Dashboard 的建卡接口只校验名字非空，投两次同名就真的会产生两张 Board 卡、两条 handoff
链。因此本 verb SHALL 在创建任何东西之前判定当前状态，并在任何情况下 MUST NOT 重复投递。

判定由两个各自独立的标记推导——分支在不在、Board 卡在不在——四种组合都要有出口：

| 分支 | 卡 | 行为 |
|---|---|---|
| 无 | 无 | 首次运行 |
| **有** | **无** | 续跑：跳过建分支，补投那次没投成的 task |
| 有 | 有 | 续跑：跳过建分支与投递，直接接着轮询 |
| 无 | 有 | `6` `UNSAFE`：那不是本 verb 的卡，什么都不碰 |

第二格是建分支与投递之间那个窗口。按「先看哪个标记」推导时它没有出口：没卡就走首次运行，
`git checkout -b` 撞上已存在的分支，`5` `ERROR`，且每次重跑都一样。

#### Scenario: 分支在而卡不在时补投

- **GIVEN** 目标分支已存在，Board 上没有对应的卡
- **WHEN** 运行 `run issue`
- **THEN** 它不建第二条分支，补投那张 task，然后与其他路径共用同一段后续代码
- **AND** 按「卡是否存在」单一入口推导的实现在这里失败

### Requirement: 只有 Board 的 lane 判定任务完成

Feature: run issue

本 verb SHALL 只以 Board 的 lane 判定任务是否完成，MUST NOT 读 role 的 in-flight 状态。

链路是多跳的，role 在两跳之间会短暂 idle：按 role 状态判定会把做了一半的任务当成做完。

#### Scenario: 链路换手时的 idle 不算完成

- **GIVEN** 任务仍在链路中，某个 role 此刻 idle
- **WHEN** 本 verb 轮询
- **THEN** 它继续等待，直到 lane 变成 done

### Requirement: 等不到不是失败

超时 SHALL MUST NOT 重投 task。调用方可以用 `--max-wait` 声明自己能等多久：正数是整条
命令的 wall-clock 预算，`0` 只查一次就返回，负数沿用 verb 自己的上限。撞到调用方的
deadline SHALL 退出 `7` `STILL_RUNNING`，不复用 `5`。

调用方必须能区分「还在跑，原样重跑即续」与「出事了」，两者要的人类动作不同。

#### Scenario: 撞到 deadline 时干净退出

- **GIVEN** `--max-wait` 到点而任务仍在进行
- **WHEN** 本 verb 结束
- **THEN** 退出 `7`，报文含它停在哪个 lane
- **AND** 没有 push、没有开 PR、没有重投 task

### Requirement: 有人在等回答时立刻停

`/api/state` 里出现 pending clarification 或 approval 时，本 verb SHALL 退出 `6` `UNSAFE`
并报出它们的 id 与原文。这项检查 MUST 在创建任何东西之前做一次，之后每一轮轮询再做一次。

被挡住的 agent 不会失败，它写一条 clarification 然后等——它的任务永远到不了 done。这是
连投链路里唯一会自动停下来的人闸；没有它，循环会继续往下投，把下一条分支叠在没人看过的
工作上面。

#### Scenario: 轮询中途出现 clarification 就停

- **GIVEN** 轮询已经开始
- **WHEN** 出现一条 pending clarification
- **THEN** 本 verb 立刻退出 `6`，报出它的 id 与问题原文，且没有开 PR
