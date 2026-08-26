# CLAUDE.md

本仓库的 agent 指令主体在 `AGENTS.md`（issue tracker 纪律、triage labels、domain docs、
不要用自动化测试钉 prompt 文本）。先读那个。术语表在 `CONTEXT.md`。

## 这是一个跟随 upstream 的 fork

本仓库是 `unclebob/swarm-forge` 的 fork，长期跟随它的 `main`，同时保留自己的一批修复
与功能。**动 `swarmforge/scripts/` 之前，先读 `docs/fork-deltas.md`。**

那份文档逐条记录了本 fork 相对 upstream 的有意差异：是什么、为什么（哪次事故、哪个
issue）、哪条测试钉着它。它同时是 merge upstream 时的检查清单。

### 为什么需要这份清单

git 的冲突检测是行级的。upstream 在**全新代码**里重犯一个本 fork 已经修过的 bug 时，
没有文本重叠，merge 干净通过，测试也可能照绿。issue #45 的 merge 里真实发生过：upstream
新增的 `in-process-dir` 用进程 cwd 解析收件箱，正是本 fork 在 issue #8 修掉的双事实来源
bug（那次让 pi-governance 的 QA 停摆一天多），而 git 一个冲突都没报。

同一次 merge 还产生过一个哑的变体：`handoff_lib.bb` 里出现两个 `state-dir`，Clojure 后
定义胜出所以 runtime 侥幸正确、测试全绿。这种只有走清单才看得见。

### merge upstream 的固定流程

```sh
git fetch upstream
git merge -X theirs upstream/main   # 冲突偏 upstream，保留非冲突区的 fork 改动
bb test
bash swarmforge/scripts/test-sync-worktree-scripts.sh
# 走一遍 docs/fork-deltas.md，补回被覆盖的修复，并把新差异写进表
```

- `-X theirs` 不等于 `git checkout --theirs`。后者取整个文件，会把自动合并成功的 fork
  改动一并丢掉。
- **攒够 3-5 个 upstream commit 就合一次。** issue #45 攒了 19 个，导致选择性
  cherry-pick 完全不可行，被迫全量 merge。

### 改 fork 侧行为时的义务

**每条相对 upstream 的差异都必须有一条会因为 upstream 的版本而失败的测试**，并在
`docs/fork-deltas.md` 里登记。判据很硬：写完测试，把代码换成 upstream 的版本，看它红不红。
不红就是没钉住，等于没写。

差异被 upstream 采纳后，从表里删掉，并在删除的 commit message 里注明是哪个 upstream
commit 收的。

## 一个 operator verb 不只是一个脚本

加或改 `.agents/skills/swarmforge-operator/` 的动词时，交付物是**四件**，缺一不算做完：

1. `scripts/<verb>.sh` —— `STATUS=` 首行，共用那张退出码表。
2. `scripts/test-<verb>.sh` —— 对着 stub 跑，不碰真实网络。
3. `SKILL.md` 的 `## Verb: <verb>` 一节 —— **写给 agent 的**。
4. `README.md` 的 verb 表一行 + 契约一节 —— **写给用户的**。

**判据：下一个 agent 只读 `SKILL.md`，能不能正确地把这个动词跑起来？** 只写到「脚本能干
什么」不够，「怎么调用它」同样要写进去：会阻塞多久、烧不烧 token、哪个 harness 的 shell
tool 会把它掐掉。这类知识往往是在会话里被问出来的，**回答完必须落进文件，不能只留在对话里**。

issue #60 真实漏过：`run-issue.sh` 和 55 个 check 都写完了，但一个会阻塞两小时的动词，
`SKILL.md` 和 `README.md` 都没说该怎么起它（pi 的 `bash` tool 没有默认超时，前台跑；
Claude Code 上限 600 秒，必须 `run_in_background`），是用户追问才补上的。

## 测试

- `bb test` —— 主套件（`test/swarmforge/` 下三个文件）。
- `bash swarmforge/scripts/test-sync-worktree-scripts.sh` —— issue #29 的镜像语义，
  **不在 `bb test` 里**。
- `.agents/skills/swarmforge-operator/scripts/test-*.sh` —— operator skill 的测试，
  也不在 `bb test` 里。**跑它们时把输出重定向到文件，不要用 `$(...)` 捕获**：
  `test-start-swarm.sh` 一类会留下后台进程持有那根管道，命令替换等不到 EOF，会一直挂着，
  看起来像测试卡死，其实早就跑完了。
- **一次 tool call 只跑一个 suite，不要用 `for t in test-*.sh` 循环包起来。** 重定向到
  文件也救不了：issue #60 这次，循环在 `test-accept-work.sh`（本身已通过）之后就再没往下
  走，15 分钟一个后续 suite 都没启动；拆成一次一个立刻全部跑完。没有根因，但拆开跑是可
  复现有效的走法。
