<p align="center" style="color: red; font-weight: bold; font-size: 2em; font-style: italic; text-decoration: underline;">
Do not spend any money on a bankrbot SWARM token.
</p>

# SwarmForge

**A disciplined tmux-based agent orchestration platform that turns swarms of AI agents into reliable, professional software engineers.**

## Intent

This `main` branch is documentary: it explains the system and carries the shared operational scripts and default constitution articles. The runnable workflow branches carry the project-facing configurations, role prompts, and local constitution articles that define specific workflows.

SwarmForge is an agent coordination system that facilitates communication between agents working in different git worktrees.

It provides a shared structure for role-specific prompts, worktree assignment, tmux sessions, and message passing so multiple agents can collaborate on the same project without stepping on each other.

## Branches

The runnable SwarmForge configurations live on dedicated branches. Each branch contains the `swarmforge/swarmforge.conf`, local constitution articles, and role prompts for one workflow. At startup, its `./swarm` wrapper copies the shared operational scripts and shared constitution articles from `main` when they are not already present, then launches that branch's local configuration.

### `two-pack`

`two-pack` is the quick backend workflow. Use it for small tasks that benefit from fast coding without the overhead of Gherkin and acceptance testing, while still preserving backend refactoring and hardening.

- `coder` implements requested behavior with TDD and unit tests.
- `cleaner` batches coder handoffs and performs cleanup, CRAP and DRY review, architectural review, encapsulation and separation-of-concerns fixes, and language mutation hardening.

The normal flow is `coder` -> `cleaner` -> `coder`. Use this branch when you want a tight implementation/refinement loop without specification, QA, property-test, or acceptance-test roles.

### `four-pack`

`four-pack` is the compact specification workflow. Use it for moderate projects that require Gherkin specification and some architectural consideration without splitting every quality gate into its own agent:

- `specifier` turns user intent into precise Gherkin acceptance specifications and asks for approval before handoff.
- `coder` implements approved behavior slices with TDD, unit tests, and generated acceptance tests.
- `refactorer` performs behavior-preserving cleanup, coverage improvement, CRAP and DRY review, mutation-site scans, and property-test support.
- `architect` owns high-level structure, dependency direction, mutation hardening, DRY review, soft Gherkin mutation, and final completion notification.

The normal flow is `specifier` -> `coder` -> `refactorer` -> `architect` -> `specifier`. Use this branch when you want disciplined development without splitting cleanup, architecture, hardening, and QA into separate agents.

### `six-pack`

`six-pack` is the full workflow. Use it for major projects that require full specification, up-front QA, backend verification, and significant architectural consideration. It separates each major quality gate into its own role:

- `specifier` turns user intent into accepted Gherkin specifications and end-to-end QA procedures.
- `coder` implements approved behavior slices with TDD, unit tests, and generated acceptance tests.
- `cleaner` performs local behavior-preserving cleanup, coverage improvement, CRAP and DRY review, and mutation-site scans.
- `architect` reviews module structure, boundaries, dependency direction, and property-test coverage.
- `hardender` performs mutation hardening, language mutation, CRAP and DRY verification, and soft Gherkin mutation.
- `QA` converts the specifier's QA procedures into executable scripts, runs final user-interface verification, checks handoff consistency, and sends completion notifications.

The normal flow is `specifier` -> `coder` -> `cleaner` -> `architect` -> `hardender` -> `QA` -> completion. Use this branch when you want each review and verification concern owned by a separate agent.

## Prerequisites

SwarmForge runs locally. Before starting a runnable branch, make sure the target machine has:

- `zsh`
- `git`
- `tmux`
- Babashka (`bb`)
- At least one configured agent backend, such as `codex`, `claude`, `copilot`, or `grok`

## Getting Started

In the directory where you want to use SwarmForge, choose a runnable branch and pull its contents without creating a Git remote:

```sh
BRANCH=four-pack
curl -L "https://github.com/unclebob/swarm-forge/archive/refs/heads/${BRANCH}.tar.gz" | tar -xz --strip-components=1
```

Use `BRANCH=two-pack` for the quick two-agent workflow, `BRANCH=four-pack` for the compact specification workflow, or `BRANCH=six-pack` for the full six-agent workflow. Do not use `main` for this command; `main` is documentary and stores the shared operational scripts, while the runnable branches provide the configurations and prompts intended for projects.

After copying a runnable branch, start the swarm from the target project:

```sh
./swarm
```

The `./swarm` wrapper keeps the runnable branch small. On first use, if `swarmforge/scripts/` is missing, it downloads the `main` branch archive, copies the shared operational scripts from `swarmforge/scripts/`, stages shared constitution articles from `swarmforge/constitution/articles/`, and then launches `swarmforge/scripts/swarmforge.sh`. Later runs reuse the existing local scripts directory instead of overwriting it.

The windows should open automatically.

To stop the swarm, close the first window listed in `swarmforge/swarmforge.conf`. That cleanup window shuts down the tmux sessions and closes the remaining tracked windows.

While a swarm is active, SwarmForge tries to prevent the host from sleeping. On macOS it uses `caffeinate`; on Linux it uses `systemd-inhibit` when available. Display lock or manual sleep can still interrupt agents depending on the OS. Set `SWARMFORGE_PREVENT_SLEEP=0` before `./swarm` to disable this behavior.

## What SwarmForge Does

SwarmForge is a lightweight, tmux-based orchestration layer that:

- Launches a **config-driven swarm** from a project-local `swarmforge/swarmforge.conf`
- Creates one tmux session per configured role and opens a terminal surface for each role when the selected backend supports it
- Reads behavior from project-local `swarmforge/roles/<role>.prompt` files plus a layered `swarmforge/constitution.prompt`
- Supports per-role backends such as `claude`, `codex`, `copilot`, or `grok`
- Puts the shared `swarmforge/scripts/` directory on each agent's `PATH`, including handoff helpers for active swarm communication
- Creates git worktrees under `.worktrees/` for roles assigned to dedicated worktree names
- Initializes a git repository in a new working directory when needed
- Keeps all swarm state local to the working directory in `.swarmforge/`

## Core Features

- **Config-Driven Topology** — The swarm shape comes from `swarmforge/swarmforge.conf`, not hardcoded shell variables.
- **Project-Local Roles** — Each role is defined by `swarmforge/roles/<role>.prompt` in the working tree being orchestrated.
- **Layered Constitution** — `swarmforge/constitution.prompt` directs agents to read article files under `swarmforge/constitution/articles/`.
- **Backend Selection Per Role** — A role can launch `claude`, `codex`, `copilot`, or `grok`.
- **Observable Swarm** — Open one Terminal window per role and watch the sessions in real time.
- **Self-Hosted & Lightweight** — Runs locally in tmux and Terminal with minimal machinery.

## Constitution Structure

Each runnable branch contains a `swarmforge/` directory with this general layout:

```text
swarmforge/
  swarmforge.conf
  constitution.prompt
  constitution/
    articles/
      project.prompt
      local-engineering.prompt
      local-workflow.prompt
      ...
  roles/
    <role>.prompt
    ...
```

`constitution.prompt` is the entry point. Runnable branches normally use it to tell agents to read every file in `swarmforge/constitution/articles/`.

Shared default articles live on `main` under:

```text
swarmforge/constitution/articles/
  engineering.prompt
  handoffs.prompt
  workflow.prompt
```

At startup, SwarmForge installs missing shared articles into the runnable branch's `swarmforge/constitution/articles/` directory before creating role worktrees. It also installs missing shared articles into each role worktree during script synchronization. Existing local files are skipped, so a runnable branch can override a shared article by committing an article with the same filename.

Pack-specific additions and exceptions should use explicit local filenames rather than editing shared articles. Current conventions are:

- `project.prompt` for the workflow's project shape and local topology.
- `local-engineering.prompt` for workflow-specific engineering rules.
- `local-workflow.prompt` for workflow-specific flow rules.

The `local-*.prompt` naming convention means "add to or specialize the shared default article for this runnable branch." Use it when the shared article remains valid and the branch only needs extra requirements, exceptions, or narrower instructions. Do not use `local-*.prompt` for a full replacement; use the shared filename instead when the branch intentionally overrides the shared article.

For example, `main` can provide a shared `workflow.prompt`, while `six-pack` can add `local-workflow.prompt` for QA-specific handoff behavior. If a branch needs to replace the shared workflow article completely, it can commit its own `workflow.prompt`; startup will treat that local file as an override and will not copy the shared one over it.

## Roles

Each role in `swarmforge/swarmforge.conf` maps to a corresponding `swarmforge/roles/<role>.prompt` file.

## How It Works

In a runnable branch:

1. SwarmForge reads `swarmforge/swarmforge.conf`.
2. The root `./swarm` wrapper copies shared helper scripts, terminal adapters, and shared constitution articles from the `main` branch when they are not already present.
3. Startup installs missing shared constitution articles into `swarmforge/constitution/articles/`, skipping any local article file that already exists.
4. Startup validates the configured role prompts, helper scripts, and terminal adapters.
5. If the target directory is not already a git repository, startup initializes one and creates the first commit.
6. Startup creates one git worktree per configured role under `.worktrees/`, unless the role is assigned to `master` or `none`.
7. Startup syncs `swarmforge/scripts/` and missing shared constitution articles into each role worktree and puts that local scripts directory on each agent's `PATH`, so agents use local handoff helpers without reaching back into the master checkout.
8. SwarmForge creates tmux sessions, opens terminal windows, and launches each configured backend in its assigned worktree.
9. Startup starts an OS-specific sleep inhibitor when one is available, and cleanup stops it with the swarm.
10. Roles communicate through daemon-delivered handoff files. Agents create validated drafts with `swarm_handoff.sh`, accept work with `ready_for_next.sh`, and complete work with `done_with_current.sh`.

## Handoff Protocol

Startup syncs the shared helper scripts into every role worktree under `swarmforge/scripts/` and puts that local directory on the agent's `PATH`. Agents do not send tmux messages directly. The launcher starts `handoffd.bb`, which owns tmux socket access, watches each agent outbox, copies validated handoff files into recipient inboxes, and sends only generic wake-up notifications.

Agents interact with handoffs through three helper scripts:

- `swarm_handoff.sh <draft-file>` validates and queues outbound handoffs.
- `ready_for_next.sh` accepts work using the role's configured receive mode.
- `done_with_current.sh` completes the current task or batch using the role's configured receive mode.

Outbound drafts use one of two message types. A git handoff points the recipient at a committed state. The commit abbreviation must be exactly 10 hexadecimal characters; `swarm_handoff.sh` validates that it resolves to a single commit and canonicalizes it before queuing the handoff.

```text
type: git_handoff
to: <role>[,<role>...]
priority: NN
task: <short-stable-task-name>
commit: <10-character-commit-abbrev>
```

A note is one short freeform message:

```text
type: note
to: <role>[,<role>...]
priority: NN
message: <one line, max 80 chars>
```

The helper generates the delivered payload. Agents do not write long handoff bodies, branch names, queue filenames, or tmux commands.

Recipient agents run `ready_for_next.sh` when notified or after restart. It dispatches to the task or batch helper configured for that role. If it prints `NO_TASK`, they stop waiting for work. If it prints `TASK: <path>`, they treat the printed `TASK_NAME` and `PAYLOAD` as the task. If it prints `BATCH: <path>`, they process the printed `BATCH_ITEM` entries in helper-delivered order. If a wake-up arrives while an agent is already working, it can ignore the wake-up; `done_with_current.sh` checks for the next task or batch after completing the current work.

The durable handoff files and lifecycle headers replace the old logbook and resend queue. Runtime handoff state lives under `.swarmforge/handoffs/` in each worktree, with `outbox`, `sent`, `failed`, and `inbox` subdirectories. Agents should not hand-edit, merge, stage, or commit handoff runtime state. See [swarmforge/handoff-protocol.md](swarmforge/handoff-protocol.md) for the full protocol.

## The `swarmforge.conf` File

`swarmforge/swarmforge.conf` defines the swarm window-by-window. Each line has this form:

```conf
window <role> <agent> <worktree> [task|batch] [extra-cli-args...]
```

The optional receive mode defaults to `task`. Use `batch` for roles that should consume all currently queued equal-priority handoffs as one batch.

Any fields after the receive mode are passed directly to the agent CLI as additional arguments. If you omit the receive mode, extra arguments may start at the fifth field:

```conf
window coder copilot wt-coder --yolo
window architect claude wt-arch task --dangerously-skip-permissions
```

You can define as many windows as your project needs. Each `role` maps to a corresponding prompt file at `swarmforge/roles/<role>.prompt`, so a config containing `architect`, `coder`, `reviewer`, `research`, and `release` windows would expect:

- `swarmforge/roles/architect.prompt`
- `swarmforge/roles/coder.prompt`
- `swarmforge/roles/reviewer.prompt`
- `swarmforge/roles/research.prompt`
- `swarmforge/roles/release.prompt`

This lets each project choose its own swarm shape instead of being locked to a fixed set of roles.

Example config:

```conf
window coordinator codex master
window coder codex coder
window refactorer codex refactorer
window architect codex architect
```

In the example above, the agents run in these worktrees:

- `coordinator` -> main working directory on `master`, and is the cleanup window because it is listed first
- `coder` -> `.worktrees/coder`
- `refactorer` -> `.worktrees/refactorer`
- `architect` -> `.worktrees/architect`

If a window uses `master` as its worktree name, SwarmForge does not create `.worktrees/master`; that role runs in the main working directory on the `master` branch.

## tmux Behavior

SwarmForge uses a project-specific tmux socket recorded in `.swarmforge/tmux-socket`, so each project swarm is isolated from other tmux sessions. It also honors tmux `base-index` and `pane-base-index` settings when launching agents and sending notifications, so configurations that number windows or panes from `1` work without requiring users to change their tmux preferences.

## Terminal Behavior

SwarmForge opens trackable terminal windows or tabs through a small terminal backend adapter.

Default detection:

- If AppleScript is available, SwarmForge opens macOS Terminal.app windows.
- Otherwise, if `wt.exe` is available, SwarmForge opens Windows Terminal windows.
- Otherwise, SwarmForge attaches the cleanup tmux session in the current shell.

After copying a runnable branch, set `SWARMFORGE_TERMINAL` to override detection:

```sh
SWARMFORGE_TERMINAL=ghostty ./swarm
SWARMFORGE_TERMINAL=terminal-app ./swarm
SWARMFORGE_TERMINAL=windows-terminal ./swarm
SWARMFORGE_TERMINAL=none ./swarm
```

Use `ghostty` when you want SwarmForge to open Ghostty tabs instead of the default Terminal.app windows. Use `windows-terminal` when you want SwarmForge to open Windows Terminal windows from WSL. Use `none` when you want SwarmForge to skip terminal automation and attach the cleanup tmux session in the current shell.

### Adding A Terminal Backend

The shared terminal backends are carried on `main` under `swarmforge/scripts/terminal-adapters/`. Runnable branches copy those scripts at startup. To add a new backend, update `main` by creating one file named after the backend:

```text
swarmforge/scripts/terminal-adapters/wezterm.sh
```

The file must define this small contract:

```sh
terminal_backend_label() {
  echo "WezTerm"
}

terminal_backend_can_open_sessions() {
  return 0
}

terminal_backend_tracks_windows() {
  return 0
}

terminal_open_session() {
  local session="$1"
  local title="$2"
  local sibling_id="${3:-}"

  # Open a terminal surface that runs:
  # cd "$WORKING_DIR" && exec tmux -S "$TMUX_SOCKET" attach-session -t "$session"
  #
  # Print a stable window/tab id to stdout.
}

terminal_window_exists() {
  local window_id="$1"

  # Return 0 if the id from terminal_open_session still exists.
  # Return nonzero otherwise.
}

terminal_close_window() {
  local window_id="$1"

  # Close the id from terminal_open_session.
}
```

If the terminal can open sessions but cannot return stable ids for open/check/close, keep `terminal_backend_can_open_sessions` as `return 0` and set `terminal_backend_tracks_windows` to `return 1`. SwarmForge will open one surface per session and skip the watchdog for that backend. `swarmforge/scripts/terminal-adapters/windows-terminal.sh` is an example of this launch-only style.

If the backend cannot open sessions at all, set both capability functions to `return 1`; SwarmForge will attach the cleanup tmux session in the current shell. Only edit `swarmforge/scripts/swarm-terminal-adapter.sh` when adding aliases or changing default auto-detection.

## 从本地操作运行中的 Swarm（swarmforge-operator）

本仓库自带 `.agents/skills/swarmforge-operator/`：一个供本地 agent 会话（工作目录在本仓库，cmux/macBook 侧）操作运行中 SwarmForge project 的操作面 skill。它面向任意 topology：两包、四包、六包或自定义角色数，一切以目标 project 的 runtime state（`.swarmforge/` 下的 `tmux-socket`、`sessions.tsv`、`roles.tsv`）为准，不按 pack 名或固定角色列表分支。

使用前提：skill 的使用者工作目录是本仓库。放在被操作 project 里时，本仓库会话调不到它。

### 十一个 verb

| 动词 | 作用 |
|---|---|
| `start swarm <root> --terminal <值>` | 从停机状态显式启动 swarm；`--terminal` 必传（`ghostty`/`iterm2`/`none`/`terminal-app`/`windows-terminal`/`auto`），杜绝 #10 那次靠自动探测踩中 watchdog 拆除的坑；已在跑（socket 探活成功）拒绝重复启动（退出 6，无 override）；启动前还会取 project lock 并比对已装 `swarmforge/scripts` 与其 manifest 的 digest，manifest 缺失或不一致报 `STATUS=DRIFT`（退出 4），锁被 `update SwarmForge scripts` 占用同样报 `UNSAFE`（退出 6）——`--force` 可越过锁占用与 DRIFT，但越不过「已在跑」；本地/远端都走 `nohup` 脱离终端启动，回读 runtime 文件确认后才报 `STATUS=STARTED` |
| `update SwarmForge scripts <root>` | 把 operator 自己这份源码checkout 的 `swarmforge/scripts` 装进被管项目，替换前先落地临时目录并按 `swarmforge.bb` 同款 required-helpers/terminal-adapters 清单校验，三件套（scripts 树、manifest、旧版 `./swarm` 启动器）原子替换、任一步失败整体回滚；已在跑拒绝（退出 6，无 override），源码checkout 有未提交改动同样拒绝（退出 5，无 override，永不可越过）；抢同一把 project lock，被 `start swarm` 占用报 `UNSAFE`，`--force` 只越过锁占用；成功报 `STATUS=UPDATED` 并带 `DIGEST=`/`SOURCE_COMMIT=` |
| `open swarm <root>` | 把运行中的 swarm 以 cmux workspace 打开；停机时报原因，命中 window watchdog 拆除会点名，绝不代人启动 |
| `dashboard <root>` | 建 SSH 隧道开 browser workspace 连 pack_web 看板；额外校验端口后面真是本项目的 `pack_web`（`--serve` 参数比对），不是同机别的项目撞上来的 |
| `attach <role>` | 临时附加到某个角色的 tmux session |
| `read swarm` | 逐角色截屏，三态分类 `IDLE`/`BUSY`/`UNKNOWN`（认不出就是 UNKNOWN，不猜成 idle），每行都附原始 pane 文本 |
| `wake <role>` | 唤醒：注入 `ready_for_next.sh`，按 backend 编码提交后**验证真的被消费**，没提交成功报错并点名 backend 不匹配 |
| `talk <role>` | 给指定角色发一条行为切片，同样验证送达且被提交，不是发了就算 |
| `onboard project` | 把 upstream 的 two-pack/four-pack/six-pack 装进一个项目目录；拒绝 `main`，目标非空时零写入拒绝；改写 `ARCHIVE_URL` 默认值指向本 fork，装完不启动 |
| `accept work` | 人工验收：读终端 handoff 报 `task`/`commit`；同时扫 `inbox/new`/`inbox/in_process` 的滞留，卡链了会 `WARN=` 报出来，不再跟"没活干"读起来一样 |
| `stop swarm` | 停机前先 preflight：有角色 `BUSY`/`UNKNOWN` 或 worktree 有未提交改动就拒绝停机（退出 6），全干净才走 `close-swarm`；`--force` 跳过 preflight 复现今天的裸停机 |

默认远端是 `admin@100.64.0.4`，可用 `--target`/`--key` 覆盖；`--local` 改走本地文件系统。

### `open swarm` 契约

```sh
.agents/skills/swarmforge-operator/scripts/open-swarm.sh \
  --root <远端 project 根> [--window <ref>] [--target host] [--key path] [--local]
```

脚本负责全部 cmux 机制：runtime gate、相邻角色配对成双 pane workspace（奇数尾部单 pane）、以 description `swarmforge:<basename>@<host>` 认领与复用、逐 surface 验证 attach、失效 surface 最多重发一次 attach。Agent 只跑脚本、读退出码、汇报。

退出码：`0` OPENED/REUSED 成功；`3` STOPPED（swarm 未运行，拒绝启动）；`4` DRIFT（workspace 与 runtime 不符，零变更，需用户授权后重建）；`5` ERROR。

看板本身是 `pack_web`：`./swarm` 启动时随 swarm 一起起的本地 HTTP 服务，页面展示并可操作 swarm 状态（agent 状态、任务/交接、approvals、chat、teardown），只监听远端 `127.0.0.1`，所以远程访问必须走隧道。

`dashboard` 动词用 `scripts/open-dashboard.sh`（参数同上）：读 `.swarmforge/dashboard-url`，确保 `-N -L` 本地转发（已有可用隧道则复用；端口被占则换空闲端口），在当前 window 开/复用 `Dashboard · <basename>` workspace（browser surface 指向隧道 URL）。退出码语义同上；`3` 表示 dashboard-url 缺失，绝不自己起 `pack_web.sh --serve`。

三条硬性禁令，agent 不越过：

1. 绝不执行 `./swarm` 或任何启动已停机 swarm 的命令；`open` 只连接运行中的 swarm。
2. 默认在 caller 当前 cmux window 建 workspace，不新建 macOS window；用户明说 new window 时才建，并传 `--window`。
3. 绝不自动 close 任何 workspace/surface/window 作为清理；残留对象由用户逐项授权处置。

直接操作 cmux 前需先加载 `cmux` skill（REQUIRED SUB-SKILL），handle、settle、ownership、destructive guardrail 是 cmux skill 的契约，本 skill 不重复。

### 测试

改脚本或 stub 契约后运行：

```sh
bash .agents/skills/swarmforge-operator/scripts/test-open-swarm.sh
```

stub cmux 全链路覆盖：two/four/six-pack、自定义 5 角色、复用、stale attach 修复、停机拒启、socket 失活、drift、mutation 输出不可解析不重复创建；dashboard 套件另覆盖隧道复用与端口冲突回退。

## Window Behavior

Each visible agent window is attached to a tmux session. That means terminal selection, copy, and paste may follow tmux and terminal-emulator rules rather than ordinary text-field behavior. If copy or paste feels unusual, check whether tmux copy mode is active before assuming the agent is stuck.

The first window in `swarmforge.conf` is the cleanup window. Closing that top configured window is the intentional shutdown path: SwarmForge tears down the tmux sessions, closes the remaining tracked windows, and shuts down the swarm.

Closing any other tracked window is non-destructive. The watchdog reopens that window and attaches it back to the same tmux session, so the agent state and terminal history remain intact. This is often the simplest way to recover a window that has landed in an unfamiliar tmux mode or otherwise feels stuck.
