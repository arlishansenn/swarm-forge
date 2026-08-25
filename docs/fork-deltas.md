# Fork deltas —— 本 fork 相对 upstream 的有意差异

本 fork 长期跟随 `unclebob/swarm-forge` 的 `main`。每次 merge upstream 之后，走一遍
这张表：确认每条差异还在，且钉住它的测试还绿。

**这张表存在的理由：** git 的冲突检测是行级的。upstream 在**全新代码**里重犯一个本
fork 已经修过的 bug 时，没有文本重叠，merge 干净通过，测试也可能照绿——除非有一条
专门为此写的测试。issue #45 的 merge 里真实发生过一次（见下面 D-1）。

## 怎么用

```sh
git fetch upstream
git merge -X theirs upstream/main   # 冲突偏 upstream，保留非冲突区的 fork 改动
bb test                             # 红的地方就是被覆盖的 fork 修复
bash swarmforge/scripts/test-sync-worktree-scripts.sh   # 不在 bb test 里，单独跑
# 然后走一遍本表，逐条确认，并把新出现的差异补进来
```

A 类差异的钉子在 `.agents/skills/swarmforge-operator/scripts/test-*.sh`，也不在
`bb test` 里。**跑它们时把输出重定向到文件，不要用 `$(...)` 捕获**：
`test-start-swarm.sh` 一类会留下后台进程持有那根管道，命令替换等不到 EOF，会一直挂着，
看起来像测试卡死，其实测试早就跑完了。

```sh
cd .agents/skills/swarmforge-operator/scripts
for t in test-*.sh; do zsh "$t" > "/tmp/$t.out" 2>&1 && echo "PASS $t" || echo "FAIL $t"; done
```

`-X theirs` 与 `git checkout --theirs` 不是一回事。后者取整个文件，会把自动合并成功
的 fork 改动一并丢掉；前者只在冲突块上偏向 upstream。issue #45 能只补 7 处而不是重做
一遍，靠的就是这个区别。

**攒够 3-5 个 upstream commit 就合一次，别攒。** issue #45 攒了 19 个，
`swarm_handoff.bb` 的 hunk 因为跨了另外 17 个 commit 引入的 helper 层而完全落不下去，
被迫改成全量 merge。

## 两类差异，merge 成本差一个数量级

**A 类 —— 落在 upstream 没有的文件里。merge 成本为零。**
`.agents/`、`docs/`、`contrib/` 下的东西 upstream 根本没有，merge 不会碰。issue #45
的 merge 触碰这三个目录 **0 个文件**。

**B 类 —— 落在 upstream 也在改的文件里。每次 merge 都要重打一遍。**
`swarmforge/scripts/` 下的三个文件是重灾区：`handoffd.bb`、`swarm_handoff.bb`、
`pack_web.bb`。

**由此得出一条实操原则：能推进 fork-only 文件的差异就推进去。** 不是所有都能——
`notify!` 少一个参数这种一行改动搬不走。但凡是一段可以独立存在的逻辑，放进自己的文件
比 patch upstream 的文件便宜得多。

---

## B 类：每次 merge 都要检查的差异

### D-1 收件箱路径按 `roles.tsv` 的 worktree 解析，不按进程 cwd

**差异：** `handoff_lib.bb` 的 `state-dir` 与 `swarm_handoff.bb` 的 `in-process-dir`
都从 `roles.tsv` 的 worktree 列派生。upstream 两处都用 `System/getProperty "user.dir"`。

**为什么：** handoffd 按 `roles.tsv` 的 worktree 列投递。agent 侧若按进程 cwd 找收件
箱，两个事实来源一旦不一致，**daemon 往 A 投、agent 在 B 找，双方都不报错**，链条无声
停住。pi-governance 的 QA 角色为此停了一天多：收到 6 次唤醒、跑了 6 次
`ready_for_next.sh`、6 次 NO_TASK，而文件一直躺在它自己的 worktree inbox 里。
来源 issue #8 / commit `3b6c315`。

**钉子：**
- `ready-for-next-finds-the-role-inbox-from-any-directory`（`handoff_test.clj`）
- `swarm-handoff-reads-the-non-forwarding-gate-from-the-role-worktree`（`handoff_test.clj`）

**历史：** issue #45 的 merge 里，upstream 新增的 `in-process-dir` 用了 `user.dir`。
**git 没有报任何冲突**，那是它全新加的函数，fork 里没有对应物。第二条钉子就是那次补的
——upstream 自带的闸门测试 cwd 恰好等于 sender worktree，对这条修复不敏感，两种实现
都能过。

### D-2 tmux 提交键用裸回车 / CSI-u，不用符号键名

**差异：** `handoffd.bb` 与 `pack_web.bb` 的 `submit-keys`：claude backend 用
CSI-u Enter（`-H 1b 5b 31 33 75`），其余用裸回车（`-H 0d`）。upstream 用 `C-m` 与 `C-j`。

**为什么：** 符号键名会被 tmux 为「协商了 extended keys 的 TUI」重新编码，然后**永远
不提交**。文本贴进去了，回车没生效，agent 看起来在 idle 实际在等一个永不到达的提交。
来源 commit `7903d03` / `34c13bc` / `005e030`。

**钉子：**
- `handoffd-submits-a-claude-wake-with-csi-u-enter`（`handoff_test.clj`）
- `handoffd-submits-a-codex-wake-with-a-raw-carriage-return`（`handoff_test.clj`）
- `pack-web-post-chat-injects-text-as-is`（`pack_ui_test.clj`）
- `inject-master-records-send-keys-argv`（`pack_ui_test.clj`）
- `attention-reject-injects-a-message-to-master`（`pack_ui_test.clj`）

**历史：** issue #45 的 merge 把 `pack_web.bb` 的 `inject-target!` 换回了 `C-m`/`C-j`。
处理方式是**保留 upstream 新增的 `inject-role!` 结构**（那是真新功能：per-role 注入），
只把里面的提交键换回 fork 的 `submit-keys`。

### D-3 `notify!` 按 backend 分发提交键，调用点必须传 agent

**差异：** `handoffd.bb` 的 `notify!` arity 是 `[socket session agent]` /
`[socket session agent await?]`。upstream 是 `[socket session]`。

**为什么：** D-2 的直接后果——提交键要按 backend 选，`notify!` 就必须知道 backend。

**钉子：** 同 D-2 的两条 handoffd wake 测试；此外 upstream 自己的
`four-pack-end-broadcast-marks-the-card-done` 与
`six-pack-qa-broadcast-marks-the-card-done` 也会因为 arity 不符而失败。

**历史：** issue #45 的 merge 取 upstream 侧后变成两参调用，**整个 `deliver!` 抛异常**，
投递路径完全断掉。这条是那次 merge 里唯一一处「upstream 自己的新测试也跟着红」的地方，
所以反而最容易发现。

### D-4 handoff helper 集中在 `handoff_lib.bb`，不在每个脚本各存一份

**差异：** `ready_for_next.bb`、`done_with_current.bb` 等 leaf 脚本
`(:require [handoff-lib :as hl])`，不自带 `command`/`git-root`/`project-root`/`role`/
`receive-mode` 的拷贝。upstream 每个脚本各存一份。

**为什么：** 五份拷贝漂移过一次（D-1 那次事故的放大器）。`handoff_lib.bb` 尾部有
`*file*` 守卫（否则 require 即执行 CLI 并退出），所有 `.sh` wrapper 带
`--classpath "$SCRIPT_DIR"`。来源 commit `3b6c315`。

**钉子：** `ready-for-next-prints-note-task-name-and-body`、
`done-with-current-archives-the-completing-role-pane`、
`receive-and-complete-infer-role-from-worktree` 等（`handoff_test.clj`）。

**历史：** issue #45 的 merge 把 upstream 的拷贝原样插了回来，但 ns 是 fork 的、没有
`clojure.java.shell :as sh` 别名，**文件连分析阶段都过不去**（`Unable to resolve
symbol: sh/sh`）。这类失败是响的，好发现。

**另一个变体是哑的：** 同一次 merge 里 `handoff_lib.bb` 出现了**两个 `state-dir`**——
upstream 版加在文件开头，fork 版在中段的非冲突区。Clojure 后定义胜出，所以 runtime
侥幸正确、**测试全绿**。这种只有走本表才看得见。

### D-5 handoffd 的对账与重试机制

**差异：** `handoffd.bb` 有一整套 upstream 没有的机制——未领取 handoff 的电平对账重发、
retry ladder、resume floor、busy 角色跳过、每轮唤醒预算、cap 耗尽经
`SWARMFORGE_ALERT_CMD` 告警、唤醒失败只记日志不隔离。另有 `SWARMFORGE_TMUX_STUB` 测试
接缝（所有 tmux 调用统一走 `tmux!`）。

**为什么：** upstream 的投递是一次性的，唤醒丢了就永久卡住。来源 issue #2 / #5，commit
`2c7814d`、`57f524b`、`4893299`、`e75cc43`、`08c02fb`、`0503aa4`。

**钉子：** `handoffd-rewakes-a-handoff-left-unclaimed-in-inbox-new`、
`handoffd-does-not-rewake-a-handoff-already-claimed`、
`handoffd-skips-wake-retries-for-a-busy-role`、
`handoffd-caps-wake-notifications-per-pass`、
`handoffd-keeps-unclaimed-work-in-inbox-new-when-the-wake-fails`、
`handoffd-keeps-retrying-an-old-handoff-past-the-first-wake`、
`handoffd-runs-the-alert-command-once-when-the-cap-is-spent`、
`handoffd-survives-a-failing-alert-command`、
`handoffd-routes-every-tmux-call-through-the-argv-stub`（均在 `handoff_test.clj`）

**历史：** issue #45 的 merge 未触及，9 条钉子全绿。

### D-6 `sync-worktree-scripts!` 是完整镜像，并检查可执行位

**差异：** `swarmforge.bb` 的 `sync-worktree-scripts!` 先 `fs/delete-tree` 再整树复制
（镜像，不是覆盖式合并）；`scripts-mirror-matches?` 在 `diff -rq` 之外单独比对可执行位
集合。配套两个测试接缝：`--test-sync-worktree-scripts`、`--test-scripts-mirror-matches`。

**为什么：** 覆盖式复制会把角色 worktree 里的过期脚本留下，下次启动跑的是旧代码。
`diff -rq` 只比内容，一个丢了 `+x` 位的文件能过 diff 然后在启动时 exec 失败。
来源 issue #29，commit `0c04e81`、`4aadea3`、`9bf7f1e`。

**钉子：** `swarmforge/scripts/test-sync-worktree-scripts.sh`（14 个断言）。
**注意：这个测试不在 `bb test` 里，必须单独跑。**

**历史：** issue #45 的 merge 把两个测试接缝的 defn 与 dispatch 条目一起吃掉了（相邻
add/add 冲突，upstream 侧只有 `test-ensure-codex-trust!`）。被测的
`sync-worktree-scripts!` / `scripts-mirror-matches?` 本体没事，但测试无法调用。补回后
14/14 PASS。

---

## A 类：落在 upstream 没有的文件里，merge 不碰

这些列出来是为了完整，不是为了每次检查。

### D-7 `swarmforge-operator` skill

**位置：** `.agents/skills/swarmforge-operator/`
**内容：** open / start / stop / read swarm、wake / talk role、dashboard、accept work、
onboard project、update SwarmForge scripts 等动词，及其 `test-*.sh` 测试。
**upstream 无对应物。**

### D-8 remote ssh 调用一律带 `-n`

**差异：** `lib-wake-talk.sh` 等脚本里所有 ssh 调用带 `-n`。

**为什么：** ssh 非交互运行且不带 `-n` 时，仍会抽干并转发自己 stdin 上的东西，哪怕远端
命令根本不读。`while read ... done <<< "$VAR"` 循环里的第一个 ssh 调用会把 here-string
喝光，**循环被截断成只跑一轮**。来源 issue #36，commit `0bcf740`。

**钉子：** `test-accept-work.sh`、`test-read-swarm.sh`、`test-stop-swarm.sh`——用一个
**会真的抽干自己 stdin** 的 ssh stub，naive 的 argv 记录 stub 抓不到这个 bug。

### D-9 managed project 的 script snapshot 指向本 fork

**差异：** fork 的 Pack 分支（`two-pack`/`four-pack`/`six-pack`）自带一个默认指向
`arlishansenn/swarm-forge` 的 `swarm` launcher，并且那个 launcher 的 first-run bootstrap
是 staged-then-atomic-rename 安装、装完写 `.swarmforge/scripts-manifest`。`onboard project`
从 fork 的 Pack 分支下载，原样安装，**不做任何解压后改写**。

**为什么：** 见 `docs/adr/0001-script-snapshot-follows-this-fork.md` 与
`docs/adr/0002-fork-owns-the-complete-pack-artifact.md`。照 upstream 流程 onboard 出来的
项目会静默拿到一份 handoff 会卡死的 snapshot（D-1 与 D-5 的修复都不在 upstream）。

ADR 0001 原来的实现手段是「onboard 解压后改写 `ARCHIVE_URL`」，已被 ADR-0002 取代：那次
改写正是 issue #33 里毁掉 launcher 可执行位的来源（`mv` 把 mktemp 的 `0600` 搬了过去，而
`STATUS=ONBOARDED` 照常报成功，podsum 上真实中过）。**不碰这个文件**才是保住字节与 mode
的办法，而不是更小心地把它写回去。

upstream 的 bootstrap 是 `rm -rf` 目标再 `cp -R`，不是崩溃安全的；fork 的 launcher 改成
先在同级 staging 装好再 rename 换入，manifest 一定写在原子安装之后。

**钉子：**
- `test-onboard-project.sh`：`launcher bytes preserved from the archive, not patched`、
  `launcher still executable after onboarding`、`launcher mode preserved from the archive`、
  `onboard downloads the pack from the fork`、`no upstream URL left in onboard-project.sh`
- 各 Pack 分支的 `test-swarm-launcher.sh`（29 条）：manifest digest 与
  `start swarm` 的 `scripts_digest` 一致、安装中途被 kill 目标树不受影响、
  失败不留半装 snapshot 或 manifest。

**注意 digest 是两份独立实现。** launcher 随 Pack 分支发布、由 curl 取回，够不到 operator
skill，所以它自己抄了一份 `scripts_digest`。两边一旦漂移，症状是 bootstrap 之后第一次
`start swarm` 报 DRIFT。`test-swarm-launcher.sh` 里那份参考实现就是钉这个的。

**代价：** upstream 对 `swarmforge/scripts/` 的更新不再自动到达 managed project，需要
人主动同步进本 fork 的 `main`——**也就是本文档描述的这件事**。

**遗留：** `update SwarmForge scripts` 保留它自己那份 `ARCHIVE_URL` 改写与回滚逻辑，
**有意不删**：那是给本次改动之前 onboard 的项目用的 legacy 修复路径，那批项目的 launcher
可能还指着 upstream。它不与已删除的 onboard 改写合并。

---

## 关于把修复推给 upstream

D-1、D-2、D-3、D-6 是「upstream 尚未修的真 bug」，不是口味分歧。这几条一旦被 upstream
收下就永久消失，是唯一能**减少**差异而不是管理差异的动作。

但 `AGENTS.md` 目前禁止在 upstream 的 issue tracker 上创建、编辑或评论。这条规则的代价
就是这几个 delta 要长期自己扛。要不要为 pull request 开个口子，是需要人决定的事，本文档
只负责把账记清楚。

---

## 维护这张表

- 每条差异必须有钉子，且钉子必须**会因为 upstream 的版本而失败**。判据很硬：写完测试，
  把代码换成 upstream 的版本，看它红不红。不红就是没钉住，等于没写。
- merge 之后新出现的差异当场补进本表，别攒。
- 差异被 upstream 采纳后从表里删掉，并在删除的 commit message 里注明是哪个 upstream
  commit 收的。
