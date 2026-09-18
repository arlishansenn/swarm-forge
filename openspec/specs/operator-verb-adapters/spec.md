# operator-verb-adapters Specification

## Purpose

为本 fork 的六个 Operator verb 提供可替换的执行 seam，以固定 fake 与既有脚本 real adapter 的共同 contract 验证替换；操作与测试不依赖设计留档。

## Requirements

### Requirement: 每个 verb 的执行入口可以选择 adapter

六个 Operator verb SHALL 各有一个 wrapper 作为执行入口，通过 `SF_ADAPTER=fake|real` 选择对应 adapter。wrapper MUST 保持参数的值、顺序与参数边界，real 路径 MUST 保持 adapter 的 stdout、stderr 与退出码，不得在 real 失败时改调 fake。upstream 不含这些入口；换成 upstream 的目录运行下述调用，应因缺少入口而失败。

#### Scenario: 参数原样到达 real adapter

```gherkin
Given real adapter 已在隔离 fixture 中就绪
When 通过对应 verb 入口传入含空格的 root 与多个参数
Then real adapter 收到原参数顺序与参数边界
And 调用者收到 adapter 的 stdout、stderr 与退出码
```

#### Scenario: 未知 adapter 不执行任何操作

```gherkin
Given SF_ADAPTER 的值为 unknown
When 调用任一 verb 入口
Then 返回 STATUS=USAGE 且退出码为 2
And fake 与 real 都没有被调用
```

#### Scenario: real 缺失不能由 fake 掩盖

```gherkin
Given SF_ADAPTER 的值为 real
And 对应 real adapter 不存在或不可执行
When 调用该 verb 入口
Then 返回 STATUS=ERROR 且退出码为 5
And fake 没有被调用
```

### Requirement: Seam — .agents/skills/swarmforge-operator/scripts/verb-provision-forge::main

provision forge SHALL 在 `scripts/provision-forge.sh` 与 `scripts/fakes/provision-forge.sh` 两个 adapter 间替换，同一组成功 contract assertions MUST 保持不变。以下 adapter 路径均相对 skill 根目录。

#### Scenario: 两个 adapter 满足同一 provision 成功 contract

```gherkin
Given scripts/fakes/provision-forge.sh 返回固定的无 project 成功样本
And scripts/provision-forge.sh 在隔离的 Forge fixture 中运行无 project 成功路径
When 分别以 SF_ADAPTER=fake 和 SF_ADAPTER=real 调用 verb-provision-forge
Then 两次都返回 STATUS=PROVISIONED 且退出码为 0
And 两次结果的 ROOT、FORGE、URL、TARGET 字段均非空
And 两次由同一组 contract assertions 判定
```

### Requirement: Seam — .agents/skills/swarmforge-operator/scripts/verb-dashboard::main

dashboard SHALL 在 `scripts/open-dashboard.sh` 与 `scripts/fakes/dashboard.sh` 两个 adapter 间替换，同一组成功 contract assertions MUST 保持不变。

#### Scenario: 两个 adapter 满足同一 Dashboard 接入成功 contract

```gherkin
Given scripts/fakes/dashboard.sh 返回固定成功样本
And scripts/open-dashboard.sh 的端口、runtime 与 cmux 依赖由隔离 fixture 提供
When 分别以 SF_ADAPTER=fake 和 SF_ADAPTER=real 调用 verb-dashboard
Then 两次都返回 STATUS=OPENED 且退出码为 0
And 两次结果的 TUNNEL、URL、WORKSPACE、SURFACE、ROOT、TARGET 字段均非空
And 两次由同一组 contract assertions 判定
```

### Requirement: Seam — .agents/skills/swarmforge-operator/scripts/verb-ship-project::main

ship project SHALL 在 `scripts/ship-project.sh` 与 `scripts/fakes/ship-project.sh` 两个 adapter 间替换，同一组成功 contract assertions MUST 保持不变。

#### Scenario: 两个 adapter 满足同一 PR 结果 contract

```gherkin
Given scripts/fakes/ship-project.sh 返回固定的 PR 成功样本
And scripts/ship-project.sh 使用临时 git remote、已完成交付记录、非空正文与 gh stub
When 分别以 SF_ADAPTER=fake 和 SF_ADAPTER=real 调用 verb-ship-project
Then 两次都返回 STATUS=PR_OPENED 且退出码为 0
And 两次结果的 url 字段均非空
And 两次由同一组 contract assertions 判定
```

### Requirement: Seam — .agents/skills/swarmforge-operator/scripts/verb-wake-role::main

wake role SHALL 在 `scripts/wake-role.sh` 与 `scripts/fakes/wake-role.sh` 两个 adapter 间替换，同一组成功 contract assertions MUST 保持不变。

#### Scenario: 两个 adapter 满足同一唤醒成功 contract

```gherkin
Given scripts/fakes/wake-role.sh 返回固定成功样本
And scripts/wake-role.sh 使用隔离 runtime 与模拟输入消费的 tmux fixture
When 分别以 SF_ADAPTER=fake 和 SF_ADAPTER=real 调用 verb-wake-role
Then 两次都返回 STATUS=WOKEN 且退出码为 0
And 两次结果的 ROLE、SESSION 字段均非空
And 两次由同一组 contract assertions 判定
```

### Requirement: Seam — .agents/skills/swarmforge-operator/scripts/verb-talk-role::main

talk role SHALL 在 `scripts/talk-role.sh` 与 `scripts/fakes/talk-role.sh` 两个 adapter 间替换，同一组成功 contract assertions MUST 保持不变。

#### Scenario: 两个 adapter 满足同一消息送达成功 contract

```gherkin
Given scripts/fakes/talk-role.sh 返回固定成功样本
And scripts/talk-role.sh 使用隔离 runtime 与模拟输入消费的 tmux fixture
When 分别以 SF_ADAPTER=fake 和 SF_ADAPTER=real 调用 verb-talk-role
Then 两次都返回 STATUS=SENT 且退出码为 0
And 两次结果的 ROLE、SESSION 字段均非空
And 两次由同一组 contract assertions 判定
```

### Requirement: Seam — .agents/skills/swarmforge-operator/scripts/verb-open-swarm::main

open swarm SHALL 在 `scripts/open-swarm.sh` 与 `scripts/fakes/open-swarm.sh` 两个 adapter 间替换，同一组成功 contract assertions MUST 保持不变。

#### Scenario: 两个 adapter 满足同一附着成功 contract

```gherkin
Given scripts/fakes/open-swarm.sh 返回固定成功样本
And scripts/open-swarm.sh 使用隔离 runtime 与 cmux、tmux fixture
When 分别以 SF_ADAPTER=fake 和 SF_ADAPTER=real 调用 verb-open-swarm
Then 两次都返回 STATUS=OPENED 且退出码为 0
And 两次结果的 ROOT、TARGET、WINDOW、WORKSPACES 字段均非空
And 两次结果中 ATTACHED 大于 0 且 FAILED 等于 0
And 两次由同一组 contract assertions 判定
```

### Requirement: fake 只提供无外部作用的固定样本

每个 fake adapter MUST 只返回预定成功报文与退出码，MUST NOT 读取目标 runtime、项目文件或凭据，MUST NOT 启动网络访问、角色输入、安装或发布。fake SHALL 在 stderr 标明 `ADAPTER=fake`；其通过不得被报告为 real adapter 验证通过。

#### Scenario: 不存在的目标也能运行固定替身

```gherkin
Given 目标 root 不存在且外部命令被设置为调用即失败
When 显式选择 fake 运行任一 verb
Then 返回该 verb 的预定成功报文与退出码
And stderr 标明 ADAPTER=fake
And 目标 root 没有被创建且外部命令没有被调用
```

### Requirement: 逐 verb 接入保留真实操作入口

六个 wrapper SHALL 先以 fake 建立骨架，再按 provision forge、dashboard、ship project、wake role、talk role、open swarm 的顺序完成 real 接入。每个 verb MUST 在 real 验证通过后才切换默认 adapter 与 SKILL.md 的操作入口。未完成的 verb MUST 保持原有真实入口，不能用 fake 成功冒充操作完成。fake 与 seam 在迁移完成后 SHALL 保留。

#### Scenario: real 尚未通过时保留旧入口

```gherkin
Given 某个 verb 的 fake 测试通过但 real 测试未通过
When 汇报该 verb 的移植进度
Then real 状态仍为未完成
And SKILL.md 的真实操作仍使用该 verb 的原入口
```

#### Scenario: 默认选择确实接到 real

```gherkin
Given 某个 verb 的 fake 与 real contract 测试均通过
When 将其默认 adapter 改为 real 并在隔离 fixture 中不指定 SF_ADAPTER 调用
Then fixture 记录到现有 real 脚本的操作
And 结果中没有 fake 标识
```

### Requirement: skill 可脱离留档执行

SKILL.md、wrapper、adapter 与 contract 测试 MUST NOT 把 issue、spec 或 ADR 作为执行输入。SKILL.md SHALL 自足说明六个 verb 的用途、输入、调用与结果处理；注释中的留档引用不属于执行依赖。不得用文档措辞自动化检查代替 seam 行为测试。

#### Scenario: 没有 openspec 的环境仍可运行

```gherkin
Given 临时目录只包含 skill 执行文件、contract 测试与所需 fixture
And 该目录没有 openspec 或 docs/adr
When 运行六个 verb 的 fake 测试及已移植 verb 的 real fixture 测试
Then 已接入的路径仍通过原 contract assertions
```
