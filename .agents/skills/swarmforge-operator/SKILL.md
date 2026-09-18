---
name: swarmforge-operator
description: "Use when operating SwarmForge from a local agent session: provisioning a lieutenant Forge, opening role terminals or a project-owned Dashboard in cmux, attaching to a role, waking a role, sending it a message, or publishing completed Managed project work as a pull request. Project lifecycle, role state, Board tasks and approvals belong in the Dashboard."
---

# SwarmForge Operator

本 skill 只服务 lieutenant Forge 及其 Managed project，不安装独立 Pack。
SwarmForge 是协调产品；Managed project 是它开发的产品仓库，住在 `<forge-root>/projects/<name>`。
Forge 围绕多个 Managed project 安装，拥有 Host lieutenant 与共享 Dashboard。

六个 verb 各有一个 `scripts/verb-*` seam，参数、stdout、stderr 与退出码原样透传给已有 `.sh`。
以下命令从本 skill 目录执行。wrapper 默认 real；操作时仍显式写 `SF_ADAPTER=real`，
避免继承测试环境。`SF_ADAPTER=fake` 只给固定成功样本，在 stderr 标明 `ADAPTER=fake`，不执行操作。
未知 adapter 返回 `2 USAGE`，adapter 缺失或不可执行返回 `5 ERROR`，绝不回退另一个 adapter。

直接操作 cmux 前必须加载 `cmux` skill。随包 adapter 已负责 settle、ownership、workspace 复用与验证，
不要在外层重复实现。新建 window 或破坏性清理须先获用户明确授权。

## 定位与 runtime

默认远端为 `admin@100.64.0.4`，key 为 `~/.ssh/tailscale_key`，可用 `--target`、`--key` 覆盖。
`--local` 在本机执行。`--root` 是目标主机上的路径，不能拿本仓库路径替代。

- `provision forge` 使用 Forge 根目录，首次安装没有 runtime。
- `open swarm`、`dashboard`、`wake role`、`talk role` 连接已运行的 Managed project。
  依照对应小节读取 runtime，缺失或 tmux 不应答就停，不能代为启动。
- `ship project` 使用 Managed project 仓库根，读取 Board、handoff 与 git，不要求角色或 pack_web 运行。

Managed project 的路径须匹配 `*/projects/*`，取 `${ROOT%/projects/*}` 为 Forge 根；
同时必须存在该根下的 `projects/` 目录与 `swarm` 文件。仅有 `.swarmforge/` 不能证明归属，
独立 Pack 安装也有相同文件。布局不符返回 `6 BLOCKED`。

角色与 topology 从目标 `.swarmforge/` 读取，不按 Pack 名或固定角色名分支：

- `tmux-socket`：真实 socket 路径，每次 Swarm 重启后重新读取。
- `sessions.tsv`：config 顺序、role、session、显示名、agent backend。
- `roles.tsv`：role、worktree 名、worktree 路径、session、显示名、backend、接收模式。
  worktree 名为 `master` 的唯一一行是 intake role；它不是固定名为 coder 的角色，也不是 git 分支名。

只碰指定 ROOT 的 runtime 及其 socket。一台主机可以有多个 project。

## Dashboard 的职责

Project open/close、Forge teardown、角色状态、Board 切卡、审批与澄清都在 Dashboard 完成。
关闭 project 使用 Dashboard 的 close，它同时维护 Forge 的 `open-projects` 记录；
不要用外部 tmux kill 或旧停机脚本绕过它。

New Task 创建 Board 卡片，是常规派活入口。chat rail 只通 Host lieutenant，不能替代向 project 角色发消息。
Dashboard 的 agent pane 是只读 capture；需要能输入的终端才用 `open swarm` 或 `attach role`。

## 读取结果

结合退出码、stdout 和 stderr 判断。成功 contract 的 STATUS 在 stdout 第一行；旧 adapter 的参数错误
可能只有 usage，provision 的 USAGE 可能写到 stderr。不能假定所有错误都有 STATUS。

- `0`：本次操作成功，或该 verb 明示没有待执行工作。把结果字段和 WARN 一并转述。
- `2` / `3 STOPPED`：分别修正参数、报告目标未运行；不要把 STOPPED 当作启动授权。
- `4 DRIFT` / `6 UNSAFE|BLOCKED`：报告具体不一致或阻断原因，修复、清理或绕过前先问人。
- `5`：操作失败，可能已经有部分副作用，按 verb 小节处理，不能盲目重试 mutation。
- `8 NEEDS_PR_BODY`：ship 已推送，等本机 PR 正文文件，不表示发布从未开始。

失败诊断是给人看的，不从句子猜新的机器协议。`attach role` 是 handover，交接之后退出码属于目标程序。

## Verb: `provision forge`

从空目录安装并启动 Forge，可选创建并打开第一个 Managed project。不负责 Board 派活。

```sh
SF_ADAPTER=real scripts/verb-provision-forge --root <forge-root> \
  --forge lieutenant --dashboard-port <N> \
  [--project <name>] [--mission <text>] [--terminal <value>] \
  [--target user@host] [--key <path>] [--local]
```

### 输入与前置条件

- `--root` 必须是目标主机的绝对路径，不含单引号，目录不存在或为空；完整安装可续跑，半安装或其他文件占用会拒绝。
- `--dashboard-port` 必填，只校验数字，不校验范围。按下文 Dashboard 端口分配选择。
  `--terminal` 默认 `none`，远端无可见窗口时保持此值。
- project 名只含字母、数字、点、下划线或连字符，不能以点开头。lieutenant 使用唯一 project template，
  `--pack` 可省。省略 `--project` 只安装启动 Forge；`--mission` 可显式传空。
- 目标需具备安装器和 launcher 的依赖，包括 zsh、curl、tar、git、tmux。

### 执行与安全条件

使用本 fork 的 helper，不透传 `SWARMFORGE_REPO_URL` 切来源。安装后检查 `handoffd.bb` 的
`reconcile-once!` 与 `handoff_lib.bb` 的 `roles.tsv` marker，失败不启动；marker 不是全树等价性证明。
仅在 manifest 缺失时写 digest，已有 manifest 不覆盖。

启动委托内部 `start-swarm.sh`，保留锁、digest、detached 启动与 readiness；不要另拼 ssh + nohup，
不要自动加 `--force`。自动探测 terminal 可能选到没有真实窗口的 backend，导致 watchdog 拆掉 Swarm。

可选建项目在 tmux 就绪后等待 Dashboard HTTP，默认 20 次、间隔 0.5 秒，再向目标主机的
`127.0.0.1` 发送 `POST /api/projects`。不直接写 `open-projects`，不建立 tunnel、不发布 tailnet 端口、不改 pack_web 绑定。
完整安装跳过下载，已运行跳过启动，均以 WARN 报告。同名 project 拒绝覆盖；半安装不能自动清空。

### 结果与失败处理

- `0 PROVISIONED`：返回 `ROOT/FORGE/URL/TARGET`；建项目另有 `PROJECT/PACK/PROJECT_PATH`。
  转述 Dashboard URL。创建请求成功不额外证明所有 project role 已完成 readiness。
- `2 USAGE` / `4 DRIFT`：分别修正参数、检查 snapshot/manifest，不覆盖 manifest 或自动强制。
- `5 ERROR`：按诊断确认失败阶段。安装失败可留下半安装，Dashboard 或建项目失败时 Forge 可能已运行。
- `6 UNSAFE`：目录占用、锁或启动条件冲突、项目重名等。HTTP 409 属于此类，其余创建失败为 ERROR。
  拒绝建项目之前可能已完成安装与启动，不能说“什么都没改”。

## Verb: `open swarm`

在当前 cmux window 打开可输入的角色终端。只连接已运行 Swarm，不启动、不关闭任何东西。

```sh
SF_ADAPTER=real scripts/verb-open-swarm --root <project-root> [--window <ref>] \
  [--target user@host] [--key <path>] [--local]
```

运行端需要 bash、python3 和可达的 cmux。目标需要 `tmux-socket`、`sessions.tsv`、`roles.tsv`，
其中 master 行恰好一条。socket 探活后，按 runtime 顺序把相邻 session 两两配成 workspace，奇数尾部单 pane。
以 `swarmforge:<basename>@<host>` 描述复用既有集合，失效 surface 最多重发一次 attach，再逐个验证。

- `0 OPENED|REUSED`：转述 `WORKSPACES/ATTACHED/REPAIRED` 与 `MASTER_DISPLAY/MASTER_WS`。
  不切用户焦点；说清 master 位置。
- `3 STOPPED`：停下。诊断点名 window watchdog 时，由人修好 terminal backend 再重启，原样重启会重现击杀。
- `4 DRIFT`：cmux 与 runtime 不符，关闭或重建前先问用户。
- `5`：早期失败报 ERROR；附着验证失败可能仍报 `STATUS=OPENED|REUSED`，但 `FAILED>0` 且退出 5。
  转述 `FAILED_SURFACES`，先检查状态，不能再次 create 试探前一次是否成功。
- `2` / `6 BLOCKED`：修正参数或 Managed project 定位；参数错误可能只有 usage。

默认使用当前 window。只有人明确要求才另建 macOS window 并传 `--window`。
停机绝不代启动，残留 workspace/surface/window 绝不自动清理。

## Verb: `dashboard`

让已有 Dashboard 可达，并在当前 cmux window 打开或复用 browser workspace。
不启动 Swarm 或 pack_web，不关闭 workspace，不自动新建 window。

```sh
SF_ADAPTER=real scripts/verb-dashboard --root <project-root> [--window <ref>] \
  [--target user@host] [--key <path>] [--local] [--tailnet]
```

### 适用范围与归属

旧 adapter 在 Managed project 自己的 `.swarmforge/` 读取 `tmux-socket`、`dashboard-url`、`pack_web.pid`。
**不能直接打开 Forge 根，也不能凭 project URL 接入 Forge 共享 pack_web**：pid 对应进程的 `--serve`
路径必须等于 ROOT。只有 Forge 级 runtime 时报告此限制，不能伪造 pid、复制 runtime 或另起 pack_web。

依次确认 Managed project 归属、tmux 活着、pid 活着且属于 ROOT，然后验证 HTTP 200，最后操作 cmux。
HTTP 200 本身不证明归属。Swarm 停着时即使 URL 还在，也拒绝继续。
按 `swarmforge-dashboard:<basename>@<host>` 复用 workspace；缺 browser 才补建，旧 URL 则导航并回读。
多个匹配 workspace 报 DRIFT，由人决定清理。

### 连接方式

本机使用 `--local`，不加 `--tailnet`，取得 `TUNNEL=local` 与 URL 后结束。
远端先读当前 `dashboard-url` 端口，不能从旧回复或上次 URL 猜：

```sh
SF=.agents/skills/swarmforge-operator/scripts  # 从本仓库根目录使用此路径
ROOT=/Users/admin/project/forge/projects/podsum
TARGET=admin@100.64.0.4
KEY=~/.ssh/tailscale_key
PORT=$(ssh -n -i "$KEY" "$TARGET" "cat '$ROOT/.swarmforge/dashboard-url'" | sed 's#.*:##; s#/##')
```

1. `7780`–`7789` 段内，运行下面的 tailnet 调用。脚本只验证可达性，不执行 tailscale 命令。
2. 其他端口，运行不带 `--tailnet` 的调用，脚本建立或复用 SSH local-forward；端口占用时换空闲端口。
   地址仅本机有效，笔记本休眠可能中断。把切固定端口作为选项，不擅自执行。
3. 成功必须转述报文的 `URL=`。只有 tailnet URL 可作为跨设备地址，不能只说“已打开”。

```sh
# 固定端口
SF_ADAPTER=real "$SF/verb-dashboard" --root "$ROOT" --target "$TARGET" --key "$KEY" --tailnet
# 其他端口，仅选符合当前端口的一条
SF_ADAPTER=real "$SF/verb-dashboard" --root "$ROOT" --target "$TARGET" --key "$KEY"
```

### 发布端口或切换端口，先获授权

未发布的固定端口返回 ERROR 并给出命令，不代表可以擅自修改主机配置。
经用户同意后依次执行：

1. 在目标检查 `tailscale serve status`，该段已有映射就跳过发布。否则逐个发布端口，不能传范围。
   Linux 写配置可能要 root；报 Access denied 时加 sudo，或由人设置 `tailscale set --operator=$USER`。
2. 若需换端口，先由 Dashboard close project 或 teardown Forge。**会打断工作，先说明影响并获授权**。
3. 从 Dashboard 重新打开，或重跑 provision Forge 指定分配端口。不能在 Swarm 仍运行时另起一个实例抢端口。
4. 重新检查 runtime 归属，再运行 tailnet seam。共享 Forge runtime 不满足上面的 adapter 条件时仍须停下。

```sh
ssh -i "$KEY" "$TARGET" 'tailscale serve status'
# 仅经授权，且尚未发布该段时：
ssh -i "$KEY" "$TARGET" 'for p in $(seq 7780 7789); do tailscale serve --bg --tcp $p tcp://127.0.0.1:$p; done'
ssh -i "$KEY" "$TARGET" 'tailscale serve status'
```

`--bg` 配置可跨重启保留，不要每次重复发布。**以上 tailscale serve 是唯一获准的手工暴露路径**。
不要另造 proxy、手拼 ssh -L 或改 pack_web 的 loopback 绑定；看板有 teardown 控件，扩大可达范围有风险。
默认 SSH tunnel 由 adapter 自己管理。流程走不通就报告，不临时发明连接方式。

端口 `7780`–`7789` 为 Dashboard 保留，一个 Forge 一个号，不是一个 project 一个号。
macmini 的 `~/project/forge` 使用 **7782**，内含 podsum；其余 **7780–7781、7783–7789** 未分配。
此为人工约定，代码不分配、不强制范围。新 Forge 选未分配号并在本节登记；跨主机不构成端口冲突。

### 结果与失败处理

- `0 OPENED|REUSED`：返回 `TUNNEL/URL/WORKSPACE/SURFACE/ROOT/TARGET`；TUNNEL 为 local、created、reused 或 tailnet。
- `2` / `3 STOPPED`：前者包括 `--local` 与 `--tailnet` 同用；后者包括 runtime 缺失、tmux 不应答、pid 失效。
  不代启动，先区分真正停机与不支持的 Forge runtime 布局。
- `4 DRIFT`：端口进程属于其他 root，或 workspace 匹配不唯一。报告证据，不自动删除或绕过检查。
- `5 ERROR` / `6 BLOCKED`：前者包括 URL、可达性或 cmux 失败，可能已建 tunnel/workspace；后者为 Managed project 布局不符。

`--tailnet` 使用 `--target` 的主机地址，需提供可达的 tailscale IP；归属检查照常执行。

## Verb: `attach role`

单角色终端交接保留直接调用，不属于六个 adapter 移植入口。
先从当前 ROOT 的 `tmux-socket` 与 `sessions.tsv` 得到 SOCK 与指定角色的 SESSION，不能硬编码 session：

```sh
ssh -tt -i "$KEY" "$TARGET" "tmux -S '$SOCK' attach -t '$SESSION'"
```

## Verb: `wake role`

向运行中角色键入 `ready_for_next.sh`，确认到达、提交并离开输入行，不把键入当作唤醒成功。

```sh
SF_ADAPTER=real scripts/verb-wake-role --root <project-root> --role <name> \
  [--target user@host] [--key <path>] [--local]
```

必需输入为 ROOT 与 role；目标须有 live tmux、`sessions.tsv` 和 `tmux-socket`。
backend 只来自 sessions.tsv，不接受 `--backend` 覆盖。claude 用 CSI-u Enter，其他 backend 用裸回车；
绝不用符号键名 C-m/C-j，extended keys 协商后的 TUI 可能收不到它们。

成功为 `0 WOKEN`，返回 ROLE、SESSION。`2` 是参数 usage（旧 adapter 不保证 STATUS 行）；
`3 STOPPED` 是 runtime 缺失或停机，不能代启动；`5 ERROR` 是角色不存在、文本没到达或没提交；
`6 BLOCKED` 是 Managed project 布局不符。提交失败时核对诊断中的 backend 与 session 中实际运行的 agent。

## Verb: `talk role`

向运行中角色发送一条行为消息，使用与 wake 相同的 runtime 前置条件、backend 选择与提交验证。

```sh
SF_ADAPTER=real scripts/verb-talk-role --root <project-root> --role <name> --message "<text>" \
  [--target user@host] [--key <path>] [--local]
```

message 必须非空，带空格文本须作为一个参数引用。成功为 `0 SENT`，返回 ROLE、SESSION；
失败处理与 wake 相同，包括 `2` usage、`3 STOPPED`、`5 ERROR`、`6 BLOCKED`。提交失败不能报告已送达。

两者的消费判据只看剥离尾部已识别静态 footer 后的最后一行非空行。Grok 的 ctrl+o footer
即使带队列提示、没有 transcript 也应剥离。直接读物理末行会把未提交误报成功；
搜索整个 pane 则会把已留在历史的文本误报未消费。

talk 不创建 Board 卡片，不能替代 Dashboard New Task。没有固定的 intake 角色名，按 roles.tsv 的唯一 master 行定位。

## Verb: `ship project`

把 Swarm 已完成的 Managed project 工作推送并开 PR，停在人工 review 前。
由 operator 执行，不通过 chat rail 让 Host lieutenant 即兴 push。

```sh
SF_ADAPTER=real scripts/verb-ship-project --root <managed-project-root> \
  [--target user@host] [--key <path>] [--local] \
  [--branch <name>] [--base <name>] [--issue <N>]... \
  [--body-file <path>] [--dry-run]
```

### 发布前检查

ROOT 必须是 Managed project 仓库根，按解析后的路径比较，允许合法符号链接；
不能是 Forge 根、仓库子目录或 `.worktrees/` 中的角色 checkout。无须预先给 task 名，也不要求 pack_web 或角色运行。

- Board 角色 lane 的卡阻断，waiting 只报告。project 根与各角色 worktree 的 `handoffs/failed/`，
  以及 project 的 `delivery_attention/` 有失败记录就阻断，空目录不算。
- 未提交改动阻断并点名，绝不代 commit。fetch origin 后，base 默认 main、其次 master；
  都不存在且未指定 base 则退出。落后远端只报 behind N 与 WARN，并写入 PR，不证明无冲突。
- 每条待发布交付的 commit 必须已是当前 HEAD 的祖先。Board Done 不等于 master 已合入；
  缺 commit 就等合入，不能编辑 Board 绕过检查。

终端交付来自 roles.tsv 唯一 master 行的 completed inbox，其他角色的中间交付不能代替。
按 task 取最新记录，字段不完整发 WARN；积压告警阈值为 new 5 分钟、in_process 30 分钟。
旧 adapter 排除已入库 commit 时固定查询 origin/main，即使显式指定其他 base 也一样，其他 base 下须核对清单。

本 verb 不运行 Managed project 测试，不猜测试命令、不搭环境，不支持 `--test-cmd`。
角色交接验证与 PR CI 仍需完成；没有 CI 的项目仍有验证缺口。

### 两趟发布

1. 运行 seam，完成检查、建分支和 push。需要正文时返回 `8 NEEDS_PR_BODY`，分支已推、PR 未开。
2. 用 `to-pr` skill 读取 origin/BASE..BRANCH 的 diff，写本机非空正文文件，不重复脚本生成字段。
   委派正文时只授权撰写，不代开 PR。
3. 保持 ROOT、base、branch、issue，重跑并加 `--body-file`，由脚本创建 PR。

`--dry-run` 不建分支、不推送，但仍 fetch 并校验发布条件，不是无 remote/base 时的独立诊断命令。
分支从 HEAD 创建但不 checkout，默认 `feat/swarm-<project>-<yyyymmdd>`；不要移动 Swarm 使用的 checkout。
push 后查同 head 的 open PR，有则返回旧 URL，不再要求正文。这是顺序重跑复用，不保证并发原子性。
跟踪分支提示与 push 进度走 stderr，成功 STATUS 保持 stdout 首行。

`--issue` 可重复，接受 `42` 或 `#42`，它是添加 Closes 的唯一来源；不从卡名或卡文本猜。
核对 will close，只传本 PR 确实解决的 issue。脚本追加 Closes、卡列表、Board 计数和发布源信息，
不替项目测试背书。空白或不存在的 body-file 会失败，不退回仅含元数据的正文；此时分支可能已推。

### 结果与失败处理

- `0 PR_OPENED`：转述 `url:`，停在可 review 的 PR，不自动 merge、force-push 或代提交。
- `0 NOTHING_TO_SHIP|DRY_RUN`：前者无待发布记录或 HEAD 未超前 base，不推送；后者只是预演。
  两者都不等于项目测试通过。
- `2` / `5 ERROR`：前者修正参数，旧 adapter 可能只有 usage；后者按诊断处理，分支可能已建或已推。
  修正后使用同一分支重跑，不自动回滚。
- `6 BLOCKED` / `8 NEEDS_PR_BODY`：前者不创建发布分支或 PR，汇总 blockers（早期路径拒绝可能只有诊断）；
  后者补本机正文再跑。把 WARN 一并转述，退出 0 不表示可直接合并。

## 内部实现：`start-swarm.sh`

仅由 provision 用来启动 Forge 自己，不是公开 verb。不要直接启动 Forge 下的 Managed project：
该路径会多起一个 Forge 不知道的 pack_web。Project 启动走 Dashboard。

保留以下内部操作约束，用于解释 provision 的失败，不作为绕过它的新入口：

- terminal 必须显式选择 ghostty、iterm2、none、terminal-app、windows-terminal 或 auto。
  auto 表示明确授权探测，脚本不原样转发这个值；其他值通过 SWARMFORGE_TERMINAL 到 launcher。
  dashboard-port 仅校验数字，通过 SWARMFORGE_DASHBOARD_PORT 转发，与 terminal 同时生效。
- live socket 时拒绝重复启动，退出 `6 UNSAFE`，force 也不豁免。
  未运行时先取 project 锁，再检查 snapshot/manifest digest；project 自己纳入 git 的 snapshot 不做此 drift 检查。
- snapshot 与 manifest 都无为 Fresh；都在为 Managed；恰好一个存在为 Incomplete，退出 `4 DRIFT`。
  digest 不符也为 DRIFT，不调用 launcher。manifest 描述 operator 安装的 snapshot，不用来覆盖 project 自有版本。
- force 会抢锁并跳过 digest，不自动使用。锁覆盖启动与 readiness，通常退出时释放；
  **Fresh bootstrap 就绪超时保留锁**，因为下载可能仍在进行，不能放进第二个写者。清锁须显式授权 force。
- 本地与远端 detached 启动，回读 runtime 与 tmux 判断 readiness，不以 launcher 自身退出码判断成功。
  `0 STARTED` 返回 SOCK/TERMINAL；`5 ERROR` 包括未就绪与启动失败，检查诊断中的日志。
  launcher 自己负责 Role worktree copy 的镜像与一致性校验，不能用此步骤代替它。

## Testing

从 skill 目录运行 `bash scripts/test-verb-<stem>.sh`，stem 为 provision-forge、dashboard、ship-project、
wake-role、talk-role、open-swarm。每套都执行固定 fake、显式 real、默认 real 的共同成功 contract，
以及 adapter 选择失败、参数边界、输出与退出码透传检查。测试不读取 spec，不检查本文件的措辞。

real 在隔离 fixture 中执行旧脚本：provision 使用本地安装样本与 HTTP server；ship 使用真本地 bare git remote
和 gh recorder；Dashboard、角色输入与终端附着使用 command doubles。wake/talk 另检查不含 transcript 的
排队 footer 不能掩盖未消费输入；open-swarm 检查配对、奇数尾部、逐 surface 验证和重复调用复用。
这些测试没有触达真实 GitHub、Forge 或角色 pane，不能宣称生产端到端已验收。

原七套回归保持：`test-open-dashboard.sh`、`test-open-swarm.sh`、`test-provision-forge.sh`、
`test-ship-project-delivery.sh`、`test-ship-project.sh`、`test-start-swarm.sh`、`test-wake-talk.sh`。
修改 adapter 后运行相关套件，交付前全部运行。ship 两套分别覆盖发布动作与终端交付筛选，不可只跑其中一套。
