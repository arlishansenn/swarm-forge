# swarm-forge issues #1–#4 处理实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 #4 关票 → #1 修唤醒提交键 → #2 拆票并实现 reconcile 核心 → #3 降级重写 的顺序，清掉 arlishansenn/swarm-forge 的前四张票。

**Architecture:** 唤醒链路有两层。快路径是 `handoffd.bb` 的 `notify!`，把唤醒文本和提交键送进角色的 tmux session；#1 修的是提交键编码错误，让常见情况第一次就成功。慢路径是新增的 `reconcile-once!`，挂在既有的 1 秒 `poll-once!` 循环里，把 `inbox/new` 里的持久文件当作「未领取」电平，到期重发同一条唤醒，直到 `ready_for_next` 把文件移进 `in_process`；这让唤醒从 fire-and-forget 变成 at-least-once。两层共用一个新的 tmux argv stub 接缝，测试因此不需要真 TUI。

**Tech Stack:** Babashka（`swarmforge/scripts/*.bb`）、`clojure.test` 经 `bb test`、bash + `set -euo pipefail`、tmux、`gh` CLI。

**Spec:** 本计划直接依据四张 issue 正文与评论：

- https://github.com/arlishansenn/swarm-forge/issues/1
- https://github.com/arlishansenn/swarm-forge/issues/2（含两条评论：adversarial review 契约 1–5、alert 通道契约 6）
- https://github.com/arlishansenn/swarm-forge/issues/3
- https://github.com/arlishansenn/swarm-forge/issues/4

设计底稿：`docs/research/handoff-reconciliation-standards.md`、`docs/research/alert-channel-internal.md`、`docs/research/alert-channel-external.md`。

## Global Constraints

- 所有新增文档与注释用中文说明，technical term 保持 English，不造中文译名。
- 测试入口只有一个：仓库根目录 `bb test`（见 `bb.edn`，跑 `swarmforge.handoff-test`、`swarmforge.script-test`、`swarmforge.pack-ui-test`）。
- Clojure 注释解释 **为什么**，不解释 what；跟着它守护的代码走，不单独堆在文件头。
- 红线（来自 issue #2 契约，任何 task 不得违反）：reconcile 路径**绝不**移动、复制、删除或改写 `inbox/new` 里的文件；通知失败**绝不**走 `fail!` → `failed/`；`capture-pane` 的输出只能影响日志，不能影响任何持久队列状态。
- 每个 task 一个 commit，commit message 用 conventional commits 前缀。
- 不 push 到 `main`，不 force-push。
- 术语按 `CONTEXT.md`：pack（角色拓扑配置）、swarm launcher（`./swarm`）、managed project、script snapshot。

## File Structure

| 文件 | 职责 | 本计划中的变化 |
|---|---|---|
| `swarmforge/scripts/handoffd.bb` | handoff 守护进程：投递 + 唤醒 | 加 tmux stub 接缝、改 `submit-keys`、加 `reconcile-once!` |
| `swarmforge/scripts/pack_web.bb` | dashboard 后端，含 `inject-master!` 注入 | 复用同一份提交键，删掉本地的 `C-m`/`C-j` |
| `test/swarmforge/handoff_test.clj` | handoffd / handoff 脚本的端到端测试 | 加 stub 助手 + 8 个新 deftest |
| `test/swarmforge/pack_ui_test.clj` | dashboard 测试 | 改钉死 `C-m`/`C-j` 的 argv 断言 |
| `.agents/skills/swarmforge-operator/SKILL.md` | operator skill 契约 | `wake role` 的提交键文档同步；（Task 9）加 `onboard project` verb |
| `.agents/skills/swarmforge-operator/scripts/onboard-project.sh` | （Task 9 新建）装 upstream pack | 新建 |
| `.agents/skills/swarmforge-operator/scripts/test-onboard-project.sh` | （Task 9 新建）上面那个的测试 | 新建 |

**为什么提交键要抽成一处**：同一份「文本 + 提交键」逻辑现在复制在 `handoffd.bb:122-142`、`pack_web.bb:106-112`、`SKILL.md:135-141` 三处。只改 handoffd 会让同一个 bug 从 dashboard 注入和人工 wake 两条路重新长出来。`handoffd.bb` 是唯一常驻进程，把它当权威，`pack_web.bb` 跟随。

---

### Task 1: 关闭 issue #4（已交付归档票）

无代码改动。#4 记录的两处改动已在仓库里。

**Files:** 无

**Interfaces:**

- Consumes: 无
- Produces: 无

- [ ] **Step 1: 核对交付证据**

```bash
grep -n "accept work" README.md
grep -n 'Verb: `accept work`' .agents/skills/swarmforge-operator/SKILL.md
git log --oneline -5 -- .agents/skills/swarmforge-operator/SKILL.md README.md
```

预期：`README.md` 的八 verb 表里有 `accept work` 行；`SKILL.md` 有 `## Verb: accept work` 一节；`git log` 里能看到 `241de93`、`54e9c15`。

- [ ] **Step 2: 三项证据齐全就关票**

```bash
gh issue close 4 -R arlishansenn/swarm-forge --comment "已交付并核对：SKILL.md 有完整 accept work verb 节，README 八 verb 表含该行，落库 commit 241de93 / 54e9c15。归档信息留在 git history，票关闭。"
```

任一项缺失就不要关，改为在票里贴出缺哪一项。

---

### Task 2: 给 handoffd 加 tmux argv stub 接缝

#1 的验收标准要求「A regression test locks the backend-specific submit events」。`handoffd.bb` 现在直接调 `sh`，测试无法观察它发了什么键。`pack_web.bb` 已有 `SWARMFORGE_TMUX_STUB` 接缝，把同一个接缝搬进 handoffd，#1 和 #2 的测试都靠它。

**Files:**

- Modify: `swarmforge/scripts/handoffd.bb:101-142`
- Test: `test/swarmforge/handoff_test.clj`

**Interfaces:**

- Consumes: 无
- Produces:
  - `(tmux-stub) => String | nil` —— stub 文件路径，来自 env `SWARMFORGE_TMUX_STUB`
  - `(tmux! & argv) => {:exit int :out String :err String}` —— 所有 tmux 调用的唯一出口
  - stub 文件格式：每行一个 `(pr-str (vec argv))`，与 `pack_web.bb:70` 完全一致，因此测试可以用 `read-string` 读回

- [ ] **Step 1: 写失败的测试**

在 `test/swarmforge/handoff_test.clj` 的 `head-sha` 函数下面加助手：

```clojure
(defn read-argv
  "Read a SWARMFORGE_TMUX_STUB file back into a vector of argv vectors."
  [path]
  (if (fs/exists? path)
    (->> (str/split-lines (read-file path))
         (remove str/blank?)
         (mapv read-string))
    []))

(defn run-handoffd-once!
  "One daemon pass with tmux replaced by an argv recorder."
  [root argv-file]
  (run {:dir root :env {"SWARMFORGE_TMUX_STUB" (str argv-file)}}
       "bb" (script "handoffd.bb") "--once" (str root)))
```

在文件末尾加测试：

```clojure
(deftest handoffd-routes-every-tmux-call-through-the-argv-stub
  ;; Given a queued outbox handoff and SWARMFORGE_TMUX_STUB set
  ;; When the daemon runs one pass
  ;; Then no real tmux runs: the wake text lands in the stub file instead
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"sender" "task" "receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (write-file (fs/path root ".swarmforge/handoffs/outbox/50_20260101T000000Z_000001_from_sender_to_receiver.handoff")
                (handoff {:id "20260101T000000Z_000001_from_sender"
                          :from "sender" :to "receiver"
                          :priority "50" :type "message" :task "stub-seam"}))
    (run-handoffd-once! root argv-file)
    (let [argv (read-argv argv-file)]
      (is (= ["tmux" "-S" "/tmp/fake.sock" "send-keys" "-t" "session" "-l"
              "You have new handoff mail. If idle, run ready_for_next.sh."]
             (first argv))
          "the wake text send must be recorded, not executed"))))
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
bb test
```

预期：FAIL，`(first argv)` 是 `nil`——stub 文件根本没被写出来，因为 `handoffd.bb` 还在直接调 `sh`。

- [ ] **Step 3: 写最小实现**

在 `swarmforge/scripts/handoffd.bb` 里，把 `pane-text`（第 101 行）上面插入：

```clojure
(defn tmux-stub []
  (System/getenv "SWARMFORGE_TMUX_STUB"))

(defn record-argv! [file argv]
  (when-let [dir (fs/parent file)]
    (fs/create-dirs dir))
  (spit (str file) (str (pr-str (vec argv)) "\n") :append true))

(defn tmux!
  "Every tmux call goes through here so tests can record argv instead of driving
  a real TUI. The stub answers exit 0: a recorder has nothing to fail at."
  [& argv]
  (let [full (into ["tmux"] argv)]
    (if-let [stub (tmux-stub)]
      (do (record-argv! stub full) {:exit 0 :out "" :err ""})
      (apply sh full))))
```

把 `pane-text` 改成用它：

```clojure
(defn pane-text [socket session]
  (let [result (tmux! "-S" socket "capture-pane" "-p" "-t" session)]
    (if (zero? (:exit result)) (:out result) "")))
```

把 `notify!`（第 134 行）整个替换成：

```clojure
(defn notify! [socket session agent]
  (let [send-text (tmux! "-S" socket "send-keys" "-t" session "-l" wake-message)]
    (when-not (zero? (:exit send-text))
      (throw (ex-info "tmux send text failed" send-text)))
    ;; Under the stub there is no pane to echo into, so waiting would just burn
    ;; the timeout on every recorded call.
    (when-not (tmux-stub)
      (await-wake-echo! socket session))
    (doseq [keys (submit-keys agent)]
      (let [result (apply tmux! (concat ["-S" socket "send-keys" "-t" session] keys))]
        (when-not (zero? (:exit result))
          (throw (ex-info "tmux send submit key failed" result)))
        (when-not (tmux-stub)
          (Thread/sleep 50))))))
```

- [ ] **Step 4: 跑测试确认通过**

```bash
bb test
```

预期：PASS，且既有测试全绿（`stop-handoff-daemon-stops-running-process-and-removes-pid-file` 不设 stub，走真 `sh`，行为不变）。

- [ ] **Step 5: 提交**

```bash
git add swarmforge/scripts/handoffd.bb test/swarmforge/handoff_test.clj
git commit -m "test(handoffd): tmux 调用统一走 tmux!，加 SWARMFORGE_TMUX_STUB 接缝"
```

---

### Task 3: #1 —— codex/grok 的提交键改裸回车

`submit-keys` 现在给非 claude backend 发符号键 `C-m`/`C-j`。符号键名要过 tmux 的 key-encoding 层：当 app 协商了 extended keys 时，tmux 会把它编成 CSI-u 形式，codex 收到的就不是字面 Enter，唤醒文本躺在输入框里不提交。`-H 0d` 直接送裸字节 0x0d，绕开这一层。

**Files:**

- Modify: `swarmforge/scripts/handoffd.bb:122-132`
- Test: `test/swarmforge/handoff_test.clj`

**Interfaces:**

- Consumes: Task 2 的 `(tmux-stub)`、`(tmux! & argv)`、测试助手 `read-argv`、`run-handoffd-once!`
- Produces: `(submit-keys agent) => [[String]]` —— claude 返回 `[["-H" "1b" "5b" "31" "33" "75"]]`，其它一律 `[["-H" "0d"]]`

- [ ] **Step 1: 写失败的测试**

在 `test/swarmforge/handoff_test.clj` 末尾加：

```clojure
(deftest handoffd-submits-a-codex-wake-with-a-raw-carriage-return
  ;; Given a codex role receiving a handoff
  ;; When the daemon delivers it
  ;; Then Enter goes out as the raw byte 0d, not as the symbolic C-m/C-j that
  ;; tmux re-encodes for a TUI that negotiated extended keys
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"sender" "task" "receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (write-file (fs/path root ".swarmforge/handoffs/outbox/50_20260101T000000Z_000002_from_sender_to_receiver.handoff")
                (handoff {:id "20260101T000000Z_000002_from_sender"
                          :from "sender" :to "receiver"
                          :priority "50" :type "message" :task "codex-enter"}))
    (run-handoffd-once! root argv-file)
    (let [argv (read-argv argv-file)]
      (is (= ["tmux" "-S" "/tmp/fake.sock" "send-keys" "-t" "session" "-H" "0d"]
             (second argv)))
      (is (= 2 (count argv)) "raw CR replaces the C-m + C-j pair, so one submit call"))))

(deftest handoffd-submits-a-claude-wake-with-csi-u-enter
  ;; Given a claude role receiving a handoff
  ;; When the daemon delivers it
  ;; Then Enter stays CSI-u: claude negotiates the kitty keyboard protocol and
  ;; ignores a bare CR
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"sender" "task" "receiver" "task"})
    (write-file (fs/path root ".swarmforge/roles.tsv")
                (str "sender\tmaster\t" root "\tsession\tSender\tclaude\ttask\n"
                     "receiver\tmaster\t" root "\tsession\tReceiver\tclaude\ttask\n"))
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (write-file (fs/path root ".swarmforge/handoffs/outbox/50_20260101T000000Z_000003_from_sender_to_receiver.handoff")
                (handoff {:id "20260101T000000Z_000003_from_sender"
                          :from "sender" :to "receiver"
                          :priority "50" :type "message" :task "claude-enter"}))
    (run-handoffd-once! root argv-file)
    (is (= ["tmux" "-S" "/tmp/fake.sock" "send-keys" "-t" "session" "-H" "1b" "5b" "31" "33" "75"]
           (second (read-argv argv-file))))))
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
bb test
```

预期：codex 那条 FAIL——实际记到的是 `[... "C-m"]` 且 argv 有 3 行；claude 那条应当已经 PASS（现有代码就是 CSI-u），它是防回归的锁。

- [ ] **Step 3: 写最小实现**

把 `swarmforge/scripts/handoffd.bb` 的 `submit-keys` 整个替换成：

```clojure
(defn submit-keys
  "tmux send-keys arguments that make this agent's TUI submit its input line.

  Both branches send raw bytes on purpose. A symbolic key name goes through
  tmux's key-encoding layer, which re-encodes it for a TUI that negotiated
  extended keys, so `C-m` does not reliably arrive as a literal Enter. Claude
  Code negotiates the kitty keyboard protocol and only submits on CSI u
  (ESC [ 13 u); every other backend wants the plain carriage return 0x0d, and
  sending CSI u to a TUI that did not negotiate would insert those bytes as
  literal text."
  [agent]
  (if (= agent "claude")
    [["-H" "1b" "5b" "31" "33" "75"]]
    [["-H" "0d"]]))
```

- [ ] **Step 4: 跑测试确认通过**

```bash
bb test
```

预期：两条新测试都 PASS。

- [ ] **Step 5: 提交**

```bash
git add swarmforge/scripts/handoffd.bb test/swarmforge/handoff_test.clj
git commit -m "fix(handoffd): 非 claude backend 的 Enter 用裸回车 -H 0d，不用符号 C-m/C-j

符号键名过 tmux key-encoding 层，协商了 extended keys 的 TUI 收到的不是字面
Enter，唤醒文本躺在输入框里不提交。Closes #1"
```

---

### Task 4: #1 同源修复 —— pack_web 注入与 SKILL.md 文档

票面只说 handoffd，但同一份提交键还复制在 dashboard 的注入路径和 operator skill 的文档命令里。不一起改，同一个 bug 会从这两条路重新长出来。

**Files:**

- Modify: `swarmforge/scripts/pack_web.bb:100-112`
- Modify: `test/swarmforge/pack_ui_test.clj:469-489`
- Modify: `.agents/skills/swarmforge-operator/SKILL.md:130-152`

**Interfaces:**

- Consumes: Task 3 定下的编码约定（claude → CSI-u，其它 → `-H 0d`）
- Produces: `pack_web.bb` 的 `(submit-keys agent)`，签名与 `handoffd.bb` 的同名函数一致

- [ ] **Step 1: 改测试断言，让它失败**

把 `test/swarmforge/pack_ui_test.clj` 第 469-489 行的 `inject-master-records-send-keys-argv` 整个替换成：

```clojure
(deftest inject-master-records-send-keys-argv
  ;; Given master session swarmforge-specifier running codex in roles.tsv
  ;; When --test-inject-argv records the would-be tmux argv
  ;; Then it send-keys -l the text, then a raw carriage return — the same
  ;; encoding handoffd uses, because a symbolic C-m is re-encoded by tmux for a
  ;; TUI that negotiated extended keys and then never submits
  (let [root (tmp-dir)
        argv-file (str (fs/path root "tmux.argv"))
        sock (str (fs/path root "tmux.sock"))
        text "hello from operator"]
    (write-file
     (fs/path root ".swarmforge/roles.tsv")
     (str "specifier\tmaster\t" root "\tswarmforge-specifier\tSpecifier\tcodex\ttask\n"))
    (write-file (fs/path root ".swarmforge/tmux-socket") (str sock "\n"))
    (let [result (pack-web root false "--test-inject-argv" (str root) argv-file text)
          argv (read-argv argv-file)]
      (is (zero? (:exit result)))
      (is (= ["tmux" "-S" sock "send-keys" "-t" "swarmforge-specifier:Specifier.0" "-l" text]
             (first argv)))
      (is (= ["tmux" "-S" sock "send-keys" "-t" "swarmforge-specifier:Specifier.0" "-H" "0d"]
             (second argv)))
      (is (= 2 (count argv))))))
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
bb test
```

预期：FAIL，`(second argv)` 实际是 `[... "C-m"]`，且 `(count argv)` 是 3。

- [ ] **Step 3: 写最小实现**

在 `swarmforge/scripts/pack_web.bb` 的 `inject-master!` 上面加：

```clojure
(defn submit-keys
  "tmux send-keys arguments that make this agent's TUI submit its input line.
  Kept byte-identical to handoffd's copy: a symbolic key name is re-encoded by
  tmux for a TUI that negotiated extended keys and then never submits."
  [agent]
  (if (= agent "claude")
    [["-H" "1b" "5b" "31" "33" "75"]]
    [["-H" "0d"]]))
```

把 `inject-master!` 整个替换成：

```clojure
(defn inject-master! [root text]
  (try
    (let [socket (tmux-socket root)
          row (master-row root)
          target (when row (pane-target row))
          agent (nth row 5 "codex")]
      (when (and socket target (not (str/blank? text)))
        (send-keys! socket target "-l" text)
        (when-not (tmux-stub)
          (Thread/sleep 150))
        (doseq [keys (submit-keys agent)]
          (apply send-keys! socket target keys))))
    (catch Exception _)))
```

`roles.tsv` 的第 6 列（0-based index 5）是 agent，见 `handoffd.bb` 的 `load-roles`。

- [ ] **Step 4: 跑测试确认通过**

```bash
bb test
```

预期：全绿。`pack-web-post-task-injects-payload-into-master-session` 只断言 `(last (first argv))`，不受影响。

- [ ] **Step 5: 同步 SKILL.md 的 wake role 文档**

把 `.agents/skills/swarmforge-operator/SKILL.md` 第 135-141 行那段命令替换成：

```sh
tmux -S "$SOCK" send-keys -t "$SESSION" -l "ready_for_next.sh"
# 提交键按 backend 分：两支都发裸字节。符号键名（C-m/C-j）会过 tmux 的
# key-encoding 层，协商了 extended keys 的 TUI 收到的不是字面 Enter。
# claude：CSI-u Enter
tmux -S "$SOCK" send-keys -t "$SESSION" -H 1b 5b 31 33 75
# 其它 backend（codex、grok…）：裸回车
tmux -S "$SOCK" send-keys -t "$SESSION" -H 0d
```

- [ ] **Step 6: 验证 SKILL.md frontmatter 仍可解析**

```bash
python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]).read().split("---")[1])' \
  .agents/skills/swarmforge-operator/SKILL.md && echo OK
```

预期：打印 `OK`。（本 task 没动 frontmatter，但改过 SKILL.md 就跑一次，这是仓库纪律。）

- [ ] **Step 7: 提交**

```bash
git add swarmforge/scripts/pack_web.bb test/swarmforge/pack_ui_test.clj .agents/skills/swarmforge-operator/SKILL.md
git commit -m "fix(pack_web,skill): 注入与 wake role 文档同步改用裸回车提交键

同一份提交键此前复制在三处，只改 handoffd 会让 bug 从 dashboard 注入和人工
wake 两条路重新长出来。Refs #1"
```

---

### Task 5: #2 拆票 —— 把 alert 通道契约拆出去

#2 现在是 20 条 user story + 6 条实现契约。契约 6（`SWARMFORGE_ALERT_CMD` + hermes/healthchecks）跟 reconcile 的正确性正交，而且它自己写了「hermes CLI 实现前需在 macmini 实测一次」——一个未验证的外部依赖不该挡住核心逻辑合入。

无代码改动。

**Files:** 无

**Interfaces:**

- Consumes: 无
- Produces: 一张新 issue（alert 通道），以及 #2 上一条收窄范围的评论

- [ ] **Step 1: 开出 alert 通道的新票**

把下面这段写进 `/tmp/alert-issue.md`（避免在 shell 里转义 markdown）：

```markdown
## Problem Statement

handoffd 的 wake retry attempt cap 耗尽后只写 daemon log。8 小时不可见事故已经证明无人盯日志，所以 log 是 audit，不是 delivery。操作员在 MacBook、daemon 在 macmini，需要一条直达的通道。

从 #2 拆出：#2 只负责 reconcile 的正确性（重发直到领取），本票只负责「重试彻底失败后怎么让人知道」。

## Acceptance criteria

- [ ] handoffd 读 `SWARMFORGE_ALERT_CMD`；attempt cap 耗尽时以 `sh -c` 执行，命令失败只写 `log!` 不抛出（照 `terminal-ok?` 的 `:continue true` 模式）。
- [ ] 未设置该 env 时行为退化为只写 `log!`，不报错。
- [ ] 同一 handoff-id 只告警一次（去抖）。
- [ ] 告警命令的 stdout/stderr 写进 `log!`。
- [ ] 代码不绑定具体 IM：hermes / ntfy.sh / SMTP 均由操作者用 env 接。
- [ ] 定向回归测试：设 `SWARMFORGE_ALERT_CMD` 为写文件的命令，cap 耗尽后该文件存在且只写一次。

验收命令：`bb test`，判据是 `swarmforge.handoff-test` 里的 `handoffd-runs-the-alert-command-once-when-the-cap-is-spent` 变绿，其余全绿。

## 部署侧（操作者配置，非代码默认）

    SWARMFORGE_ALERT_CMD='hermes send --to <target> "swarmforge: handoff <id> unclaimed after N attempts"'

hermes CLI 需在 macmini 实测一次；不可用则换 ntfy.sh（`curl -d "..." ntfy.sh/<un-guessable-topic>`）。

## Out of scope

- healthchecks.io 死人开关、launchd KeepAlive 替代 nohup（加固项，另计）。
- reconcile 循环本身（#2）。

底稿：`docs/research/alert-channel-internal.md`、`docs/research/alert-channel-external.md`。
```

然后：

```bash
gh issue create -R arlishansenn/swarm-forge \
  --title "handoffd: attempt cap 耗尽时经 SWARMFORGE_ALERT_CMD 告警操作员" \
  --label ready-for-agent \
  --body-file /tmp/alert-issue.md
```

- [ ] **Step 2: 在 #2 上收窄范围并写死定向验收命令**

把下面这段写进 `/tmp/issue2-scope.md`：

```markdown
## 范围收窄 + 定向验收命令

契约 6（operator alert 投递通道）已拆到独立票。本票只做 reconcile 的正确性：契约 1–5 + 到期重发 + 领取即停。cap 耗尽在本票里的行为是**只写 `log! "wake-exhausted"` 并停止重试，文件留在 `inbox/new` 不动**。

验收命令（跑这一条，不要额外加范围）：

    bb test

判据：`swarmforge.handoff-test` 里下列 deftest 全绿——

- `handoffd-rewakes-a-handoff-left-unclaimed-in-inbox-new`
- `handoffd-does-not-rewake-a-handoff-already-claimed`
- `handoffd-leaves-the-original-file-as-the-only-payload`
- `handoffd-skips-wake-retries-for-a-busy-role`
- `handoffd-caps-wake-notifications-per-pass`
- `handoffd-keeps-unclaimed-work-in-inbox-new-when-the-wake-fails`
- `handoffd-stops-waking-after-the-attempt-cap`

外加人工确认三条红线：reconcile 路径不移动/复制/删除 `inbox/new` 文件；notify 失败不进 `failed/`；`capture-pane` 只影响日志。
```

然后：

```bash
gh issue comment 2 -R arlishansenn/swarm-forge --body-file /tmp/issue2-scope.md
```

---

### Task 6: #2 —— reconcile 最小闭环

`inbox/new` 里的文件就是「未领取」这个电平。到期重发同一条唤醒，直到 `ready_for_next` 把它移进 `in_process`。这一 task 只做：退避判定、重发、领取即停、绝不复制。

**Files:**

- Modify: `swarmforge/scripts/handoffd.bb`（顶部常量区、`poll-once!`）
- Test: `test/swarmforge/handoff_test.clj`

**Interfaces:**

- Consumes: Task 2 的 `(tmux! & argv)`、`(tmux-stub)`、`notify!`；测试助手 `read-argv`、`run-handoffd-once!`
- Produces:
  - `(retry-delay-ms attempts) => long`
  - `(attempts-from-age age-ms) => long`
  - `(due-attempt now-ms id enqueued-ms) => long | nil`
  - `(inbox-dir role-info state) => java.nio.file.Path`，`state` 为 `"new"` / `"in_process"`
  - `(handoff-files dir) => seq of Path`
  - `(wake-candidates roles now-ms) => seq of {:role-info :path :id :attempt}`
  - `(reconcile-once! roles socket) => nil`
  - daemon 日志新行：`wake-retry <id> attempt=<n>`

- [ ] **Step 1: 写失败的测试**

在 `test/swarmforge/handoff_test.clj` 末尾加助手和三条测试：

```clojure
(defn entry-count
  "Entries in dir, or 0 when the dir was never created. fs/glob on a missing
  directory is not portable across babashka.fs versions."
  [dir]
  (if (fs/exists? dir) (count (fs/list-dir dir)) 0))

(defn stalled-handoff!
  "A handoff that has sat unclaimed in a recipient's inbox/new since 2026-01-01,
  i.e. far past every retry delay."
  [root filename id]
  (put-handoff! root "new" filename
                {:id id :from "sender" :to "receiver" :recipient "receiver"
                 :priority "50" :type "message" :task "stalled"
                 :enqueued-at "2026-01-01T00:00:00Z"}))

(deftest handoffd-rewakes-a-handoff-left-unclaimed-in-inbox-new
  ;; Given a handoff that has sat in inbox/new past the first retry delay
  ;; When the daemon runs one pass
  ;; Then it re-sends the same wake hint, because the file is the level: a
  ;; keystroke the TUI swallowed leaves no other trace
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (stalled-handoff! root "50_20260101T000000Z_000010_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000010_from_sender")
    (run-handoffd-once! root argv-file)
    (let [argv (read-argv argv-file)]
      (is (= ["tmux" "-S" "/tmp/fake.sock" "send-keys" "-t" "session" "-l"
              "You have new handoff mail. If idle, run ready_for_next.sh."]
             (first argv)))
      (is (= ["tmux" "-S" "/tmp/fake.sock" "send-keys" "-t" "session" "-H" "0d"]
             (second argv))))))

(deftest handoffd-does-not-rewake-a-handoff-already-claimed
  ;; Given the same old handoff, but already moved to in_process by ready_for_next
  ;; When the daemon runs one pass
  ;; Then no wake is sent: the move is the authoritative claim acknowledgement
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (put-handoff! root "in_process" "50_20260101T000000Z_000011_from_sender_to_receiver.handoff"
                  {:id "20260101T000000Z_000011_from_sender"
                   :from "sender" :to "receiver" :recipient "receiver"
                   :priority "50" :type "message" :task "claimed"
                   :enqueued-at "2026-01-01T00:00:00Z"})
    (run-handoffd-once! root argv-file)
    (is (= [] (read-argv argv-file)))))

(deftest handoffd-leaves-the-original-file-as-the-only-payload
  ;; Given an unclaimed handoff woken twice
  ;; When two daemon passes run
  ;; Then inbox/new still holds exactly that one file: a retry re-notifies, it
  ;; never re-queues, and notification failure must never look like new work
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")
        new-dir (fs/path root ".swarmforge/handoffs/inbox/new")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (stalled-handoff! root "50_20260101T000000Z_000012_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000012_from_sender")
    (run-handoffd-once! root argv-file)
    (run-handoffd-once! root argv-file)
    (is (= 1 (count (fs/glob new-dir "*.handoff"))))
    (is (= 0 (entry-count (fs/path root ".swarmforge/handoffs/inbox/failed"))))))
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
bb test
```

预期：第一条 FAIL（`(first argv)` 是 `nil`，没有 reconcile 就不会重发）；第二、三条会 PASS——它们锁的是「不该发生的事」，现在恰好也不发生，作为后续 task 的回归锁保留。

- [ ] **Step 3: 写最小实现**

在 `swarmforge/scripts/handoffd.bb` 顶部 `(def wake-echo-interval-ms 100)` 下面加常量与状态：

```clojure
;; Retry ladder for handoffs still sitting unclaimed in a recipient's inbox/new.
;; Overridable constants, not standards: a swallowed keystroke must be re-sent,
;; but an agent that is simply slow must not be spammed every second.
(def retry-delays-ms [5000 15000 60000])
(def retry-interval-ms 300000)
(def retry-attempt-cap 12)

;; handoff id -> {:attempts n :last-ms t}. In memory only: a daemon restart costs
;; at most one extra idempotent wake, which is cheaper than a persistence surface
;; to maintain. Keyed by the id header, not the filename, because
;; move-with-collision renames files on delivery collisions.
(def retry-state (atom {}))
```

在 `outbox-files`（第 250 行）上面加 reconcile 相关函数：

```clojure
(defn parse-instant-ms [s]
  (try
    (.toEpochMilli (java.time.Instant/parse s))
    (catch Exception _ nil)))

(defn retry-delay-ms [attempts]
  (get retry-delays-ms attempts retry-interval-ms))

(defn attempts-from-age
  "Ladder position implied by how long a file has waited. Used when the daemon has
  no in-memory record, so a restart resumes the ladder instead of replaying
  5s/15s/60s from the top."
  [age-ms]
  (loop [n 0 spent 0]
    (let [d (retry-delay-ms n)]
      (if (or (>= n retry-attempt-cap) (< age-ms (+ spent d)))
        n
        (recur (inc n) (+ spent d))))))

(defn due-attempt
  "Attempt number to make now for an unclaimed handoff, or nil if it is not due
  yet or the cap is spent.

  With no in-memory record the clock starts at the file's own enqueued_at rather
  than at daemon start: after a restart the ladder resumes where it was."
  [now-ms id enqueued-ms]
  (if-let [{:keys [attempts last-ms]} (get @retry-state id)]
    (when (and (< attempts retry-attempt-cap)
               (>= (- now-ms last-ms) (retry-delay-ms attempts)))
      attempts)
    (let [age (- now-ms enqueued-ms)]
      (when (>= age (retry-delay-ms 0))
        (min (attempts-from-age age) (dec retry-attempt-cap))))))

(defn inbox-dir [role-info state]
  (fs/path (:worktree-path role-info) ".swarmforge" "handoffs" "inbox" state))

(defn handoff-files [dir]
  (if (fs/exists? dir)
    (->> (fs/list-dir dir)
         (filter #(and (fs/regular-file? %)
                       (str/ends-with? (fs/file-name %) ".handoff")))
         (sort-by #(fs/file-name %)))
    []))

(defn wake-candidates
  "Unclaimed handoffs due for a wake retry, oldest filename first."
  [roles now-ms]
  (->> (vals roles)
       (mapcat (fn [role-info]
                 (for [path (handoff-files (inbox-dir role-info "new"))
                       :let [headers (:headers (parse-message path))
                             id (get headers "id")
                             enqueued (parse-instant-ms (get headers "enqueued_at"))
                             attempt (when (and id enqueued)
                                       (due-attempt now-ms id enqueued))]
                       :when attempt]
                   {:role-info role-info :path path :id id :attempt attempt})))
       (sort-by #(fs/file-name (:path %)))))

(defn reconcile-once!
  "Re-send the wake hint for handoffs still sitting in a recipient's inbox/new.

  The wake hint is lossy: every agent TUI encodes Enter differently and a
  keystroke that lands mid-paste gets swallowed, which strands the chain with no
  log anomaly. The file in inbox/new is the level - it stays until
  ready_for_next moves it to in_process - so re-sending until it moves makes
  wake-up at-least-once instead of fire-and-forget. Never moves, copies, or
  deletes anything: a lost notification must never be mistaken for invalid work."
  [roles socket]
  (let [now-ms (System/currentTimeMillis)]
    (doseq [{:keys [role-info id attempt]} (wake-candidates roles now-ms)]
      (notify! socket (:session role-info) (:agent role-info))
      (swap! retry-state assoc id {:attempts (inc attempt) :last-ms now-ms})
      (log! "wake-retry" id (str "attempt=" attempt)))))
```

把 `poll-once!` 整个替换成（末尾接上 reconcile）：

```clojure
(defn poll-once! []
  (when-not (should-stop?)
    (let [roles (load-roles)
          socket (str/trim (slurp (str socket-file)))
          paths (->> (concat (mapcat #(or (outbox-files %) []) (vals roles))
                             (or (outbox-files {:worktree-path project-root}) []))
                     (map str)
                     distinct)]
      (doseq [path paths
              :while (not (should-stop?))]
        (try
          (process-outbox-file! roles socket path)
          (catch Exception e
            (log! "error" path (.getMessage e))
            (try
              (fail! (fs/path path) (.getMessage e))
              (catch Exception nested
                (log! "failed-to-archive" path (.getMessage nested)))))))
      ;; Guarded separately: a reconcile bug must never take delivery down with it.
      (try
        (reconcile-once! roles socket)
        (catch Exception e
          (log! "reconcile-error" (.getMessage e)))))))
```

- [ ] **Step 4: 跑测试确认通过**

```bash
bb test
```

预期：三条新测试全绿，既有测试不变。

- [ ] **Step 5: 提交**

```bash
git add swarmforge/scripts/handoffd.bb test/swarmforge/handoff_test.clj
git commit -m "feat(handoffd): 对未领取的 inbox/new handoff 做电平对账重发

唤醒是有损的，文件是电平：重发到文件被 ready_for_next 移进 in_process 为止。
绝不移动/复制/删除 inbox/new 文件。Refs #2"
```

---

### Task 7: #2 契约 1 与契约 3 —— busy 跳过与每 tick 通知预算

契约 1：角色的 `in_process` 非空时跳过它。排队中的第二件 handoff 是按设计等待，对它重试会把唤醒文本 + 提交键注射进正在工作的 agent 会话。

契约 3：`await-wake-echo!` 单次最多阻塞 `wake-echo-timeout-ms`（5s），`poll-once!` 单线程，十个积压条目会把 outbox→inbox 投递饿死 50s。重试路径既限流也不等 echo。

**Files:**

- Modify: `swarmforge/scripts/handoffd.bb`（`notify!`、`wake-candidates`、`reconcile-once!`、常量区）
- Test: `test/swarmforge/handoff_test.clj`

**Interfaces:**

- Consumes: Task 6 的 `reconcile-once!`、`wake-candidates`、`inbox-dir`、`retry-state`
- Produces:
  - `(notify! socket session agent)` 与 `(notify! socket session agent await?)` 两个 arity；`await? = false` 时跳过 `await-wake-echo!`
  - `(busy? role-info) => boolean`
  - `(distinct-by f coll) => vector`
  - 常量 `retry-notify-budget`

- [ ] **Step 1: 写失败的测试**

在 `test/swarmforge/handoff_test.clj` 末尾加：

```clojure
(deftest handoffd-skips-wake-retries-for-a-busy-role
  ;; Given a role already working one handoff and queuing a second
  ;; When the daemon runs one pass
  ;; Then no wake is sent: the queued file waits by design, and wake text
  ;; injected into a working agent corrupts its input line
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (put-handoff! root "in_process" "50_20260101T000000Z_000020_from_sender_to_receiver.handoff"
                  {:id "20260101T000000Z_000020_from_sender"
                   :from "sender" :to "receiver" :recipient "receiver"
                   :priority "50" :type "message" :task "working"
                   :enqueued-at "2026-01-01T00:00:00Z"})
    (stalled-handoff! root "50_20260101T000000Z_000021_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000021_from_sender")
    (run-handoffd-once! root argv-file)
    (is (= [] (read-argv argv-file)))))

(deftest handoffd-caps-wake-notifications-per-pass
  ;; Given three idle roles each holding one stalled handoff
  ;; When the daemon runs one pass
  ;; Then at most two are woken: poll-once! is single threaded, so an unbounded
  ;; retry backlog would push outbox->inbox delivery behind it
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"alpha" "task" "beta" "task" "gamma" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (doseq [[n role] [["30" "alpha"] ["31" "beta"] ["32" "gamma"]]]
      (put-handoff! root "new"
                    (str "50_20260101T000000Z_0000" n "_from_sender_to_" role ".handoff")
                    {:id (str "20260101T000000Z_0000" n "_from_sender")
                     :from "sender" :to role :recipient role
                     :priority "50" :type "message" :task "stalled"
                     :enqueued-at "2026-01-01T00:00:00Z"}))
    (run-handoffd-once! root argv-file)
    ;; two wakes, each recorded as one text send plus one submit key
    (is (= 4 (count (read-argv argv-file))))))
```

注意：`setup-project!` 给三个角色写的 `worktree-path` 都是 `root`，所以三个角色共享同一个 `inbox/new` 目录。同一个 id 因此会在 `wake-candidates` 里出现三次，实现必须按 id 去重后再限流，否则预算会被同一条 handoff 吃光。

- [ ] **Step 2: 跑测试确认它失败**

```bash
bb test
```

预期：`handoffd-skips-wake-retries-for-a-busy-role` FAIL（实际记到 2 行 argv）；`handoffd-caps-wake-notifications-per-pass` FAIL（实际是 18 行：3 个角色各扫到 3 个文件，9 次唤醒 × 2 行）。

- [ ] **Step 3: 写最小实现**

在 `swarmforge/scripts/handoffd.bb` 的常量区，`(def retry-attempt-cap 12)` 下面加：

```clojure
;; Wake retries per poll pass. poll-once! is single threaded, so an unbounded
;; retry backlog would push outbox->inbox delivery behind it.
(def retry-notify-budget 2)
```

把 `notify!` 改成两个 arity（整个替换 Task 2 写下的版本）：

```clojure
(defn notify!
  ([socket session agent] (notify! socket session agent true))
  ([socket session agent await?]
   (let [send-text (tmux! "-S" socket "send-keys" "-t" session "-l" wake-message)]
     (when-not (zero? (:exit send-text))
       (throw (ex-info "tmux send text failed" send-text)))
     ;; The echo wait covers the first-delivery race where a submit key lands
     ;; mid-paste. A retry must not wait: it can block up to
     ;; wake-echo-timeout-ms, and poll-once! is single threaded.
     (when (and await? (not (tmux-stub)))
       (await-wake-echo! socket session))
     (doseq [keys (submit-keys agent)]
       (let [result (apply tmux! (concat ["-S" socket "send-keys" "-t" session] keys))]
         (when-not (zero? (:exit result))
           (throw (ex-info "tmux send submit key failed" result)))
         (when-not (tmux-stub)
           (Thread/sleep 50)))))))
```

在 `parse-instant-ms` 上面加去重助手（babashka 没有内建 `distinct-by`）：

```clojure
(defn distinct-by [f coll]
  (:out (reduce (fn [{:keys [seen out]} x]
                  (let [k (f x)]
                    (if (contains? seen k)
                      {:seen seen :out out}
                      {:seen (conj seen k) :out (conj out x)})))
                {:seen #{} :out []}
                coll)))
```

在 `wake-candidates` 上面加：

```clojure
(defn busy?
  "True when this role is already working something. Its inbox/in_process holds
  both single handoffs and batch directories, so any entry counts."
  [role-info]
  (let [dir (inbox-dir role-info "in_process")]
    (and (fs/exists? dir) (boolean (seq (fs/list-dir dir))))))
```

把 `wake-candidates` 的第一行 `(->> (vals roles)` 改成两行：

```clojure
  (->> (vals roles)
       (remove busy?)
```

把 `reconcile-once!` 的 `doseq` 绑定改成去重 + 限流 + 不等 echo：

```clojure
    (doseq [{:keys [role-info id attempt]}
            (->> (wake-candidates roles now-ms)
                 (distinct-by :id)
                 (take retry-notify-budget))]
      (notify! socket (:session role-info) (:agent role-info) false)
      (swap! retry-state assoc id {:attempts (inc attempt) :last-ms now-ms})
      (log! "wake-retry" id (str "attempt=" attempt)))
```

- [ ] **Step 4: 跑测试确认通过**

```bash
bb test
```

预期：两条新测试 PASS，Task 6 的三条仍绿。

- [ ] **Step 5: 提交**

```bash
git add swarmforge/scripts/handoffd.bb test/swarmforge/handoff_test.clj
git commit -m "feat(handoffd): reconcile 跳过 busy 角色，重试限流且不等 echo

契约 1：in_process 非空说明 agent 在工作，重试会把唤醒文本注射进它的输入行。
契约 3：await-wake-echo! 单次可阻塞 5s，poll-once! 单线程，积压会饿死投递。
Refs #2"
```

---

### Task 8: #2 契约 2 与 cap —— 通知失败不隔离，cap 耗尽只告警

契约 2：reconcile 路径的 notify 抛错（tmux 瞬断、session 消失）只记日志 + 递增重试计数，下个 tick 再来。绝不复用 `poll-once!` 的 `fail!` → `failed/`——那会把合法的未领取工作隔离掉。

cap 耗尽后停止重试，文件永远留在 `inbox/new`。告警投递通道是 Task 5 拆出去的那张票。

**Files:**

- Modify: `swarmforge/scripts/handoffd.bb`（常量区、`reconcile-once!`）
- Test: `test/swarmforge/handoff_test.clj`

**Interfaces:**

- Consumes: Task 7 的 `reconcile-once!`、`busy?`、`distinct-by`、`retry-notify-budget`、`notify!` 的 4-arity
- Produces:
  - `(env-long name default) => long`
  - 常量读 env override：`SWARMFORGE_WAKE_RETRY_MS`、`SWARMFORGE_WAKE_ATTEMPT_CAP`、`SWARMFORGE_WAKE_BUDGET`
  - `(wake-exhausted! id attempts) => nil`
  - daemon 日志新行：`wake-retry-failed <id> <message>`、`wake-exhausted <id> attempts=<n>`

- [ ] **Step 1: 写失败的测试**

在 `test/swarmforge/handoff_test.clj` 末尾加：

```clojure
(deftest handoffd-keeps-unclaimed-work-in-inbox-new-when-the-wake-fails
  ;; Given a stalled handoff and a tmux socket with no server behind it, so the
  ;; real tmux call fails
  ;; When the daemon runs one pass with no stub
  ;; Then the file stays in inbox/new and nothing lands in failed/: a lost
  ;; notification is not invalid work
  (let [root (tmp-dir)
        new-dir (fs/path root ".swarmforge/handoffs/inbox/new")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket")
                (str (fs/path root "no-such.sock") "\n"))
    (stalled-handoff! root "50_20260101T000000Z_000040_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000040_from_sender")
    (run {:dir root} "bb" (script "handoffd.bb") "--once" (str root))
    (is (= 1 (count (fs/glob new-dir "*.handoff"))))
    (is (= 0 (entry-count (fs/path root ".swarmforge/handoffs/inbox/failed"))))
    (is (= 0 (entry-count (fs/path root ".swarmforge/handoffs/failed"))))
    (is (str/includes? (read-file (fs/path root ".swarmforge/daemon/handoffd.log"))
                       "wake-retry-failed"))))

(deftest handoffd-stops-waking-after-the-attempt-cap
  ;; Given a one-attempt cap and a 200ms retry interval
  ;; When the daemon runs long enough for several passes
  ;; Then it wakes once, logs wake-exhausted once, and leaves the file in place
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")
        log-file (fs/path root ".swarmforge/daemon/handoffd.log")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (stalled-handoff! root "50_20260101T000000Z_000041_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000041_from_sender")
    (run {:dir root :ok? false}
         "sh" "-c"
         (str "SWARMFORGE_TMUX_STUB=" argv-file
              " SWARMFORGE_WAKE_ATTEMPT_CAP=1 SWARMFORGE_WAKE_RETRY_MS=200"
              " bb " (script "handoffd.bb") " " root " >/dev/null 2>&1 &"))
    (Thread/sleep 3000)
    (run {:dir root} (script "stop_handoff_daemon.bb") (str root))
    (Thread/sleep 300)
    (let [log (read-file log-file)]
      (is (= 1 (count (re-seq #"wake-retry " log))))
      (is (= 1 (count (re-seq #"wake-exhausted " log))))
      (is (= 1 (count (fs/glob (fs/path root ".swarmforge/handoffs/inbox/new") "*.handoff")))))))
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
bb test
```

预期：第一条 FAIL——`reconcile-once!` 抛出的异常被 `poll-once!` 外层 catch 成 `reconcile-error`，日志里没有 `wake-retry-failed`。第二条 FAIL——没有 env override，`SWARMFORGE_WAKE_ATTEMPT_CAP` 不起作用，`wake-exhausted` 行不存在。

- [ ] **Step 3: 写最小实现**

把 `swarmforge/scripts/handoffd.bb` 常量区里 Task 6/7 写下的四行退避常量整块替换成可 env override 的版本：

```clojure
(defn env-long [name default]
  (or (some-> (System/getenv name) parse-long) default))

;; Retry ladder for handoffs still sitting unclaimed in a recipient's inbox/new.
;; Overridable constants, not standards: a swallowed keystroke must be re-sent,
;; but an agent that is simply slow must not be spammed every second.
;; SWARMFORGE_WAKE_RETRY_MS collapses the ladder to one interval; tests use it to
;; observe several passes without waiting out the real schedule.
(def retry-delays-ms
  (if-let [flat (env-long "SWARMFORGE_WAKE_RETRY_MS" nil)]
    [flat]
    [5000 15000 60000]))
(def retry-interval-ms (env-long "SWARMFORGE_WAKE_RETRY_MS" 300000))
(def retry-attempt-cap (env-long "SWARMFORGE_WAKE_ATTEMPT_CAP" 12))
(def retry-notify-budget (env-long "SWARMFORGE_WAKE_BUDGET" 2))
```

在 `reconcile-once!` 上面加：

```clojure
(def alerted (atom #{}))

(defn wake-exhausted!
  "Record that nobody claimed this handoff after the cap. The work stays in
  inbox/new forever on purpose: quarantine is for malformed outbound handoffs,
  never for work whose notification failed. Delivering this to a human is a
  separate concern - see the SWARMFORGE_ALERT_CMD ticket."
  [id attempts]
  (when-not (contains? @alerted id)
    (swap! alerted conj id)
    (log! "wake-exhausted" id (str "attempts=" attempts))))
```

把 `reconcile-once!` 整个替换成：

```clojure
(defn reconcile-once!
  "Re-send the wake hint for handoffs still sitting in a recipient's inbox/new.

  The wake hint is lossy: every agent TUI encodes Enter differently and a
  keystroke that lands mid-paste gets swallowed, which strands the chain with no
  log anomaly. The file in inbox/new is the level - it stays until
  ready_for_next moves it to in_process - so re-sending until it moves makes
  wake-up at-least-once instead of fire-and-forget. Never moves, copies, or
  deletes anything: a lost notification must never be mistaken for invalid work."
  [roles socket]
  (let [now-ms (System/currentTimeMillis)]
    (doseq [{:keys [role-info id attempt]}
            (->> (wake-candidates roles now-ms)
                 (distinct-by :id)
                 (take retry-notify-budget))]
      (try
        (notify! socket (:session role-info) (:agent role-info) false)
        (log! "wake-retry" id (str "attempt=" attempt))
        (catch Exception e
          ;; Log and count, then come back next tick. Routing this through fail!
          ;; would quarantine legitimate unclaimed work.
          (log! "wake-retry-failed" id (.getMessage e))))
      (let [attempts (inc attempt)]
        (swap! retry-state assoc id {:attempts attempts :last-ms now-ms})
        (when (>= attempts retry-attempt-cap)
          (wake-exhausted! id attempts))))))
```

- [ ] **Step 4: 跑测试确认通过**

```bash
bb test
```

预期：两条新测试 PASS，Task 6 与 Task 7 的五条仍绿。第二条测试耗时约 3.5 秒。

- [ ] **Step 5: 人工核对三条红线**

```bash
grep -n "fs/move\|fs/copy\|fs/delete\|fail!" swarmforge/scripts/handoffd.bb
```

预期：`reconcile-once!`、`wake-candidates`、`wake-exhausted!`、`busy?`、`handoff-files` 这几个函数体内**一处都不出现**上述调用。`pane-text` 的返回值只流向 `await-wake-echo!`，而 reconcile 路径传 `await? = false`，因此 `capture-pane` 不影响任何持久状态。

- [ ] **Step 6: 提交并关票**

```bash
git add swarmforge/scripts/handoffd.bb test/swarmforge/handoff_test.clj
git commit -m "feat(handoffd): 唤醒失败只记日志不隔离，cap 耗尽停重试并留档

契约 2：notify 抛错走 log! + 计数，下个 tick 再来；绝不复用 fail! → failed/，
那会把合法的未领取工作隔离掉。cap 耗尽后文件永远留在 inbox/new。Closes #2"
```

---

### Task 9: #3 —— onboard project 降级实现

原 spec 是 12 条 user story + 独立 test suite + curl/ssh 双 stub + 本地远端双测试矩阵，而动词本体是一条 `curl | tar`。真正值得编码的只有两个守卫：拒绝 `main`（upstream 明令禁止，误装会污染项目）和目标非空时零写入拒绝。

**如果决定关掉 #3，跳过本 task**，改为在 README 贴那一行 curl 并 `gh issue close 3`。

**Files:**

- Create: `.agents/skills/swarmforge-operator/scripts/onboard-project.sh`
- Create: `.agents/skills/swarmforge-operator/scripts/test-onboard-project.sh`
- Modify: `.agents/skills/swarmforge-operator/SKILL.md`
- Modify: `README.md`

**Interfaces:**

- Consumes: 无（与既有动词共享 `--root` / `--target` / `--key` / `--local` 参数惯例，见 `open-swarm.sh:16-25`）
- Produces: `onboard-project.sh --root <dir> --pack <two-pack|four-pack|six-pack> [--target|--key|--local]`，STATUS 行与退出码：`0 ONBOARDED`、`2 USAGE`、`4 OCCUPIED`、`5 ERROR`

- [ ] **Step 1: 写失败的测试**

创建 `.agents/skills/swarmforge-operator/scripts/test-onboard-project.sh`：

```bash
#!/usr/bin/env bash
# test-onboard-project.sh — checks for onboard-project.sh against a stubbed curl.
# Run: bash scripts/test-onboard-project.sh. Exits non-zero on any failure.
# Only the two guards worth encoding are tested: the pack whitelist and refusing
# a non-empty target. The happy path is one curl | tar; the stub proves it lands.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/onboard-project.sh
WORK=$(mktemp -d /tmp/sf-onboard-test.XXXXXX)
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

# ---------- fixture tarball: one dir holding a swarm launcher + swarmforge/ ----
mkdir -p "$WORK/bin" "$WORK/src/pack-root/swarmforge"
echo '#!/bin/sh' > "$WORK/src/pack-root/swarm"
echo 'roles' > "$WORK/src/pack-root/swarmforge/roles.txt"
tar -czf "$WORK/pack.tgz" -C "$WORK/src" pack-root

# ---------- stub curl: -o <file> gets the fixture, or fails on demand ---------
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
[ -n "${CURL_FAILS:-}" ] && exit 22
out=''
while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift 2 ;; *) shift ;; esac; done
cp "$FIXTURE" "$out"
EOF
chmod +x "$WORK/bin/curl"
export PATH=$WORK/bin:$PATH FIXTURE=$WORK/pack.tgz

echo "onboard-project.sh"

# 1. happy path lands the pack
T=$WORK/proj-ok
out=$("$SCRIPT" --root "$T" --pack six-pack --local 2>&1); rc=$?
check "six-pack exits 0" 0 "$rc"
check "six-pack STATUS" "STATUS=ONBOARDED" "$(echo "$out" | head -1)"
check "swarm launcher landed" "yes" "$([ -f "$T/swarm" ] && echo yes || echo no)"
check "swarmforge/ landed" "yes" "$([ -d "$T/swarmforge" ] && echo yes || echo no)"

# 2. main is refused
T=$WORK/proj-main
"$SCRIPT" --root "$T" --pack main --local >/dev/null 2>&1; rc=$?
check "main exits 2" 2 "$rc"
check "main writes nothing" "no" "$([ -e "$T" ] && echo yes || echo no)"

# 3. unknown pack is refused
T=$WORK/proj-bogus
"$SCRIPT" --root "$T" --pack seven-pack --local >/dev/null 2>&1; rc=$?
check "unknown pack exits 2" 2 "$rc"

# 4. occupied target is refused with zero writes
T=$WORK/proj-occupied; mkdir -p "$T"; echo keepme > "$T/swarm"
out=$("$SCRIPT" --root "$T" --pack six-pack --local 2>&1); rc=$?
check "occupied exits 4" 4 "$rc"
check "occupied STATUS" "STATUS=OCCUPIED" "$(echo "$out" | head -1)"
check "occupied file untouched" "keepme" "$(cat "$T/swarm")"

# 5. download failure leaves no half-installed tree
T=$WORK/proj-netfail
CURL_FAILS=1 "$SCRIPT" --root "$T" --pack six-pack --local >/dev/null 2>&1; rc=$?
check "download failure exits 5" 5 "$rc"
check "download failure leaves nothing" "0" "$(ls -A "$T" 2>/dev/null | wc -l | tr -d ' ')"

echo "  $PASS passed, $FAIL failed"
rm -rf "$WORK"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
bash .agents/skills/swarmforge-operator/scripts/test-onboard-project.sh
```

预期：全部 FAIL —— `onboard-project.sh` 还不存在。

- [ ] **Step 3: 写最小实现**

创建 `.agents/skills/swarmforge-operator/scripts/onboard-project.sh`：

```bash
#!/usr/bin/env bash
# onboard-project.sh — install an upstream SwarmForge pack into a project dir.
#
# Exit codes / STATUS line:
#   0 ONBOARDED   2 USAGE   4 OCCUPIED   5 ERROR
# Contract details live in ../SKILL.md (verb: onboard project).
# Never starts a swarm, never runs git. Depends on bash, curl, tar.
set -euo pipefail

TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
ROOT='' PACK='' LOCAL=0

while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT=$2; shift 2 ;;
    --pack) PACK=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
    *) sed -n '2,7p' "$0"; exit 2 ;;
  esac
done
[ -n "$ROOT" ] && [ -n "$PACK" ] || { sed -n '2,7p' "$0"; exit 2; }

# upstream README: main is the documentary branch, never a pack. Encoding that
# rule here is the whole reason this script exists instead of a pasted curl.
case $PACK in
  two-pack|four-pack|six-pack) ;;
  *) printf 'STATUS=USAGE\n%s\n' \
       "pack must be two-pack, four-pack or six-pack — never main" >&2
     exit 2 ;;
esac

URL=https://github.com/unclebob/swarm-forge/tarball/$PACK

remote() {
  if [ "$LOCAL" = 1 ]; then bash -c "$1"; else ssh -i "$KEY" "$TARGET" "$1"; fi
}

if remote "test -e '$ROOT/swarm' || test -e '$ROOT/swarmforge'"; then
  printf 'STATUS=OCCUPIED\n%s\n' \
    "$ROOT already has swarm or swarmforge/ — refusing to overwrite"
  exit 4
fi

# Download and verify into a temp dir first, so a failed transfer never leaves a
# half-extracted tree that a rerun would then refuse as OCCUPIED.
if ! remote "set -e
  tmp=\$(mktemp -d)
  trap 'rm -rf \"\$tmp\"' EXIT
  curl -fsSL '$URL' -o \"\$tmp/pack.tgz\"
  tar -tzf \"\$tmp/pack.tgz\" >/dev/null
  mkdir -p '$ROOT'
  tar -xzf \"\$tmp/pack.tgz\" --strip-components=1 -C '$ROOT'"; then
  printf 'STATUS=ERROR\n%s\n' "download or extract of $PACK failed; $ROOT unchanged" >&2
  exit 5
fi

printf 'STATUS=ONBOARDED\n'
remote "ls -1 '$ROOT'"
printf 'next: run ./swarm in %s yourself — this script never starts a swarm\n' "$ROOT"
```

设可执行位：

```bash
chmod +x .agents/skills/swarmforge-operator/scripts/onboard-project.sh
chmod +x .agents/skills/swarmforge-operator/scripts/test-onboard-project.sh
```

- [ ] **Step 4: 跑测试确认通过**

```bash
bash .agents/skills/swarmforge-operator/scripts/test-onboard-project.sh
```

预期：`11 passed, 0 failed`。

- [ ] **Step 5: 加 SKILL.md verb 节**

在 `.agents/skills/swarmforge-operator/SKILL.md` 的 `## Verb: open swarm` 那一节之前插入下面这段（含代码块）：

````markdown
## Verb: `onboard project`

把 upstream 的一个 pack 装进一个 managed project 目录。这是 skill 里唯一的创建性
动词：它只负责落盘，装完即止。

```sh
scripts/onboard-project.sh --root <项目目录> --pack <two-pack|four-pack|six-pack> [--local]
```

退出码与 STATUS 行：`0 ONBOARDED`、`2 USAGE`（缺参数、或 pack 不在白名单——
`main` 是 upstream 的 documentary branch，永远不是 pack）、`4 OCCUPIED`（目标已有
`swarm` 或 `swarmforge/`，零写入拒绝）、`5 ERROR`（下载或解压失败，目标不变）。

**边界**：onboard 之后**不要**替用户跑 `./swarm`。三条硬禁令原封不动：不启动、
不清理、不代替用户决定启动时机。脚本也不碰目标项目的 git 状态——`git init` 是
swarm launcher 首跑自己的行为。
````

- [ ] **Step 6: 验证 frontmatter 仍可解析并更新 README**

```bash
python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]).read().split("---")[1])' \
  .agents/skills/swarmforge-operator/SKILL.md && echo OK
```

预期：打印 `OK`。

把 `README.md:335` 的 `### 八个 verb` 改成 `### 九个 verb`，并在表格里 `accept work` 行之前插入：

```markdown
| `onboard project` | 把 upstream 的 two-pack/four-pack/six-pack 装进一个项目目录；拒绝 `main`，目标非空时零写入拒绝；装完不启动 |
```

- [ ] **Step 7: 提交并关票**

```bash
git add .agents/skills/swarmforge-operator/scripts/onboard-project.sh \
        .agents/skills/swarmforge-operator/scripts/test-onboard-project.sh \
        .agents/skills/swarmforge-operator/SKILL.md README.md
git commit -m "feat(skill): swarmforge-operator 新增 onboard project 动词

动词本体是一条 curl | tar；值得编码的是两个守卫：拒绝 main、目标非空时零写入
拒绝。原 spec 的 12 条 user story 与双路径测试矩阵按实际价值缩减。Closes #3"
```

---

## 执行完成后的全量验证

```bash
bb test \
  && bash .agents/skills/swarmforge-operator/scripts/test-open-swarm.sh \
  && bash .agents/skills/swarmforge-operator/scripts/test-open-dashboard.sh \
  && bash .agents/skills/swarmforge-operator/scripts/test-onboard-project.sh
```

`bb test` 必须全绿；三个 skill 测试各自打印 `0 failed`。

## 遗留项（本计划不覆盖）

- **六包实机验证**：#1 的验收标准第 5 条要求「A live six-pack check demonstrates automatic pickup by an idle Codex role」。stub 测试锁的是发出去的字节，锁不了真 TUI 是否接受。合入后需在 macmini 跑一次真实六包链，观察 idle codex 角色自动领取。
- **三处部署点同步**：#2 正文要求实现后同步本地 clone、podsum 与 pi-governance 的 script snapshot。
- **claimed-but-crashed 的 lease/heartbeat 恢复**：#2 明确列为 out of scope，另一个状态机、另一张票。
- **alert 投递通道**：Task 5 拆出的新票，实现前需在 macmini 实测 hermes CLI。
