# Research: SwarmForge 内部 alerting/escalation 现状（issue #2 operator alert 通道选型依据）

---

**一句话**：仓库内不存在任何「推送到人」的通道，现有 escalation 惯例是 watchdog 式「strike 阈值 → 自行动作（恢复或拆除）→ 仅写 log」，人能看见的唯一途径是 operator skill 的手动 `read swarm` 轮询和 pull-only dashboard（8 小时不可见事故已证明不足）；最贴合现有惯例的适配是 handoffd 在 attempt cap 处执行一个 env-var 配置的 alert command（`SWARMFORGE_*` env 模式已有 7 个先例），`osascript display notification` 是仓库已验证依赖上的一行式本机兜底。

---

## Summary

研究范围为只读。逐个读取了任务点名的 7 处位置，外加 pack_web.bb 全文、handoff-protocol.md 全文、ready_for_next_task.bb、done_with_current_task.bb、swarm_tool.sh。结论：SwarmForge 的「escalation」目前全部是机器自愈（watchdog reopen window / kill-all-sessions），alerting 目前全部是文件与 stdout（handoffd.log、window-watchdog.log），不存在 email/webhook/osascript notification/IM 的任何 wiring。配置面成熟的是 env-var（`SWARMFORGE_*`），不是 swarmforge.conf（该文件每行被严格校验为 window 定义，无扩展指令）。外部候选（hermes、podsum SMTP）在本仓库与本机均不可验证，只能作为 task 声明的 runtime fact 参与评估。

## Findings

### A. 现有 escalation 模式（该设计应模仿的「内部标准」）

**1 → handoffd 的 append-only log 是唯一的持久记录面。** `swarmforge/scripts/handoffd.bb:41-45` 定义 `log!`：把 `<ISO-8601> <parts>` 追加到 `log-file`（`handoffd.bb:34` = `<project-root>/.swarmforge/daemon/handoffd.log`）。`deliver!`、`fail!`（`:155-159`，写 `.error` 边车文件并移入 `failed/`）、`hold!`（`:192-194`，移入 `pending_approval/`）、daemon start/stop 全走它。已在使用：所有 handoff 生命周期事件。适配成本：**零**（attempt-cap 事件照写一行即可），但正是 8 小时不可见的通道，只能作 audit 层，不能当 delivery。

**2 → watchdog 的 strike 机制 = 「阈值 → 动作 → log」，从不通知人。** `swarmforge/scripts/swarm-window-watchdog.bb:8` `(def missing-threshold 3)`；`log!` 在 `:10-12` 仅 `println` 到 stdout（由 swarmforge.bb `start-window-watchdog!` 重定向进 `.swarmforge/window-watchdog.log`）。阈值命中后做什么：普通 role window 连续 3 次缺失 → 调 `terminal_open_session` 重开窗口并改写 window-id（`window-reopened` log，`:123-136` 一带）；cleanup-owner window 3 次缺失 → `kill-all-sessions!`（`:79-91`：log `KILL-ALL-SESSIONS`、停 handoff daemon、杀全部 tmux session、关全部 Terminal 窗口）。已在使用：每次 `./swarm` 启动即拉起（swarmforge.bb `start-window-watchdog!`）。适配成本：**模式免费**（reconcile 的 capped retry + attempt 计数就是照它改的，blueprint 已声明 adapt）；它缺失的恰是「通知人」这一步，任何 delivery channel 都是新代码。

**3 → swarm-cleanup.sh 与 close-swarm 无任何 notification hook。** `swarmforge/scripts/swarm-cleanup.sh`（全文 51 行）：archive-all board → 停 daemon → 杀 session → 关窗口，每步 `|| true`，唯一 env 是 `SWARMFORGE_TERMINAL_BACKEND`（`:11`）。仓库根 `close-swarm`：解析路径、把 `SWARMFORGE_TERMINAL` 透传成 `SWARMFORGE_TERMINAL_BACKEND`（`:~58-60`）、exec swarm-cleanup.sh，错误只 echo 到 stderr。适配成本：不适用——拆除路径不需要 alert，但证明「静默收尾」是本仓库惯例，别在这里找 hook。

### B. 已存在的通知类通道（按可用性排序）

**4 → osascript 是仓库内唯一 wired 的「通知类」依赖，但只用于控窗口，从未发过 notification。** `swarmforge/scripts/terminal-adapters/terminal-app.sh`：`terminal_window_exists`（`:15-38`）、`terminal_open_session`（`:~36-56`）、`terminal_close_window`（`:~58-70`）全部是 `osascript <<'APPLESCRIPT'` heredoc 驱动 Terminal.app。已在使用：macmini 生产后端默认就是 terminal-app（`detect_terminal_backend`：有 osascript 且非 iTerm → terminal-app），macmini 上有活跃 GUI session（Terminal 窗口就开在里面）。适配成本：**一行**：`osascript -e 'display notification "..." with title "SwarmForge"'`，handoffd 已 import `clojure.java.shell/sh`（`handoffd.bb:5`），照 `terminal-ok?` 的 `{:continue true}` 模式调用即可。局限：只到达看得见 macmini 屏幕的人，而操作者平时在 MacBook 上。

**5 → `.swarmforge/notify/` 是现成的文件 dropbox，但方向是人→agent。** 写入方：`pack_web.bb:353-357` `write-reject-notify!`——dashboard 上 reject 一个 approval 时，往 `<root>/.swarmforge/notify/reject-<task>` 写 `rejected`（`reject!` 在 `:363` 调它）。目录本身由 swarmforge.bb `prepare-workspace!`（`:notify-dir`）和 `sync-worktree-scripts!`（每个 worktree 建 `.swarmforge/notify/`）创建。消费方：未定位——`ready_for_next_task.bb` 不读它，推测由 role prompt 约定（未读 roles/*.prompt，见 Gaps）。适配成本：daemon 写一个 `alert-<handoff-id>` marker 是零新概念，但没人 watch 这个目录，可见性与 log 相同；若要让 dashboard 展示，需扩 `dashboard-state`（pack_web.bb）+ 前端，且仍是 pull。

**6 → dashboard（pack_web）是操作者现有的 pull 面，无任何 push。** `pack_web.bb` `serve!` 绑 `127.0.0.1`（macmini 本地，操作者经 SKILL.md 的 dashboard verb 建 SSH tunnel 访问）；路由仅 GET `/`、`/api/state`、`/api/agents/<role>/pane`、`/doc`，POST `/api/tasks`、`/api/chat`、`/api/teardown`、`/api/approvals/...`。无出站 HTTP、无轮询回调。适配成本：把「unclaimed 超时」加进 `/api/state` 的 `work_in_flight` 很自然，但解决不了「没人开着 dashboard」的根本问题，只能作辅助展示层。

**7 → 全仓搜索结果：terminal-notifier / notify-send / webhook / curl POST / slack / feishu / dingtalk / email / smtp / hermes 均为 0 命中。** 覆盖已读全集：handoffd.bb、swarmforge.bb、swarm-window-watchdog.bb、swarm-cleanup.sh、close-swarm、swarm-terminal-adapter.sh、terminal-adapters/terminal-app.sh、pack_web.bb（全文）、handoff-protocol.md、ready_for_next_task.bb、done_with_current_task.bb、swarm_tool.sh、swarmforge-operator SKILL.md、docs/research blueprint、docs/agents/domain.md。注：本 subagent 工具集无 grep/ls，这是穷举式读取而非真正的全仓 grep；roles/*.prompt 与少数 helper（pack_board、swarm_handoff、handoff_lib 等）未逐个读，但它们是 agent 侧工具，不是 operator-facing 通道，风险低。

### C. 操作者今天如何配置一个 alert 命令（hook 点评估）

**8 → swarmforge.conf 没有扩展位；env-var 才是既有的 operator-config 惯例。** conf 格式（handoff-protocol.md「Role Receive Mode」+ swarmforge.bb `parse-window-line`/`validate-window!`）：每行 `window|window-invisible <role> <agent> <worktree> [task|batch] [extra-cli-args...]`，未知 directive 直接 `config-fail!`。没有 alert/notify 指令，加一个要动 parser + validation + 文档，成本中等。对照 env 面：`SWARMFORGE_TERMINAL`、`SWARMFORGE_TERMINAL_BACKEND`、`SWARMFORGE_PREVENT_SLEEP`、`SWARMFORGE_OPEN_BROWSER`、`SWARMFORGE_AGENT_START_DELAY_MS`（经 `env-long`，`swarmforge.bb:29-34`）、`SWARMFORGE_ROLE`、`SWARMFORGE_TMUX_STUB`——全是「env + 内置默认值、进程启动时读一次」。**新增 `SWARMFORGE_ALERT_CMD`（或同族）完全落在这个惯例上**：handoffd 在 attempt cap 处 `sh` 执行它（照 `terminal-ok?` 的 continue 模式，~10 行），未设置时退化为 `log!` + 可选 osascript。hermes/smtp/任何通道都由操作者用 env 接，代码不绑定具体 IM。

**9 → 注入点与生效路径已明确。** handoffd 由 swarmforge.bb `start-handoff-daemon!` 从启动它的 checkout 拉起（`sync-worktree-scripts!` 在每次 `./swarm` 启动时把 scripts 快照进各 worktree，所以改 handoffd.bb 后需重启 swarm 才全面生效）。另外 `sleep-inhibitor-prefix`（swarmforge.bb，默认 `caffeinate -dims`，除非 `SWARMFORGE_PREVENT_SLEEP=0`）保证 daemon 在夜间不被 host sleep 冻结——attempt-cap 时刻的 alert 不会因休眠丢失。

### D. 操作者现实（de-facto alerting 是手动轮询）

**10 → SKILL.md 证实：操作者在 MacBook 上 SSH 到 macmini，`read swarm` 就是当前的 alerting。** `.agents/skills/swarmforge-operator/SKILL.md`「Runtime inputs」：`TARGET=admin@100.100.100.4` 形态的 Tailscale SSH（原文 `admin@100.64.0.4`，key `~/.ssh/tailscale_key`）。`read swarm` verb：遍历 sessions.tsv，逐 role `tmux capture-pane -S -12 | tail -1`，判定「empty prompt = idle，Working = busy，idle 角色上挂着 handoff-mail 提示 = 需要 `wake role`」。`wake role` verb 就是人工版 wake-hint（backend-specific submit key 与 handoffd `submit-keys` 同一套）。这就是 stuck chain 8 小时不可见的机制性原因：唯一告警路径依赖人主动发起 pull。适配成本：不适用（这是要被修的现状），但它确认了 alert 必须推到 MacBook 可感知的通道（通知/IM/email），而不是 macmini 本机屏幕或日志文件。

### E. 外部候选（本仓库不可验证，只按 task 声明评估）

**11 → hermes（`hermes send --to <target>`，gateway 在 msb7）：仓库内零引用。** 上述已读文件里没有出现 `hermes`。作为 task 声明的 runtime fact：若 CLI 在 macmini 的 PATH 上，适配成本是 handoffd 里一个 `sh` 调用，且是唯一可能直达操作者手机/聊天端的通道。**未验证项，设计引用时须标注。**

**12 → podsum SMTP adapter：给定路径本机不存在。** `/Users/admin/project/podsum/outputs/podsum_core/delivery/smtp_adapter.py` 读取结果 ENOENT（本机该路径无此文件，可能仅存在于 macmini 或别的 worktree）。无法核实 `send_smtp_email` 的签名与配置方式。若采用，成本 = 移植 adapter 或 shell 出去调用，外加 SMTP 凭据管理，重于 hermes/osascript 两条路。

**13 → .worktrees 内的 pi-governance / podsum 快照：无法枚举。** 本 subagent 工具集没有 ls/grep，`.worktrees/` 目录内容不可列举；已探测路径均未命中。按「未发现」处理，不下结论。

### F. 给设计的综合建议（按内部惯例贴合度排序）

**1 → `log!` 必写**（handoffd.bb:41-45，零成本，audit 层）。
**2 → `SWARMFORGE_ALERT_CMD` env hook 作为主通道**（贴合 7 个 `SWARMFORGE_*` 先例；hermes/SMTP/任意命令由操作者接；未设置则静默降级）。
**3 → osascript `display notification` 本机兜底**（terminal-app.sh 已证明 osascript 可用且 GUI session 存在；一行）。
**4 → 可选：`/api/state` 暴露 unclaimed 年龄**，让 dashboard `read swarm`/dashboard verb 顺带可见（仍为 pull，仅辅助）。
不推荐：往 `.swarmforge/notify/` 写 marker 当「告警」（没人消费，同 log 可见性）；改 swarmforge.conf 加 alert 指令（parser 成本高且 env 惯例已存在）。

## Sources

- Kept（全部一手、逐行读过）：
  - `swarmforge/scripts/handoffd.bb` — log!/log-file/notify!/fail!/hold! 与 poll loop，alert 注入点。
  - `swarmforge/scripts/swarm-window-watchdog.bb` — strike 阈值与「动作而非通知」的 escalation 惯例。
  - `swarmforge/scripts/swarm-cleanup.sh` + 根目录 `close-swarm` — 拆除路径无 hook 的反证。
  - `swarmforge/scripts/swarm-terminal-adapter.sh` + `terminal-adapters/terminal-app.sh` — osascript 依赖与 SWARMFORGE_TERMINAL env。
  - `swarmforge/scripts/swarmforge.bb` — conf parser、env-long、daemon/watchdog 启动与日志重定向、notify dir 创建、caffeinate。
  - `swarmforge/scripts/pack_web.bb`（全文）— write-reject-notify!、dashboard 路由面、127.0.0.1 绑定。
  - `swarmforge/handoff-protocol.md` — conf 格式、wake-up「intentionally lossy」、daemon runtime files 仅 pid/log/stop。
  - `swarmforge/scripts/ready_for_next_task.bb`、`done_with_current_task.bb`、`swarm_tool.sh` — agent 侧 helper 无通知通道。
  - `.agents/skills/swarmforge-operator/SKILL.md` — 操作者拓扑（MacBook→SSH→macmini）与手动轮询现状。
  - `docs/research/handoff-reconciliation-standards.md` — 被研究的 blueprint 本身。
  - `docs/agents/domain.md` — 排除 domain doc 含 hermes/notify 的可能。
- Dropped：
  - 无 web 检索来源（纯内部研究，未调用 web_search）。
  - `~/project/podsum/.../smtp_adapter.py` — ENOENT，读不到，不作证据。

## Gaps

- **hermes CLI 无法验证**：不能 ssh macmini；仓库内无引用。设计若依赖它，需要操作者先在 macmini 上跑一次 `hermes send` 验证。
- **podsum SMTP adapter 内容未读到**：路径在本机不存在；其配置面（凭据、收件人）未知。
- **`.swarmforge/notify/` 的消费方未定位**：`ready_for_next_task.bb` 不读它；最可能在 `swarmforge/roles/*.prompt` 里约定，本轮未读 roles 目录。
- **.worktrees 快照未枚举**：无 ls/grep 工具，pi-governance/podsum 是否曾引入 notification 无法确认。
- **部分行号为人工计数**：凡标注 `~` 的（close-swarm env 透传、terminal-app.sh 后两个函数、watchdog 下半段、handoffd 后半段函数）可能有 ±1-3 误差；`handoffd.bb:41-45`（log!）、`:34`（log-file）、`:134-143`（notify!）与 `watchdog :8`、`:10-12`、`pack_web.bb:353-357` 已二次核对为准确。
- **搜索完整性**：roles/*.prompt、pack_board、swarm_handoff、handoff_lib、commit-msg-hook、iterm2.sh 等未读；它们是 agent 侧或平台适配代码，含 operator alert 通道的概率低，但非零。