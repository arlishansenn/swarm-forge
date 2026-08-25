# Research: upstream SwarmForge 如何定义 task completion，master `inbox/completed` 是否是 human delivery source of truth

Pinned refs：`upstream/main@0b69a51`、`upstream/two-pack@f279178`、
`upstream/four-pack@83f8193`、`upstream/six-pack@c8650d1`（`git remote -v`：
`upstream` = `unclebob/swarm-forge`）。

---

**一句话**：upstream 用 terminal handoff 标记 workflow completion，用 Board `done` 投影该事件，
用各 recipient 的 `inbox/completed` 记录本地处理完成；因此 `accept work` 应只读 master 的
**terminal** completed record，但 #39 当前只检查 `type/task/commit/completed_at`，还缺少
`non-forwarding: true`（或 legacy 全收件人集合）这一 terminal 判据，而且 fork `origin/main`
尚未同步产生这些信号的 upstream commits。

Board `done`、terminal marker 与 master `completed_at` 的写入时间不同：Board 在 daemon 开始投递
terminal handoff 时写入；sender 在发送时写 `non-forwarding: true`；master 只有在
`ready_for_next.sh` merge 并运行 `done_with_current.sh` 后才产生 completed record。Upstream 没有
human accepted 状态，`accept work` 是 fork 自己的 report projection。

---

## Summary

只读 `upstream/main`、`upstream/two-pack`、`upstream/four-pack`、`upstream/six-pack` 的
handoff protocol、`handoffd.bb`、`swarm_handoff.bb`、`ready_for_next_task.bb`、
`done_with_current_task.bb`、`handoff_lib.bb`、`pack_board.bb`、`pack_web.bb`、
`pack/dashboard.html`、三个 pack 的 `swarmforge.conf` 与 master role prompt。逐一验证并用
`git log`/`git show` 交叉核对了两处一开始读错的地方（见 Findings A、Gaps）。核心发现：

1. **「terminal handoff」是发送事件的属性，不是队列位置**：由 sender 是否为 pack 里最后一个
   role（`non-forwarding` stamp）与 `to:` 是否等于「除 sender 外的全部 role」（集合相等，不是
   数量判断）共同判定，两者任一为真即成立。
2. **Board `done` lane 现在对三个 pack 都会触发**，在 `handoffd` 投递终态 handoff 的**那一刻**
   写入，早于任何 recipient 实际处理它。
3. **只有 recipient 自己的 `done_with_current_task.bb` 写 `completed_at`**，这是唯一证明
   「这个 recipient 已经跑过 merge 并主动关闭这个队列项」的持久状态，且是 per-recipient 的
   （master 与中间 role 各自有自己的 `inbox/completed`）。
4. **upstream 没有「human accepted」状态**。最接近的机制（`should-hold?` / `pending_approval` /
   dashboard `/api/approvals/*`）是 four/six-pack 里 specifier（master）**发出**单收件人
   handoff 前的操作者审批闸门，方向与 `accept work` 想读的「master 收到终态交付」相反，不能
   混用。
5. **fork 尚未拥有这套 latest mechanism**。`origin/main` 与 `upstream/main` 的 merge-base 是
   `1e78c44`；fork 落后 19 个 upstream commits，包含 `771d1fa`（terminal broadcast → Board
   Done）与 `0b69a51`（last-role `non-forwarding` stamp）。当前 fork `handoffd.bb` 仍用
   `(next recipients)` 判断 Done，`swarm_handoff.bb` 不产生 `non-forwarding`。

## Findings

### A. Terminal handoff 的判定机制：两个独立信号，不是「收件人数量」

**1 → `terminal-handoff?` = `non-forwarding?` OR `terminal-broadcast?`，不是 recipient 计数。**
`swarmforge/scripts/handoffd.bb:174-179`：

```clojure
(defn non-forwarding? [headers]
  (= "true" (get headers "non-forwarding")))

(defn terminal-handoff? [roles headers]
  (or (non-forwarding? headers)
      (terminal-broadcast? roles headers)))
```

`terminal-broadcast?`（`handoffd.bb:165-172`）比较的是**集合相等**：`to:` 展开后的收件人集合
必须等于「pack 里除 sender 外的全部 role」（`other-roles`，`handoffd.bb:160-163`），并且要求
sender 不是 master（`from-master?`，`handoffd.bb:157-159`）。two-pack 只有 2 个 role，
「除 cleaner 外的全部 role」天然只有 `coder` 一个名字——所以 two-pack 的终态 handoff **在
`to:` 字段上就是单收件人**，仍然判定为 terminal。这一点我在本次研究最初读 `handoffd.bb` 时
读错了（见 Gaps 第 1 条），已用 `git show upstream/main:swarmforge/scripts/handoffd.bb`
三次独立复核（全文、`grep -n`、`sed -n` 分段）确认现状如上。

**2 → `non-forwarding: true` 由 sender 在 pack 里的位置决定，与 `to:` 无关。**
`swarmforge/scripts/swarm_handoff.bb:157-170`：

```clojure
(defn pack-role-names []
  (->> (str/split-lines (slurp (str (roles-file))))
       (remove str/blank?)
       (map #(first (str/split % #"\t")))
       vec))

(defn last-pack-role? [role]
  (= role (last (pack-role-names))))

(defn with-non-forwarding [headers sender]
  (if (and (= "git_handoff" (get headers "type"))
           (last-pack-role? sender))
    (assoc headers "non-forwarding" "true")
    headers))
```

`roles.tsv` 的行序跟随 `swarmforge.conf` 的 `window` 声明顺序。三个 pack 的
`swarmforge.conf`（`upstream/two-pack:swarmforge/swarmforge.conf`、
`upstream/four-pack:swarmforge/swarmforge.conf`、
`upstream/six-pack:swarmforge/swarmforge.conf`）里最后一行分别是 `cleaner`、`architect`、
`QA`——与 `handoff-protocol.md`「Terminal broadcast」列出的三个终态发送者完全一致
（`swarmforge/handoff-protocol.md:173-186`，`upstream/main`）。

**3 → 这个 stamp 同时是「工具层强制」，不只是 prompt 约定。**
`swarm_handoff.bb:507-509`（`-main` 校验阶段）：master 收到终态 handoff 之后，只要那份
inbound handoff 还带着 `non-forwarding: true` 且未被 `done_with_current.sh` 处理掉，
`swarm_handoff.sh` 本身就拒绝再发任何 `git_handoff`：`"Current inbound handoff is
non-forwarding; do not send a git_handoff."`（`inbound-non-forwarding?`，
`swarm_handoff.bb:177-179`，读的是当前 `inbox/in_process`）。role prompt 里「merges only」
的措辞（见 Findings E）只是把这条工具约束写给 agent 看，真正的强制点在这里。

### B. Board `done` lane：三个 pack 现在都会到达，写入时机是「投递」而不是「处理」

**4 → `update-board!` 在 `deliver!` 内部、复制文件到收件箱之前就执行。**
`handoffd.bb:270-289` 的 `deliver!`：

```clojure
(defn deliver! [roles socket sender-role path]
  ...
  (do
    (update-board! roles headers)
    (doseq [recipient recipients]
      ... (spit (str target) ...) (notify! socket ...))
    (move-with-collision path (sent-dir roles sender-role))
    (archive-sender! headers)
    (log! "delivered" (str path))))
```

`update-board!`（`handoffd.bb:229-239`）：非终态 → `pack-board! "move" --lane <first
recipient>`；终态 → 对 `terminal-task-names` 里的每个 task name 执行
`pack-board! "done" --name <name>`。这一步发生在**任何 recipient 打开这份 handoff 之前**——
和 `docs/research/handoff-reconciliation-standards.md` 里已经论证过的「`capture-pane`
只是诊断，不是确认」同一类问题：Board `done` 证明的是「daemon 认定这次投递是终态形状」，不是
「recipient 已经做了什么」。

**5 → `terminal-task-names` 可能一次把多个 task name 标 done（batch 场景）。**
`handoffd.bb:219-227`：先取 `headers["task"]`，再从 sender 自己 worktree 的
`inbox/completed` + `inbox/in_process` 里找「已完成/在办」的 task name，与 sender 当前
Board 车道上的卡片名字取交集，一并标 done。提交历史里对应 commit
`771d1fa End packs with a last-role broadcast to Done.` 和
`f178a10 Archive panes on complete, name batches from the top task, and stop
auto-merging on done.`（`git log upstream/main -- swarmforge/handoff-protocol.md`）。
这意味着一次终态广播可能同时把若干张卡标 done，`accept work` 如果要用 Board `done` 做
cross-check，不能假设「一次投递只对应一个 task name」。

**6 → Dashboard 确实渲染 `done` 列，卡片不会消失。**
`swarmforge/scripts/pack/dashboard.html:282`：`const lanes = (data.lanes ||
[]).concat(["done"]);`——`done` 是追加的固定列，`tasks.tsv` 里 lane=done 的行永远留着直到被
`pack_board.sh delete` 删除。`pack_web.bb:236-245`（`task-with-status`）把 lane=done 的卡片
状态字段设为空字符串 `""`，其余状态（`REJECTED`、`Waiting for approval`、实时 pane 状态、
`waiting in queue`）都是给「还在流转」的卡片用的——done 卡片只是不再显示状态文案，仍然渲染在
`done` 列。

### C. Recipient 处理完成：唯一的 per-recipient 持久信号

**7 → `ready_for_next_task.bb` 对任何 `git_handoff` 都会 merge，不区分是否终态。**
`swarmforge/scripts/ready_for_next_task.bb:93-101`（`merge-git-handoff!`）对 `in_process`
里的当前文件调用 `merge_and_process.sh <from> <commit>`；终态与非终态走同一条代码路径，唯一
差别在于终态文件带着 `non-forwarding: true`（供 B 里提到的 outbound gate 使用）。

**8 → `done_with_current_task.bb` 才写 `completed_at` 并把文件移进 recipient **自己**的
`inbox/completed/`。**
`swarmforge/scripts/done_with_current_task.bb:65-93`：要求 `inbox/in_process` 恰好一个
文件，`set-header!` 写 `completed_at`，`fs/move` 到 `completed-dir`，随后调用
`swarmforge/scripts/handoff_lib.bb:173-176` 的 `finish-done!`（archive 自己的 pane +
`announce-follow-up!` 打印 `MAIL_WAITING`/`NO_TASK`，与 Board 无关）。这一步是
**per-recipient**：two-pack 里 cleaner 处理第一跳时也会在自己的 `inbox/completed` 留一份
记录（对应中间提交），master(coder) 处理终态跳时在**它自己**的 `inbox/completed` 留下带
`completed_at` 的终态记录——这正是 `accept-work.sh` 当前误读 cleaner 记录、应该只读 master
记录的根因（见 Gaps 第 2 条，与 issue #39 描述的现场一致）。

### D. 三个 pack 的 state transition

以下只保留 upstream source 能证明的状态，箭头旁标注触发它的函数。

```text
two-pack（master = coder，swarmforge.conf: window coder ... master / window cleaner ... cleaner）

New Task (dashboard)
  Board: create --lane coder            [pack_web.bb:688 create-task!]
  master inbox/new: type=note "(New Task)"  [pack_web.bb:574 queue-new-task-note!]

coder (master) 处理 New Task
  ready_for_next_task.bb: TASK (note, 无 commit)
  完成实现后 commit，swarm_handoff.sh git_handoff -> cleaner
    with-non-forwarding: coder 不是 last-pack-role，不 stamp
  handoffd deliver!:
    terminal-handoff? = false（非终态）
    Board: move --lane cleaner            [handoffd.bb:229-239]
  coder: done_with_current.sh -> completed_at（coder 自己的 inbox/completed，中间记录）

cleaner (last-pack-role) 处理
  ready_for_next_task.bb: merge coder 的 commit
  完成 cleanup 后 commit，swarm_handoff.sh git_handoff -> coder
    with-non-forwarding: cleaner 是 last-pack-role -> stamp non-forwarding: true
  handoffd deliver!:
    terminal-handoff? = true（non-forwarding 且 to:={coder}=other-roles）
    Board: done --name <task>             [HANDOFF DELIVERED，非「已处理」]
  cleaner: done_with_current.sh -> completed_at（cleaner 自己的 inbox/completed，中间记录）

coder (master) 收到终态 handoff
  ready_for_next_task.bb: merge cleaner 的终态 commit    <- ROLE PROCESSING 开始
  coder: done_with_current.sh -> completed_at（coder 自己的 inbox/completed）
                                                          <- ROLE PROCESSING COMPLETED
                                                          <- 唯一的 per-task 权威交付记录
  coder 再想发 git_handoff：swarm_handoff.sh 因 inbound-non-forwarding? 拒绝
```

```text
four-pack（master = specifier，最后一个 role = architect）
specifier -> coder -> refactorer -> architect（stamp non-forwarding，broadcast 到
{specifier,coder,refactorer}） -> 各自 merge-only；specifier 自己的 inbox/completed 是权威
交付记录。specifier 作为 sender 发第一跳时，若目标是单收件人，还要经过 should-hold?/approve!
审批闸门（见 Findings F），这一闸门与「谁认定任务完成」无关。
```

```text
six-pack（master = specifier，最后一个 role = QA）
specifier -> coder -> cleaner -> architect -> hardender -> QA（stamp non-forwarding，
broadcast 到其余 5 个 role，含 specifier） -> 各自 merge-only；specifier 自己的
inbox/completed 是权威交付记录。
```

### E. Role prompt 对「merge only」的描述与工具层一致

**9 → two/four/six-pack 的 master role prompt 都写「merges only, 然后问用户下一步」，不写
「标记 done」或「通知已接受」。**
`upstream/two-pack:swarmforge/roles/coder.prompt`：「On notify or restart, run
`ready_for_next.sh`. ... If the inbound `git_handoff` is from cleaner, run unit tests, fix
failures, and run `done_with_current.sh`. Do not send a `git_handoff`.」
`upstream/four-pack:swarmforge/roles/specifier.prompt` 与
`upstream/six-pack:swarmforge/roles/specifier.prompt` 的 Handoff 小节都是「When the
architect/QA notifies you that the job is complete, run `ready_for_next.sh` (it merges).
Then ask the user for the next feature to add.」——upstream 把「告诉人类」这件事留给 agent
在对话里说，不落地成任何机器可读状态，这与 Findings D「human accepted 未建模」一致。

### F. Single-recipient return-to-master 与 multi-recipient broadcast 的 Board 语义

`handoff-protocol.md:173-186`（`upstream/main`）原文已经把两者统一成同一条规则，不是两条：

> The terminal handoff is the last role's `git_handoff` whose `to:` is every other role in
> the pack. That set, not a count of names, marks the card Done.

- two-pack：cleaner `to: coder`（对 2-role pack 而言，「除 cleaner 外的全部 role」正好只有
  1 个名字）——**判定标准是集合相等，不是「≥2 个收件人才算 broadcast」**。
- four-pack：architect `to: specifier,coder,refactorer`（3 个名字，等于除 architect 外的
  全部 role）。
- six-pack：QA `to:` 其余 5 个 role。

三者都会触发 `update-board!` 的 done 分支（Findings B），Board 语义上没有区分「回到 master
一人」和「广播给所有人」——**区分点在于「谁是 sender、sender 在不在 pack 末位」，不在于收件人
数量**。six-pack 的 QA 广播之所以看起来「更像 broadcast」，只是因为 six-pack 除 QA 外还有
4 个非 master role 需要一起收到这份终态 commit；对 Board 记账逻辑而言，two-pack 的单收件人
返回和 six-pack 的五收件人广播走的是同一段代码。

## `arlishansenn/swarm-forge#39` 评估

评估对象：<https://github.com/arlishansenn/swarm-forge/issues/39>
（`accept work` 应直接读取 master completed terminal handoff，不再跨 worktree 推断
chain）。只评估该 issue 正文，不复制其全文。

**核心 seam 正确，但 #39 需要 major requirement revision：**

- 「找到唯一 `worktree-name == master` 的 Role」——与 `pack_board.bb:186-193`
  `master-lane!`（要求 `roles.tsv` 里恰好一行 `worktree-name = master`）逐字一致。
- `task`、`commit`、`completed_at` 证明 master 已 merge 并完成该 recipient copy，但它们
  **不能单独证明 terminal**。候选 record 还必须满足 `non-forwarding: true`；兼容 marker
  之前的 records 时，允许 `to:` recipient set 等于 `roles.tsv` 中除 sender 外全部 Role。
  master 也可能完成非终态 inbound handoff，不能把所有 completed `git_handoff` 都视为交付。
- 「同一 task 多次 terminal return 时取 `completed_at` 最新一条」——`done_with_current_task.bb`
  只在同名文件已存在时才拒绝（`AMBIGUOUS_TASK_STATE`），不同轮次的终态 handoff 文件名
  不同（含时间戳、sequence），所以同一个 task name 在 master 自己的 `inbox/completed` 下
  可以合法堆积多条记录，用时间戳挑最新是正确做法。
- 「report-only，不修改 Board 或 handoff files」——上面所有信号都是 upstream 自己的
  helper（`handoffd`、`swarm_handoff.sh`、`ready_for_next.sh`、`done_with_current.sh`）
  写入的，`accept work` 读它们即可，不需要、也不应该自己再写一份。

**必须修正的 contract：**

1. issue 的 Pack 描述已过期。Latest upstream 是 last Role 向 every other Role broadcast：
   two-pack `cleaner → coder`，four-pack `architect → specifier,coder,refactorer`，six-pack
   `QA →` 其余五个 Role。`0b69a51` 又自动给 last-role handoff 加 `non-forwarding: true`，作为
   explicit terminal marker 与 compatibility path。
2. Board 存在时，选中的 task 应位于 `done` lane；不一致必须 WARN，不能只拿 Board name 做
   issue mapping。Board 缺失时，terminal marker + master completed record 仍可报告，但必须明确
   这是 legacy/non-dashboard intake。
3. 实现 #39 前必须把 upstream `771d1fa`、`0b69a51` 及其依赖安全同步到 fork，或明确实现
   legacy compatibility。否则 fork runtime 不会写出 latest terminal marker，two-pack Board
   也不会按 latest protocol 进入 Done。

**与 #39 无关、不要混进同一验证逻辑的机制：** `should-hold?` / `pending_approval` /
`/api/approvals/*`（`handoffd.bb:247-259`、`pack_web.bb:767-776`）是 four/six-pack 里
specifier（master）**发出**单收件人 handoff 前的操作者审批闸门，方向是「master 要发的东西
需要人先批准」，与 `accept work` 要读的「master 收到的终态交付」正好相反。两者都是
「human-in-the-loop」但作用在链路两端，不能用同一段代码或同一份文档合并描述。

## Gaps / 未验证项

**1 → 本次研究前段一度读到与当前 `upstream/main` 不一致的 `handoff-protocol.md` /
`handoffd.bb` 内容**（旧版措辞是「多收件人才算 broadcast」、`update-board!` 用
`(if (next recipients) ...)` 数收件人）。已用 `git show`（全文 + `grep -n` + `sed -n`
分段，三次独立复核）确认当前committed 内容如本文 Findings A/B 所写；不确定第一次读到的内容
从何而来（可能是工具输出被截断/顺序错乱，也可能是我在早期回合里记错了另一份历史版本），但
最终结论以本次三重复核的 `git show` 输出为准，不采信最初的读数。

**2 → 未在真实 Managed project 上重新跑一次经由 Dashboard New Task 的完整 two-pack 链路来
验证 Board `done` 与 master `inbox/completed` 的时间差。** 本文 D 节的状态机完全来自代码
静态阅读，未做 E2E 实测；此前 podsum 上的实测（`.swarmforge/board/tasks.tsv` 不存在）本来就
绕过了 Board，无法用来验证 Board 部分。

**3 → `terminal-task-names` 的 batch 交集逻辑（Findings B-5）未做边界测试**，不确定「sender
worktree 里同时有多个已完成同名之外的 task 卡片停在同一车道」这种场景在真实三 pack 里出现的
频率，只确认了代码路径存在。

**4 → 已确认 fork 与 latest upstream 不一致。** `git merge-base origin/main upstream/main`
为 `1e78c44`，`git rev-list --left-right --count origin/main...upstream/main` 为 `68 19`。当前 fork
`handoffd.bb:update-board!` 仍以 `(next recipients)` 作为 Done 判据：two-pack 的单收件人终态
只会把 card 移回 coder；当前 fork `swarm_handoff.bb` 与 `swarmforge.bb` 也没有
`non-forwarding` / last-role terminal instruction。故本文 Findings A–F 描述的是 latest
upstream contract，不是 fork 当前 runtime contract。

## Sources

### Internal（均为 primary source，按 pinned commit 读取）

- `swarmforge/handoff-protocol.md:157-186`（`upstream/main@0b69a51`）：Chain forwarding /
  Terminal broadcast 定义与三个 pack 的示例。
- `swarmforge/scripts/handoffd.bb:142-292`（`upstream/main@0b69a51`）：
  `master-role-name`、`specifier-pack?`、`from-master?`、`other-roles`、
  `terminal-broadcast?`、`non-forwarding?`、`terminal-handoff?`、`terminal-task-names`、
  `update-board!`、`single-recipient?`、`already-approved?`、`should-hold?`、`hold!`、
  `deliver!`。
- `swarmforge/scripts/swarm_handoff.bb:150-179,254-259,503-524`
  （`upstream/main@0b69a51`）：`with-board-task`、`pack-role-names`、`last-pack-role?`、
  `with-non-forwarding`、`inbound-non-forwarding?`、outbound 校验阶段拒绝转发终态 handoff。
- `swarmforge/scripts/ready_for_next_task.bb:93-101,102-155`
  （`upstream/main@0b69a51`）：`merge-git-handoff!`，`git_handoff` 一律 merge，不区分终态。
- `swarmforge/scripts/done_with_current_task.bb:65-95`（`upstream/main@0b69a51`）：
  `completed_at` 写入点，`fs/move` 到 recipient 自己的 `inbox/completed`，`finish-done!`
  调用点。
- `swarmforge/scripts/handoff_lib.bb:159-176`（`upstream/main@0b69a51`）：
  `archive-current-role!`、`announce-follow-up!`、`finish-done!`（与 Board 无关）。
- `swarmforge/scripts/pack_board.bb:135-193,226-235`（`upstream/main@0b69a51`）：
  `create!`、`move!`、`done!`、`master-lane!`、`archive!`，`tasks.tsv` 的 4 列格式。
- `swarmforge/scripts/pack_web.bb:157,236-245,574-586,688-696,767-800`
  （`upstream/main@0b69a51`）：`master-role`、`task-with-status`、`queue-new-task-note!`、
  `create-task!`、`approve!`、`/api/approvals/*` 路由、`should-hold?` 对应的审批闸门。
- `swarmforge/scripts/pack/dashboard.html:282`（`upstream/main@0b69a51`）：`done` 车道
  被硬追加进渲染的车道列表。
- `swarmforge/swarmforge.conf`（`upstream/two-pack@f279178`、
  `upstream/four-pack@83f8193`、`upstream/six-pack@c8650d1`）：三个 pack 的
  `window`/`window-invisible` 行序，确认 `master` worktree 名字与「最后一个 role」分别是
  coder/cleaner、specifier/architect、specifier/QA。
- `swarmforge/roles/coder.prompt`（`upstream/two-pack@f279178`）、
  `swarmforge/roles/specifier.prompt`（`upstream/four-pack@83f8193`、
  `upstream/six-pack@c8650d1`）：master role prompt 对「merge only」的描述。
- `git log upstream/main --oneline -- swarmforge/handoff-protocol.md` /
  `-- swarmforge/scripts/handoffd.bb`：`771d1fa End packs with a last-role broadcast to
  Done.`、`f178a10 Archive panes on complete, name batches from the top task, and stop
  auto-merging on done.`、`0b69a51 Trust Codex worktrees on launch and stamp last-role
  handoffs non-forwarding.`——确认 Board `done` 三 pack 统一行为与 `non-forwarding` stamp
  是近期一起落地的设计，不是历史遗留的不一致。
- `docs/research/handoff-reconciliation-standards.md`（本仓库 `main`）：已确立的内部标准
  「文件位置移动才是权威确认，`capture-pane`/日志只是诊断」，本文沿用同一原则区分 Board
  `done`（投递时）与 master `completed_at`（处理后）。
- `docs/adr/0001-script-snapshot-follows-this-fork.md`（本仓库 `main`）：解释了为什么 fork
  侧的 Script snapshot 不会自动跟随 upstream。
- `git merge-base origin/main upstream/main`、`git rev-list --left-right --count
  origin/main...upstream/main`，以及 fork 当前 `swarmforge/scripts/handoffd.bb:update-board!`：
  确认 fork 缺少 `771d1fa` / `0b69a51` terminal mechanism，而不是推测。
