# Operator runbook —— 从本地操作运行中的 Swarm

本文是**本 fork 独有**的内容，upstream 没有对应物。它原先住在 `README.md` 里，
2026-09-14 那次 merge 之后搬到这里：upstream 把 `README.md` 重新定位成 GitHub
landing page，一份后半段是中文操作手册的 README 与那个定位冲突，而且每次 upstream
动 README 都要手工调和这一整块。理由见
[`docs/adr/0005-operator-runbook-lives-outside-the-readme.md`](adr/0005-operator-runbook-lives-outside-the-readme.md)。

正文逐字保留搬迁前的版本，只在这里加了本段说明。

---

## 从本地操作运行中的 Swarm（swarmforge-operator）

本仓库自带 `.agents/skills/swarmforge-operator/`：一个供本地 agent 会话（工作目录在本仓库，cmux/macBook 侧）操作运行中 SwarmForge project 的操作面 skill。它面向任意 topology：两包、四包、六包或自定义角色数，一切以目标 project 的 runtime state（`.swarmforge/` 下的 `tmux-socket`、`sessions.tsv`、`roles.tsv`）为准，不按 pack 名或固定角色列表分支。

使用前提：skill 的使用者工作目录是本仓库。放在被操作 project 里时，本仓库会话调不到它。

### 六个 verb

**停 project / 停 forge / 起 project / 读角色状态都不在这里,走 Dashboard**（issue #158、
ADR-0008）。留下的每一个 verb 都做网页做不到的事:接入、附着、往 pane 里打字、装 forge、
推 GitHub。

| 动词 | 作用 |
|---|---|
| `start-swarm.sh`（**不再是公开 verb**，是 `provision forge` 的内部步骤：起 forge 自己时 Dashboard 还不存在） | 从停机状态显式启动 swarm；`--dashboard-port <N>` 可选，转成 `SWARMFORGE_DASHBOARD_PORT` 让 pack_web 绑固定端口（不传则一字不变地保持随机端口；只校验是数字，不校验范围；与 `--terminal` 累积进同一个 `env` 前缀，两者同时生效）；`--terminal` 必传（`ghostty`/`iterm2`/`none`/`terminal-app`/`windows-terminal`/`auto`），杜绝 #10 那次靠自动探测踩中 watchdog 拆除的坑；已在跑（socket 探活成功）拒绝重复启动（退出 6，无 override）；启动前还会取 project lock 并比对已装 `swarmforge/scripts` 与其 manifest 的 digest，manifest 缺失或不一致报 `STATUS=DRIFT`（退出 4），锁被另一次并发的 `start swarm` 占用同样报 `UNSAFE`（退出 6）——`--force` 可越过锁占用与 DRIFT，但越不过「已在跑」；本地/远端都走 `nohup` 脱离终端启动，回读 runtime 文件确认后才报 `STATUS=STARTED` |
| `open swarm <root>` | 把运行中的 swarm 以 cmux workspace 打开；停机时报原因，命中 window watchdog 拆除会点名，绝不代人启动 |
| `dashboard <root>` | 开 browser workspace 连 pack_web 看板；默认建 SSH 隧道，`--tailnet` 则不建隧道、直接打 target 的 tailscale IP（笔记本一睡隧道就断，且只有那台机器能看；tailnet URL 手机平板都能开）；**每次先读 `dashboard-url` 的端口决定走哪条**——在 `7780-7789` 段内就加 `--tailnet`，是随机端口就不加并把切换步骤报给用户（切换要停 swarm，不自作主张）；额外校验端口后面真是本项目的 `pack_web`（`--serve` 参数比对），不是同机别的项目撞上来的；**跑完要把报文里的 `URL=` 转述给用户，不能只回「已打开」** |
| `attach <role>` | 临时附加到某个角色的 tmux session |
| `wake <role>` | 唤醒：注入 `ready_for_next.sh`，按 backend 编码提交后**验证真的被消费**，没提交成功报错并点名 backend 不匹配 |
| `talk <role>` | 给指定角色发一条行为切片，同样验证送达且被提交，不是发了就算 |

默认远端是 `admin@100.64.0.4`，可用 `--target`/`--key` 覆盖；`--local` 改走本地文件系统。


### `open swarm` 契约

```sh
.agents/skills/swarmforge-operator/scripts/open-swarm.sh \
  --root <远端 project 根> [--window <ref>] [--target host] [--key path] [--local]
```

脚本负责全部 cmux 机制：runtime gate、相邻角色配对成双 pane workspace（奇数尾部单 pane）、以 description `swarmforge:<basename>@<host>` 认领与复用、逐 surface 验证 attach、失效 surface 最多重发一次 attach。Agent 只跑脚本、读退出码、汇报。

退出码：`0` OPENED/REUSED 成功；`3` STOPPED（swarm 未运行，拒绝启动）；`4` DRIFT（workspace 与 runtime 不符，零变更，需用户授权后重建）；`5` ERROR。

看板本身是 `pack_web`：`./swarm` 启动时随 swarm 一起起的本地 HTTP 服务，页面展示并可操作 swarm 状态（agent 状态、任务/交接、approvals、chat、teardown），只监听远端 `127.0.0.1`，所以远程访问必须走隧道。

`dashboard` 动词用 `scripts/open-dashboard.sh`（参数同上，另加 `--tailnet`）：按顺序问四件事，第一个「否」就停——**swarm 在不在跑**（读 `tmux-socket` 探 `list-sessions`，与 `open swarm`、`wake`/`talk role` 用的是同一条判定）→ 有没有 `dashboard-url` → 那个端口是不是本项目自己的 `pack_web` → 最后才是能不能连上。然后在当前 window 开/复用 `Dashboard · <basename>` workspace。**复用时会校验那个 browser surface 现在指向哪**（issue #99）：不是本次的 URL 就 `goto` 过去，已经一致则一个 cmux mutation 都不做。此前只在 surface **缺失**时才修，于是报文打印新 URL 而画面停在上一个已死端口——而这是常态不是例外，`pack_web` 每次启动都换端口（除非用了 `--dashboard-port`）。报文里的 `URL=` 与 surface 实际指向的一致，否则不报成功。

**顺序是修过的（issue #100）。** 停机会删 `pack_web.pid`，但**没有任何动词删 `dashboard-url`**，所以停机后这两个输入互相矛盾；而可达性检查排在前面时，一个只是停机的项目会报 `5` ERROR（「隧道坏了」）而不是 `3` STOPPED，`--tailnet` 那条还会让人去跑一条**已经跑过**的 `tailscale serve`。**有意的取舍**：swarm 停了而 `pack_web` 仍独活的项目现在会被 `3` 拒绝——这个动词开的是某个 swarm 的看板，swarm 不在就没有可看的东西。退出码语义同上；`3` 表示 dashboard-url 缺失，绝不自己起 `pack_web.sh --serve`。报文里的 `TUNNEL=` 说明走了哪条路：`created`/`reused`/`tailnet`/`local`。

**不带 `--tailnet`：** 建 `-N -L` 本地转发（已有可用隧道则复用；端口被占则换空闲端口），browser surface 指向隧道 URL。这条路径行为未变。

**带 `--tailnet`（issue #78）：** 完全不建隧道。隧道挂在操作者笔记本上，**笔记本一睡就断**，而且只有那台机器能看。managed host 本来就在 tailnet 里，所以脚本直接从 `--target` 取 tailscale IP，确认 `http://<ip>:<port>/` 答 200，browser surface 指向它。它需要端口固定、且该端口已发布——两件事的命令都在下面「切到固定端口」一节，只写在那一处。

**这个动词不执行任何 `tailscale` 命令**——不下发、不修复、不清理那份 serve 配置，只用 HTTP 观测结果。端口不答 200 时干净退出 `5` ERROR，报文里给出目标 URL 与该敲的命令原文，不建 workspace、不建隧道。`--tailnet` 配 `--local` 是 `2` USAGE（本机没有可走 tailnet 的 target）。归属检查在 `--tailnet` 这条路上照跑，而且更重要：固定端口比随机端口更容易被同机别的项目撞上。

**跑完把报文里的 `URL=` 说给用户。** 每次都打印，但只回一句「已打开」不算做完——tailnet 那个地址在任何设备上都能开，那才是操作者要拿走的东西。

**每次先判断走哪条路，别猜。** 读 `<root>/.swarmforge/dashboard-url` 的端口：在 `7780-7789` 段内 → 加 `--tailnet`；其他端口（内核随机分的）→ **不要加**，加了会正确地退 `5` ERROR，改为不带 flag 跑，并在同一条回复里告诉用户这个地址只在本机有效、笔记本一睡就断，以及下面的切换步骤。**别自己去跑切换**，第二步会停掉在跑的 swarm。过去的报文、别人引用的 URL、flag 存在与否，都不能用来推断当前端口是不是固定的。

#### 切到固定端口

四步，顺序不能变。第三步不能并进第二步：一个已在跑的 swarm 不会让你再起一个绑到别的端口，所以不停就换不了端口。

```sh
# 1. 在 target 上发布整个 dashboard 端口段。每台 host 一次性。
#    `tailscale serve` 没有 range 语法（`--tcp` 只收单个端口），所以一个端口一条；
#    `--bg` 的映射在重启与 `tailscale down`/`up` 之后自动恢复，
#    所以是**每个端口一辈子一次**，不是每次运行一次。
#    Linux target 上写 serve 配置要 root（读不用）：报
#    `Access denied: serve config denied` 就整条加 `sudo`，
#    或先 `sudo tailscale set --operator=$USER` 一次再以自己身份跑。
ssh -i <key> <target> \
  'for p in $(seq 7780 7789); do tailscale serve --bg --tcp $p tcp://127.0.0.1:$p; done'
ssh -i <key> <target> 'tailscale serve status'    # 确认十个都在

# 2. 停 swarm。  ← 会打断在跑的活，先问人。
scripts/stop-swarm.sh --root <root> --target <target> --key <key>

# 3. 用本项目分配到的端口重新起
scripts/start-swarm.sh --root <root> --target <target> --key <key> \
  --terminal <值> --dashboard-port 7780

# 4. 到这一步 flag 才有意义
scripts/open-dashboard.sh --root <root> --target <target> --key <key> --tailnet
```

**绝不用别的方式暴露 dashboard。** 第 1 步的 `tailscale serve` 是唯一被认可的路径：不要自己写端口转发或 proxy，不要自己加 `ssh -L`，不要改 `pack_web` 绑定的地址。它绑 `127.0.0.1` 是刻意的，好让没有 tailscale 的环境行为不变；在它前面加任何东西，都等于把一块带 Teardown 按钮的看板发布给所有能连到的人。上面这几步走不通就说走不通，不要临时发明一条路。

**第 2 步会打断 swarm 正在做的事，动手前必须问人**，并说清会打断什么（Dashboard 的 role heats 能看到哪些 role 在忙）。固定端口是便利，别人跑到一半的链路不是。第 1 步每台 host 只做一次，`tailscale serve status` 里已经有这个段就直接跳到第 2 步。

#### dashboard 端口分配

`7780-7789` 留给 dashboard。**一个 forge 一个号，不是一个项目一个号**——Forge 下的被管项目没有自己的 dashboard（`run-project!` 不起 `pack_web`），整个 forge 共用一个：

| forge | 端口 | 里面的项目 |
|---|---|---|
| macmini `~/project/forge` | `7782` | podsum |
| 未分配 | `7780`-`7781`、`7783`-`7789` | |

跨 host 其实不冲突，这张表是给人看 URL 用的。它是本 fork 操作者手工维护的约定：没有任何代码推导它，也没有任何检查强制它，`--dashboard-port` 不会拿它做范围校验。新 forge 取下一个空号，并在这里补一行。

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

