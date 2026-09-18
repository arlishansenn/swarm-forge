# Operator runbook

本 fork 的本地 operator 入口是
[swarmforge-operator SKILL.md](../.agents/skills/swarmforge-operator/SKILL.md)。
它统一维护六个 verb 的用途、参数、seam 调用、结果与失败处理；本页只做导航，不另存契约表。
执行操作不要求先阅读 issue、spec 或 ADR。

## 操作前定位

1. 在本仓库的本地 agent 会话中加载 skill。先区分 Forge 根目录与它下面的 Managed project：
   新安装使用 Forge 根，操作角色或发布使用 `<forge-root>/projects/<name>`。
2. 依据目标的 runtime 选择角色、session 和 backend，不按 Pack 名或固定角色列表猜测。
   具体所需文件与停机处理按对应 verb 小节执行。
3. 直接操作 cmux 前加载 `cmux` skill。新建 window、破坏性清理、停机或重启都保留人的授权边界。

## 查找操作

安装 Forge、打开 Dashboard、附着终端、唤醒或发消息、发布 PR，均从 skill 中的同名 verb 进入。
调用使用 `scripts/verb-*` seam；`SF_ADAPTER=real` 执行实际操作，fake 只用于测试。

Project 的 open/close、Forge teardown、角色状态、Board 派活与审批在 Dashboard 处理。
单角色 `attach role` 保留 skill 中的直接终端交接，不属于六个 adapter 移植入口。

Dashboard 的端口分配、tailnet 发布授权和 runtime 归属限制也只维护在 skill 中。
尤其要先确认对应小节的适用范围，不能把 Forge 共享 Dashboard 当成 project 自有的 pack_web。

## 修改后的验证

测试入口与验证边界见 skill 的 Testing 小节。fake/real contract 在隔离 fixture 中运行；
它们不会连接真实角色 pane，也不代表生产 Forge 的端到端验收。
