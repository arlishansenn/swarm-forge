# Agent 须知

**这是 `arlishansenn/swarm-forge` 的 `lieutenant` 产品分支，upstream 是
`unclebob/swarm-forge`。** 跑任何 `gh` 命令、任何 `git merge` 之前先读下面两节。
那两件事都长得像日常操作，一件公开且撤不回，一件完全静默。

## 绝不碰 upstream 的 tracker

工作记在 `arlishansenn/swarm-forge` 的 GitHub Issues 上。**绝不在
`unclebob/swarm-forge` 创建、编辑或评论 issue 与 pull request。**

这个 clone 的 `origin` 是本 fork，但 **`gh` 默认解析到 upstream**，所以裸的
`gh issue create` 会把票开到别人的仓库上。每一条 `gh issue` 与 `gh pr` 都要带
`--repo arlishansenn/swarm-forge`。开出去是公开的，撤不干净。

## 绝不把 `main` 合进这条分支

这里的树是 upstream 的 `lieutenant` 产品分支，**不是**本 fork `main` 的副本，
两者不可互换：

- `handoffd.bb` 在这里 1161 行，在 `main` 上 697 行。多出来的 43 个函数是卡片
  派发、Attention 栏、反向车道——正是这个产品的全部意义。合 `main` 会删掉它们。
- `pack_web.bb` 在这里拆成了 `pack_web_*.bb` 一族；`start-pack-web!` 住在
  `swarmforge_terminal.bb`，不在 `swarmforge.bb`。

只跟 `upstream/lieutenant` 同步，做法与 pack 分支一样。
`get-swarm-forge lieutenant` 下载的是这条分支，**从不下载 `main`**，所以 `main`
上的任何改动都不会自己到达一座装好的 forge。

## fork 差异在这里要逐条重打

本 fork 带的每一条行为修复都得在这条分支上单独打一遍，而且锚点通常跟 `main` 对不上
——`submit-keys`、`pack-web-argv` 这些符号在这里都是零命中。索引、理由与每条差异的
钉子都在 `main` 上：
[`docs/fork-deltas.md`](https://github.com/arlishansenn/swarm-forge/blob/main/docs/fork-deltas.md)。

这条分支已经绊过两次的坑：

- `notify!` 的第三个参数在这里是自定义 `message`，在 `main` 上是 `agent`。两个能力
  都得活下来。
- `retry-delay-ms` 两边都有，含义相反——这里是 outbox 投递的指数退避，`main` 上是
  唤醒阶梯。Clojure 让后定义的**静默**胜出。唤醒阶梯在这里改名叫 `wake-*` 就是因为
  这个，别改回去。

## 在这条分支上怎么验证改动

`bb test` 会在 `coverage-in-process-test` 处 abort（`Cannot find SwarmForge project
root`），`upstream/lieutenant` 原样也一样，所以报不出总数。改成比对前后的失败清单：

```sh
LC_ALL=C LANG=C bb test > /tmp/after.out 2>&1
grep -oE '(FAIL|ERROR) in \([a-z0-9-]+\)' /tmp/after.out | sort -u
grep -cE '^(FAIL|ERROR) in ' /tmp/after.out
```

基线是 **1 个失败测试 / 3 个断言**（`merge-and-process-takes-inbound-task-docs`，
upstream 自己就是红的）。**`LC_ALL=C LANG=C` 必须加**：不加的话 git 输出中文，那个
测试会以另一种方式失败，看起来像是你弄出来的回归。

## 不要用测试去钉 prompt 文本

不要用自动化单元测试或验收测试去钉 prompt 的文字，包括 constitution articles、
role prompts、Tool Startup 以及生成出来的指令文件。prompt 的措辞不是可以用
`str/includes?`、Gherkin 或任何自动检查去钉的生产行为。

## 这里缺的东西是有意缺的

`docs/`、`openspec/`、`.agents/`、`CONTEXT.md`、`contrib/` 在这条分支上不存在，是
设计如此。它们是 `main` 的开发期资产，`get-swarm-forge` 从不安装它们。要用
`swarmforge-operator` skill、要改 OpenSpec、要写 ADR，切回 `main`。
