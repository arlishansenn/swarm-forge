# Agent 须知

**这是 `arlishansenn/swarm-forge` 的 `two-pack` 分支，upstream 是
`unclebob/swarm-forge`。** 这条分支是**交付物**：`get-swarm-forge two-pack` 只从
这里取 `swarm` 与 `swarmforge/`（conf、roles、pack 专属 constitution articles），
本文件与 `test-swarm-launcher.sh` 都不会被装进用户的项目。

在这条分支上只会做一件事：**跟 `upstream/two-pack` 同步**。下面几节都是围绕那件事的。

## launcher 必须一直指着本 fork

这是这条分支作为 fork 存在的全部理由。`swarm` 里的 `ARCHIVE_URL` 默认值是
`https://github.com/arlishansenn/swarm-forge/archive/refs/heads/main.tar.gz`。
从 upstream 的树装出来的 pack，拿到的 `swarmforge/scripts/` 里没有本 fork 的 handoff
修复，handoff 链会卡死而且**什么都不报**。见
[`docs/fork-deltas.md`](https://github.com/arlishansenn/swarm-forge/blob/main/docs/fork-deltas.md)
的 D-9 与
[`docs/adr/0002-fork-owns-the-complete-pack-artifact.md`](https://github.com/arlishansenn/swarm-forge/blob/main/docs/adr/0002-fork-owns-the-complete-pack-artifact.md)。

launcher 还会先在同级 staging 装好再 rename 换入，`.swarmforge/scripts-manifest`
一定写在原子安装之后。upstream 的版本是 `rm -rf` 目标再 `cp -R`，不是崩溃安全的。
**别把它「简化」回去。**

`scripts_digest` 有意实现了两份：一份在 `swarm` 里（它由 curl 取回，够不到 operator
skill），一份在 skill 里。两边一旦漂移，症状是 bootstrap 之后第一次 `start swarm`
报 `DRIFT`。

## `--yolo` 只加在 codex 行，grok 行一个都不加

`swarmforge/swarmforge.conf` 里只有 agent 是 `codex` 的行带 `--yolo`。grok 没有这个
flag：`swarmforge.bb` 的 `grok-permission-prefix` 已经给每个 grok row 传了
`--permission-mode bypassPermissions`，而 `extra-args-prefix` 把 token 直接拼进 agent
命令行，所以 grok 行上多一个 `--yolo` 就是一个非法参数。

**没有任何测试钉得住这一条**，而且 upstream 已经把解释它的那段注释整块删过一次。
每次同步之后手工核一遍。

至于哪个角色跑哪个 agent，2026-08-31 起跟随 upstream，不再是 fork 差异。

## 怎么验证

`test-swarm-launcher.sh` 是钉子，**它不在 `bb test` 里**，要直接跑：

```sh
bash test-swarm-launcher.sh
```

基线是 **29 PASS / 0 FAIL**。它把 curl 打了桩，不碰网络。

**同步完还要跑一遍 RED 探针**：把 `swarm` 换成 `upstream/two-pack` 的版本再跑，
**必须有 7 个断言变红**。那里跑绿了，就说明 fork 的 launcher 已经被 upstream 的悄悄
换掉了。

## 同步与开 PR

只跟 `upstream/two-pack` 同步。**绝不把 `main` 合进来，也绝不把这条分支合进
`main`。** 三条 pack 各走各的 PR，一条出问题不该挡住另外两条。

开 PR 时：**`gh` 在这个 clone 里默认解析到 `unclebob/swarm-forge`**，所以
`gh pr create` / `gh issue create` 必须带 `--repo arlishansenn/swarm-forge`。这条分支
上已经开过 9 个同步 PR，每一个都踩在这个默认值上；开到别人仓库是公开的，撤不干净。

## 不要用测试去钉 prompt 文本

不要用自动化测试去钉 prompt 的文字，包括 constitution articles、role prompts、
Tool Startup 以及生成出来的指令文件。prompt 的措辞不是可以用 `str/includes?`、
Gherkin 或任何自动检查去钉的生产行为。

## 这里缺的东西是有意缺的

`docs/`、`openspec/`、`.agents/` 在这条分支上不存在，是设计如此。它们是 `main` 的
开发期资产。要用 `swarmforge-operator` skill、要改 OpenSpec、要写 ADR，切回 `main`。
