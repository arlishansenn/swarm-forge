# Git 的 clone / worktree / branch / commit / tree

SwarmForge 让每个 role 待在自己的 worktree 里，`roles.tsv` 又把仓库根那一行叫
`master`。这几个词跟 git 自己的 `main`、`master` 撞名，读运行态时很容易看错。这份
文档把它们的关系摆清楚。

## 一张图

下图是 macmini 上 podsum 的真实布局（2026-08-31 快照，commit 号会变，结构不会）。

```
                    GitHub: arlishansenn/podsum
                         main -> 4ed636a
                              ^
                    push -----+----- fetch
                              |
==============================+=======================================
  macmini                CLONE = 下面这一整块
                         ~/project/podsum/.git
==============================+=======================================

  +-- refs（便利贴，每张 41 字节）-----------------------------+
  |                                                            |
  |   main                -> 723cd6f  (本地落后了)             |
  |   origin/main         -> 4ed636a  (上次 fetch 的缓存)       |
  |   feat/issue-93-...   -> 2e735a1  <--+                     |
  |   swarmforge-cleaner  -> 2e735a1  <--+--+                  |
  |                                      |  |                  |
  +--------------------------------------|--|------------------+
                     | 指向              |  |
                     v                   |  |
  +-- objects（压缩，全 clone 共享）-----|--|------------------+
  |                                      |  |                  |
  |   o------o------o------o 2e735a1     |  |                  |
  |  commit commit commit commit         |  |                  |
  |            \_ parent 链 = 历史       |  |                  |
  |                          |           |  |                  |
  |                     commit 内含:     |  |                  |
  |                       tree   1a1b02a -+ |  |               |
  |                       parent 22e7b08  | |  |               |
  |                       author / 时间   | |  |               |
  |                       message         | |  |               |
  |                                       v |  |               |
  |                     tree 1a1b02a（目录快照，无历史）        |
  |                       +- blob  AGENTS.md 的内容             |
  |                       +- blob  README.md 的内容             |
  |                       +- tree  outputs/ -> 更多 tree/blob   |
  |                                  |    |  |                  |
  +----------------------------------|----|--|------------------+
                                     |    |  |
               checkout：递归解压 ---+    |  |
                                          |  |
  +-- worktree（展开的可编辑文件，各一份）|--|------------------+
  |                                       |  |                  |
  |  (1) ~/project/podsum/          HEAD -+  |                  |
  |        <- roles.tsv 叫它 "master"，coder 在这                |
  |                                          |                  |
  |  (2) ~/project/podsum/.worktrees/cleaner/                    |
  |        HEAD ------------------------------+  cleaner 在这    |
  |                                                              |
  |  (3) /private/tmp/podsum-issue65-test/                       |
  |        HEAD -> 5aa3b73  (detached，绕过 refs 直接指 commit)  |
  |                                                              |
  +--------------------------------------------------------------+
```

竖着看是指向链：`HEAD -> 分支 -> commit -> tree -> blob`。worktree (3) 少一跳，
HEAD 直接咬住 commit。

横着看是共享边界：`refs` 与 `objects` 每个 clone 一份，所有 worktree 共用；展开的
文件每个 worktree 一份。只有最上面那根箭头跨机器，clone 之间不直接说话。

## 五个概念，各是什么

**GitHub repo** — 唯一的共享点。两台机器的交汇只能靠 push 与 fetch。

**Clone** — 一台机器上的一份完整副本，`.git` 里有全部历史。换台机器就是另一个
clone，它俩之间不通信。

**Branch** — 一张便利贴，磁盘上就是 `.git/refs/heads/<name>`，41 字节，内容只有一个
commit 编号。它会移动：在分支上 commit 一次，便利贴就撕下来贴到新 commit 上。

**Commit** — 历史节点。含 `tree`、`parent`（可以多个）、author、时间、message。
`git log`、`git blame`、`git bisect`、merge-base 全都靠 parent 链，所以这一跳不能省。

**Tree** — 一层目录的快照，只列出它含哪些 blob 与 tree。**不含任何历史**。同一个
tree 可以被多个 commit 共用（例如 revert 回旧状态）。

**Worktree** — 一个目录 + 一个 HEAD。从某个 commit 的 tree 递归解压出来的普通文件，
coding agent 改的就是它。

## 三个撞名的词

| 词 | 是什么 |
| --- | --- |
| `main` | 一个 branch 名。每个 clone 一份，GitHub 上那份叫 `origin/main` |
| worktree | 一个目录。一个 clone 可挂多个，各自有 HEAD |
| `master`（SwarmForge） | `roles.tsv` 第 2 列的值，意思是「这个 role 用仓库根目录」 |

`master` 这一列跟 git 的 `master` 分支毫无关系，也跟 HEAD 停在哪条分支无关。哪个
role 是 master 取决于 pack：two-pack 是 `coder`，four-pack 是 `specifier`。

## 常见看反的地方

**`main` 与 `origin/main` 是两张不同的便利贴。** `git fetch` 只动后者，`git pull`
= fetch + 把后者并进前者。「GitHub 上已经 merge 了」和「我本地 main 有了」是两件事。
一个 worktree 的目录内容跟着 HEAD 走，不跟着 `main` 走 —— 这就是刚 merge 完却在本地
看不到新文件的原因。

**两条分支可以指同一个 commit，但两个 worktree 不能 checkout 同一条分支。** 前者
git 完全允许；后者会被直接拒绝，因为便利贴会移动，两个目录同时写会打架。commit 是
不可变的，用 detached HEAD 展开几份都行。SwarmForge 给每个 role 一条独立分支，根本
原因是这条限制，不是为了隔离代码。

**能被 checkout 的是 commit，不是分支。** 分支只是指定 commit 的一种便利方式。
worktree (3) 就是活例子：完整可编辑，但没有任何分支指着它。

**分支指向 commit，不是 tree。** 少这一跳就没有 parent，没有 parent 就没有历史。

**删分支不会删代码。** `git branch -d` 只撕便利贴，commit 还在 objects 里，一段时间
内可以用 `git reflog` 找回来。

## 自己验一遍

```sh
cat .git/refs/heads/main          # 41 字节，只有一个 commit 编号
cat .git/HEAD                     # 一行 ref: refs/heads/<branch>，或一个裸 commit 号
git cat-file -t main              # commit，不是 tree
git cat-file -p main              # 展开 commit：tree / parent / author / message
git cat-file -p main^{tree}       # 展开 tree：只有目录条目
git worktree list                 # 这个 clone 挂了哪些目录，各自停在哪
du -sh .git/refs .git/objects     # 便利贴多小，历史多大
```

## 在 SwarmForge 里怎么落地

`.swarmforge/roles.tsv` 第 2 列给出每个 role 的 worktree 名，第 3 列给出它的绝对
路径。`master` 那一行的路径就是仓库根。verb 脚本一律从这里推导拓扑，不按 role 名字
分支 —— 详见 `.agents/skills/swarmforge-operator/SKILL.md` 的 Runtime inputs 一节。

`stop swarm` 的 dirty 检查会对 `roles.tsv` 里每个 worktree 路径各跑一次
`git status --porcelain`，并做去重，因为 `master` 与 `none` 两种行都解析到仓库根。
理解「多个 worktree 共用一份 refs 与 objects」才能看懂为什么要去重。
