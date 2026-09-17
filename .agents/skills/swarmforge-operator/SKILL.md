---
name: swarmforge-operator
description: "Use when operating a running SwarmForge project from the local machine: opening its role sessions or its pack_web dashboard in cmux, attaching to a role terminal, waking a stuck role or sending it a message, publishing finished swarm work to GitHub as a pull request, or provisioning a whole forge (project-manager, lieutenant) from an empty directory and creating its first project. Reading role state and stopping a swarm are done in the dashboard, not here."
---

# SwarmForge Operator

从本地机器操作一个运行中的 SwarmForge project。SwarmForge 是 config-driven 的:
活动 topology 要从目标 project 的 runtime state 推导出来,不要按 two-pack、
four-pack、six-pack 或角色名分支。

**REQUIRED SUB-SKILL:** `cmux`。你自己动手做任何 cmux 操作之前先加载它(用户要求
新建 window、drift 恢复、检查某个 surface)。随包的 `open-swarm.sh` 脚本内部已经
遵守 cmux 契约,不要重新实现它的机制。

## Runtime inputs

每个 verb 都要先设定目标 project。macmini 的这几个值是默认值,不是 topology 的
一部分:

```sh
TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
ROOT=${ROOT:?set ROOT to the remote project root}
SSH=(ssh -i "$KEY" "$TARGET")

SOCK=$("${SSH[@]}" "cat '$ROOT/.swarmforge/tmux-socket'")
SESSIONS=$("${SSH[@]}" "cat '$ROOT/.swarmforge/sessions.tsv'")
ROLES=$("${SSH[@]}" "cat '$ROOT/.swarmforge/roles.tsv'")
MASTER=$(printf '%s\n' "$ROLES" | awk -F '\t' '$2 == "master" {print $1}')
```

启动之后,runtime 文件就是唯一的事实来源:

- `tmux-socket`:纯文本,内容是真实的 socket 路径。每次 `./swarm` 重启后都要重新
解析一遍。
- `sessions.tsv`:config 顺序、role、session、显示名、agent backend。
- `roles.tsv`:role、worktree 名/路径、session、显示名、backend、接收模式。worktree
名是 `master` 的那一行是 intake role。

runtime 文件缺失、socket 上没有 session、或者 master 行不是恰好一条,就停下。一台
主机可以跑多个 project;只碰 `ROOT` 下面的状态,以及从那个 project 读到的 socket。

## 什么不在这里做

lieutenant forge 的设计是**操作都在 Dashboard 上做**。以下动作没有 operator verb,去网页:

- **停一个 project** —— Dashboard 的 close(`POST /api/projects/close`)。它同时维护 forge
  自己的 `open-projects` 记录,而任何绕过它的停机都不会 —— forge 会继续认为那个 project
  开着。**这是本 skill 曾经有过 `stop swarm` 而现在没有的原因(issue #158)。**
- **停整个 forge** —— Dashboard 的 teardown(`/api/teardown`)。
- **起一个 project** —— Dashboard 的 open(`POST /api/projects/open`)。
- **读角色状态** —— Dashboard 的 `role_heats`、`work_in_flight` 与 agent pane 页,它们是
  活的,比一次性快照准。
- **切卡、批准、回答澄清** —— Board 与 Attention,那是 Host lieutenant 的地盘。

留在这里的六个 verb,每一个都做网页做不到的事:接入(`dashboard`)、附着(`open swarm`)、
往 pane 里打字(`wake role`/`talk role`)、装一个新 forge(`provision forge`)、
推 GitHub(`ship project`)。

## 被管 project 在哪

**一个 Managed project 永远住在 `<forge-root>/projects/<name>`。** 这是 upstream lieutenant
的布局,也是 ADR-0007 之后本 fork 唯一服务的布局。所有吃 `--root` 的 verb 都在动手之前
硬性校验这一点(`lib-wake-talk.sh` 的 `require_managed_project`),不满足就 `6` `BLOCKED`。

判据是两条,路径形状不算证据:

1. `$ROOT` 必须匹配 `*/projects/*`,`<forge-root>` 取 `${ROOT%/projects/*}`。
2. **那个 forge root 要被证实**:`<forge-root>/projects` 是目录,且 `<forge-root>/swarm` 存在。

**为什么需要这道闸。** 一个独立的 pack 安装和一个 forge 管的 project,从目录内部看是
**一模一样的** —— 同样的 `.swarmforge/`、同样的 `roles.tsv`、同样的 `handoffs/`。没有这道
闸,每个 verb 都会照常工作在一个本 fork 早已不服务的 Pack 安装上。这不是假想:
`ship project` 第一次真跑就跑在了一个休眠的 two-pack clone 上,它跟 forge 里那个真 project
**同名**,报文里一切看起来都正常,得出的结论全是错的。

## Verb contract

每个 verb 要么是 handover verb,要么是 report verb,要么是 effect verb(见
`CONTEXT.md`)。类型决定了它跑完时欠你什么。

**状态行与退出码。** 有脚本的 verb 第一行打印 `STATUS=<WORD>`。退出码在所有 verb
里是同一套含义:

- `0` —— verb 干完了它的活。
- `2` `USAGE` —— 参数不对。
- `3` —— 目标没在跑。绝不代为启动;那是人的决定。
- `4` `DRIFT` —— 记录的状态与真实状态不一致。修复前先问。
- `5` `ERROR` —— verb 失败了。
- `6` `UNSAFE` —— verb 拒绝做破坏性的活,因为它发现了一个必须由人先清掉的条件。
  什么都没改。
- `8` —— verb 停下来等一件只有人能提供的东西。不是失败:把那东西补上再跑同一条
  命令就接着往下走。(`ship project` 的 `NEEDS_PR_BODY`。)

**失败要用大白话说清原因。** `STATUS=` 行之后,失败的 verb 打印一句话告诉你该做
什么。没有机器可读的 reason 字段:脚本要分支就看退出码,那句话是给人看的。

**成功也可以说话。** verb 干完了活但发现了你必须知道的事,就打印一行或多行
`WARN=<one sentence>`,退出码仍然是 `0`。只报对本次运行成立、且以后可能变成不成立的
事实。永远成立的事实要在成因处修掉,不是拿来 warn 的:每次都出现的警告等于没人看
的警告。

**handover verb 的契约只到交接那一步为止。** 它检查它能检查的,然后把自己替换成
目标程序。之后的退出码属于那个程序,不属于这份契约。

**不是每个 verb 都已经有脚本。** `provision forge`、`open swarm`、`dashboard`、
`wake role`、`talk role` 和 `ship project` 今天已经有脚本并遵守这份契约。其余 verb 是本文件里的 shell 步骤;照写的跑,读它们的原始输出。把它们
纳入契约的工作记在 issue tracker 里。

## Verb: `provision forge`

从一个空目录到一个跑着的 forge,外加它里面第一个跑着的 project。这是 forge 那条路的
入口,对应 upstream README 的第 2–4 步。

```sh
scripts/provision-forge.sh --root <forge-root> \
  --forge <project-manager|lieutenant> --dashboard-port <N> \
  [--project <name> [--pack <two-pack|four-pack|six-pack>]] \
  [--mission <text>] [--terminal <value>] \
  [--target user@host] [--key <path>] [--local]
```

退出码 / STATUS 行:

- `0` `PROVISIONED` —— 报出 `ROOT`/`FORGE`/`URL`,建了 project 时再加
  `PROJECT`/`PACK`/`PROJECT_PATH`。
- `2` `USAGE` —— 参数不对。什么都不会尝试。
- `4` `DRIFT` —— 由 `start swarm` 抛上来的;它的 STATUS 行原样透传。
- `5` `ERROR` —— 装失败、来源校验不过、dashboard 没在预算内应答,或者建 project 被拒。
- `6` `UNSAFE` —— 目标目录不空且没有完整安装,或者 project 重名。什么都没改。

**为什么叫 `provision` 而不是 `start`。** 因为 `start swarm` 撞见已在跑的 swarm 是
`6` `UNSAFE` 且无 override,而本 verb 撞见已在跑的 forge 要跳过启动继续往下走 —— 同一个
动词在同一个条件上一拒一放,是给读的人埋雷。

### 它吃掉的三个陷阱

**来源。** upstream README 第 2 步的 helper URL 指向 `unclebob/swarm-forge`。从那棵树装出来
的 forge 既没有 D-1(收件箱按 `roles.tsv` 解析)也没有 D-5(handoffd 的对账与重试),
handoff 链在唤醒键被 TUI 吞掉时**静默**卡死 —— 不报错,只是不动了(ADR-0001/0002)。所以
安装走本 fork 的 `get-swarm-forge`,**并且装完从文件内容自证**:`handoffd.bb` 里要有
`reconcile-once!`,`handoff_lib.bb` 里要有 `roles.tsv`。「我传的参数是对的」不是证据。
文件是否存在也不是判据 —— 这两个文件 upstream 也有,只是内容不同。

天花板说在明处:两个 marker 不是全树等价性证明。upstream 哪天长出同名函数,这个判据就会
把 upstream 的树认成 fork 的。真正的等价性证明要重新下载本 fork 的同一分支再比 digest,
那是每次运行多一次下载,换一个还没发生过的失效模式 —— 等 marker 真的失效再换。

**启动。** 从 ssh 会话裸跑 `./swarm`,`osascript` 存在这一点就足以让
`detect-terminal-backend` 选中 `terminal-app`,而背后没有真实 window,window watchdog
几秒内就把整个 forge 拆了(issue #10,手工操作下已复现两次)。所以启动一律委托给
`start swarm`,白拿它的 detached 启动、readiness 轮询、project 锁和「已在跑就拒绝」那道
闸。**绝不自己拼 `ssh` + `nohup ./swarm &`,也绝不传 `--force`。**`--terminal` 默认
`none`:forge 跑在远端主机上,没有人会去看它的终端窗口,而 `auto` 正是 #10 的复现路径。

**manifest。** `get-swarm-forge` 装完 forge 后 `swarmforge/scripts/` 存在而
`.swarmforge/scripts-manifest` 从不存在,`start swarm` 的三态判定读作 INCOMPLETE 并以
`4` `DRIFT` 拒绝 —— 于是 `--force` 成了启动**任何** forge 的唯一办法,而 `--force` 同时
关掉 issue #29 建立的 digest 校验。ADR-0006 把这个责任放在这里:**装那棵树的 verb 负责写
描述它的 manifest。**`get-swarm-forge` 与 `start-swarm.sh` 都不改 —— 前者是 upstream 也
拥有的安装器,后者的三态判定本身是对的,缺的只是一个 writer。

manifest 只在**缺失**时写。已经存在却与树不一致,那是真的 drift,归 `start swarm` 报;
在这里覆盖掉它等于抹掉 issue #29 建起来的那个信号。`SOURCE_COMMIT` 写 `unknown`:
安装走的是分支 tarball,拿不到 commit id,而 `read_manifest` 从来只读 `DIGEST=`。

### 三个阶段,各自可续跑

| 阶段 | 已完成的判据 | 已完成时 |
|---|---|---|
| 装 | `$ROOT` 有 `swarm` 且有 `swarmforge/scripts` | 跳过,`WARN=`;manifest 缺失则补写 |
| 起 | `tmux-socket` 上有活 tmux server | 跳过,`WARN=` |
| 建 | `projects/<name>` 已存在 | `6` `UNSAFE`,零改动 |

所以「装到一半 / 起到一半被中断了怎么办」的答案是**同一条命令再跑一遍**。没有 `--resume`,
也没有为此新增的 STATUS 词。

`$ROOT` 存在、不空、又没有完整安装时是 `6` `UNSAFE`:那要么是一次撕裂的安装,要么是别人的
目录,而 `get-swarm-forge` 会毫不犹豫地往里面写。这道闸是写入边界上的守卫,不是状态机的
一环。

### 建 project 为什么只能走 HTTP

生产 `pack_web.bb` 的 `-main` 只认 `--serve`;所有 `--test-*` flag(含
`--test-new-project`)只在测试 harness 里 dispatch。绕过 HTTP 直接调 `forge.bb` 也不行 ——
那会让这个脚本变成 forge 的 open-projects 状态的第二个写者,而那份状态归跑着的 dashboard。
所以它 `ssh` 进目标主机、在那台机器上 `curl` `127.0.0.1`。**这不违反「绝不用任何其它方式
把 dashboard 暴露出去」** —— 那条禁的是往外暴露,主机内自访不在其内。这个 verb 不建隧道、
不写 `tailscale serve`、不改 `pack_web` 绑什么。

POST 之前要等两次:`start swarm` 的 readiness 只证明 tmux server 有应答,**不证明
`pack_web` 在听**。所以还要等 `.swarmforge/dashboard-url` 出现并且那个端口握手成功,预算
照抄 `dashboard` 的 20 次 × 0.5s —— 它等的是同一件事,一次 TCP 握手。

`POST /api/projects` 的 handler 是 `forge/instantiate!` 接 `forge/open-project!`,所以
2xx 意味着 project 目录建好了**并且**它自己的 swarm 已经被拉起。`409` 是这个端点唯一的
冲突状态,覆盖「已存在」与「已打开」两种 —— `forge.bb` 那个 `:error` keyword 到不了线上
(`http-error` 只序列化 message),所以分流看状态码,不看 body 字段。

**lieutenant forge 的 `--pack` 是可省的。** 它只有一个 project 模板
(`.swarmforge/project-pack`),它那份 `forge.bb` 的 `pack-dir` 干脆忽略 pack 名。
project-manager 才有 `packs/`,那里 `--pack` 是真选择。

## Verb: `open swarm`

**什么时候用它，而不是看 Dashboard。** Dashboard 的 agent pane 页是**只读 capture**
(`pack_web_pane.bb` 只有 `capture-pane`)。只想看一眼角色在干什么就去看网页;要一个**能打字
的附着终端**——翻历史、回答一个 TUI 提示、手工跑一条命令——只有这个 verb 给得了。

从本 skill 的目录跑随包的脚本;所有 cmux 机制都归它管(settle、输出解析、workspace
复用、attach 验证):

```sh
scripts/open-swarm.sh --root <project-root> [--window <ref>] \
  [--target user@host] [--key <path>] [--local]
```

它读 runtime 文件,以 tmux socket 活着为前置闸门,把 `sessions.tsv` 里相邻的
session 两两配成 `<Display 1> + <Display 2>` 的 workspace(落单的尾巴变成单 pane 的
workspace),复用按描述 `swarmforge:<basename>@<host>` 匹配到的既有 workspace 集合,
对失效的 surface 重发一次 attach,最后逐个验证每个 surface 都显示着自己的 session。

从它的输出和退出码读结果:

- `0` `STATUS=OPENED|REUSED` —— 把 `WORKSPACES`、`ATTACHED`、`REPAIRED`、
  `MASTER_DISPLAY`/`MASTER_WS` 报给用户。脚本不动用户的焦点;说清 master 在哪,
  而不是把焦点切过去。
- `3` `STOPPED` —— swarm 没在跑。报出原因然后停下。当消息点名 window watchdog 时,
  必须由人先修好 terminal backend 再重启 —— 原样重启只会重现同一次击杀。
- `4` `DRIFT` —— cmux 状态与 runtime 文件不一致(跑了一半,或 topology 变了)。关闭
  或重建任何东西之前先问用户。
- `5` `ERROR` —— 把消息显示出来;重试前先检查 cmux 状态。绝不用「再跑一次可能已经
  成功的 create」去试探。

这个 verb 的硬规则:

- **绝不启动一个停着的 swarm。** 不跑 `./swarm`,不重启,无论用户看起来多像是那个
  意思。启动是人的决定;`open` 只连接已经在跑的东西。
- **默认不开 macOS window。** 脚本作用在调用者当前的 window 上。只有用户明确要求
  新开 window 时,才按 cmux skill 自己创建,并传 `--window <ref>`。
- **没有用户明确批准就不做破坏性清理** —— 脚本什么都不关,你也不要关。

## Verb: `dashboard`

跑随包的脚本;它把 pack_web 的 dashboard 页面开成一个 cmux browser workspace:

```sh
scripts/open-dashboard.sh --root "$ROOT" [--window <ref>] \
  [--target admin@host] [--key ~/.ssh/key] [--local] [--tailnet]
```

它按这个顺序问四个问题,在第一个 `no` 处停下(issue #100):**swarm 在跑吗**
(读 `tmux-socket`,探 `list-sessions` —— 与 `open swarm`、`wake`/`talk role` 用的是
同一个判断)、**有
dashboard-url 吗**、**那个端口是不是本 project 自己的 `pack_web` 占的**,通过之后才
问**我够得着它吗**(隧道或 tailnet)。然后它按得到的 URL 打开或复用一个叫
`Dashboard · <basename>` 的 workspace,里面有一个 browser surface。

**被复用的 surface 是要校验的,不是假定的**(issue #99)。存在不等于正确:surface
选取器只按类型匹配,从不看 url,而复用路径只修复*缺失*的 surface —— 于是报文打印
的是本次运行的 URL,屏幕却停在上一个已经死掉的端口上。这不是罕见情况而是常态:
除非 project 传了 `--dashboard-port`,`pack_web` 每次启动都绑一个新端口,所以只要
重启过一次,被复用的 surface 就一定是陈旧的。这个 verb 现在会读 surface 实际指向
哪里(`cmux browser --surface <ref> get-url`),不是本次运行的 URL 就导航过去;
已经一致时则完全不做任何 cmux 变更。报文里的 `URL=` 就是 surface 指向的地址,否则
这个 verb 不报成功 —— 前面几个问题证明*服务端*是对的,这一个证明*屏幕*是对的。

顺序是要紧的,而且过去是错的。停机会删 `pack_web.pid`,但**没有任何东西
会删 `dashboard-url`**,所以停机之后这两者互相矛盾 —— 而当可达性被最先检查时,一个
停着的 project 死于 `5` `ERROR`(「隧道坏了」)而不是 `3` `STOPPED`。在 `--tailnet`
路径上它还更进一步,叫 operator 去跑一条他们已经跑过的 `tailscale serve` 命令。一个
没在跑的 swarm 既没有端口可达、没有所有者可辨认、也没有 workspace 可打开,所以现在
这个问题最先问。

**一个刻意的后果:** 一个 swarm 停着、但 `pack_web` 不知怎么还活着的 project,现在
会被 `3` 拒绝。这个 verb 打开的是*某个 swarm 的* Dashboard;没有 swarm 就没什么可看
的。Dashboard 的 close 会连 `pack_web` 一起收,所以这种状态只在有东西绕过正常停机路径时
才出现。报文里的 `TUNNEL=` 说明走了哪条路:`created`、
`reused`、`tailnet` 或 `local`。

### 怎么跑它

下面这几个设一次,然后按顺序跑各步骤。`SF` 是本 skill 的 `scripts/` 目录。如果
dashboard 就在你所在的这台机器上,照着 `# local:` 注释走:`REMOTE=(--local)`,
读文件时不走 `ssh`。

```sh
SF=.agents/skills/swarmforge-operator/scripts
ROOT=/Users/admin/project/forge/projects/podsum   # <forge-root>/projects/<name>, on its host
TARGET=admin@100.64.0.4                   # omit for a local root
KEY=~/.ssh/tailscale_key                  # omit for a local root
REMOTE=(--target "$TARGET" --key "$KEY")  # local: REMOTE=(--local)
```

**第 1 步 —— 读端口。**

```sh
PORT=$(ssh -n -i "$KEY" "$TARGET" "cat $ROOT/.swarmforge/dashboard-url" | sed 's#.*:##; s#/##')
# local: PORT=$(sed 's#.*:##; s#/##' "$ROOT/.swarmforge/dashboard-url")
echo "$PORT"
```

**第 2 步 —— 按它分支。**

```sh
case $PORT in
  778[0-9]) echo "fixed   -> step 3" ;;
  *)        echo "random  -> step 5" ;;
esac
```

**第 3 步 —— 固定端口:走 tailnet 打开它。**

```sh
"$SF"/open-dashboard.sh --root "$ROOT" "${REMOTE[@]}" --tailnet
```

预期 `TUNNEL=tailnet`。如果得到 `5` `ERROR` 并点名某个未发布的端口,跑一次第 6a 步
再重复这一步。然后去第 4 步。

**第 4 步 —— 完成。把报文里的 `URL=` 那行打在你的回复里。** 不是「已经打开了」——
要地址本身,因为那才是用户在手机上能打开的东西。

**第 5 步 —— 随机端口:走 ssh 隧道打开它,然后停。**

```sh
"$SF"/open-dashboard.sh --root "$ROOT" "${REMOTE[@]}"
```

预期 `TUNNEL=created` 或 `reused`。把 `URL=` 那行打出来,**并且**说明它只在这台机器
上有效、笔记本一睡就断。把第 6 步作为选项提出来,不要动手跑。第 6b 步会打断正在进行
的工作,所以那是用户的决定。

**第 6 步 —— 把这个 project 切到固定端口。只在用户同意之后做。**

```sh
# 6a. publish the range — ONE-TIME PER HOST; skip if `serve status` lists it.
#     Writing serve config needs root on a Linux target (reading does not):
#     "Access denied: serve config denied" means run the loop under `sudo`,
#     or do `sudo tailscale set --operator=$USER` once and re-run as yourself.
ssh -i "$KEY" "$TARGET" 'for p in $(seq 7780 7789); do tailscale serve --bg --tcp $p tcp://127.0.0.1:$p; done'
ssh -i "$KEY" "$TARGET" 'tailscale serve status'

# 6b. stop it from the Dashboard (ASK FIRST) — close the project, or tear the
#     forge down. That path also maintains the forge's own open-projects record.

# 6c. start it again from the Dashboard on the port from the table below,
#     or re-provision the forge with --dashboard-port <N> (7780, 7781, ...)

# 6d. go back to step 3
```

**停机这一步不能跳过**:一个已经在跑的 swarm 不会让你再起一个绑到别的端口。`tailscale serve --bg` 能扛过重启和 `tailscale down`/`up`,而
`--tcp` 一次只吃一个端口(没有范围语法),这就是 6a 要写成一个每台主机跑一次的循环
的原因。

**绝不用任何其它方式把 dashboard 暴露出去。** 6a 是唯一获准的路径。不要写端口转发
或代理,不要自己加 `ssh -L`,不要改 `pack_web` 绑什么。它绑 `127.0.0.1` 是有意的,
这样一台没有 tailscale 的主机行为跟以前完全一样;在这之前加任何东西,都等于把一个
Teardown 按钮发布给所有够得着它的人。如果这些步骤走不到,就说出来然后停下 —— 不要
临时发明一条路线。

### Dashboard 端口分配

`7780`-`7789` 留给 dashboard。**一个 forge 一个号,不是一个 project 一个号** —— Forge 下的
Managed project 没有自己的 dashboard(`swarmforge.bb` 的 `run-project!` 不起 `pack_web`),
整个 forge 共用一个:

| forge | port | 里面的 project |
|---|---|---|
| macmini `~/project/forge` | `7782` | podsum |
| unassigned | `7780`-`7781`, `7783`-`7789` | |

端口跨主机其实不会真的冲突 —— 这张表存在的意义是让读 URL 的人知道那是什么。它是
本 fork 的 operator 手工维持的一条约定:没有任何东西推导它,没有任何东西强制它,
`--dashboard-port` 也不会拿它做范围校验。给新 forge 分配下一个空号,并在这里加
一行。

### `--tailnet` 为什么存在

不带这个 flag 时,脚本建一条到该端口的 SSH local-forward。那条隧道活在 operator 的
笔记本上:**笔记本一睡它就死**,而且别的设备用不了。`--tailnet` 跳过隧道,直接从
`--target` 里取目标机的 tailscale IP,确认 `http://<ip>:<port>/` 返回 200,然后把
browser surface 指过去。

这个 verb **不跑任何 `tailscale` 命令** —— 它只通过 HTTP 观察;端口没有应答时它以
`5` `ERROR` 退出并给出该跑的命令,同时既没建 workspace 也没建隧道。`--tailnet` 与
`--local` 同时用是 `2` `USAGE`:没有目标主机可以在 tailnet 上够。它不是默认行为;
ssh 那条路径原样不变。

端口归属:HTTP 200 只能证明那个端口上有东西应答,不能证明那是本 project 的
dashboard —— 在一台跑着多个被管 project 且端口动态分配的主机上,一个陈旧的
`dashboard-url` 可能撞上另一个 project 的 `pack_web`。脚本读
`$ROOT/.swarmforge/pack_web.pid`,确认那个进程的 `--serve` 参数等于 `$ROOT`,并且
是直接对着 `$TARGET`/本地跑这项检查的(隧道只承载 HTTP,不带进程身份)。硬规则和
退出码与 `open swarm` 相同:退出 3 STOPPED 意味着 dashboard-url 缺失,或者
`pack_web.pid` 缺失/它的进程死了 —— 绝不要自己去跑 `pack_web.sh --serve`;退出 4
DRIFT 意味着要么匹配到多个 workspace,要么那个端口被另一个 project 的 `pack_web`
占着 —— 在归属这种情况下,是别人的 dashboard 蹲在记录的端口上,由人来决定,脚本
永远不自动修;退出 5 ERROR。`--local` 期望 dashboard 已经在这台机器上监听,并在本地
跑同样的归属检查;不建隧道。归属检查在 `--tailnet` 路径上同样跑,而且在那里更要紧:
固定端口比过去的随机端口更容易成为撞车目标。

## Verb: `attach role`

在 `sessions.tsv` 里找到这个角色,用它记录的 session;不要拿一份硬编码的角色列表去
拼 session 名:

```sh
ssh -tt -i "$KEY" "$TARGET" "tmux -S '$SOCK' attach -t '$SESSION'"
```

## Verb: `wake role`

跑随包的脚本;它自己从 `sessions.tsv` 解析出 session 和 backend,并验证唤醒真的落
到了,而不是信任一个陈旧的猜测:

```sh
scripts/wake-role.sh --root <project-root> --role <name> \
  [--target user@host] [--key <path>] [--local]
```

它键入 `ready_for_next.sh`,确认文本到达了输入行,用该 backend 自己的按键编码提交
(`claude` 用 CSI-u Enter,其它所有 backend 用裸回车 —— 见 `handoffd.bb` 里的
submit-keys;绝不用 `C-m`/`C-j` 这类符号键名,因为一个协商过 extended keys 的 TUI
不会通过 tmux 的按键编码层收到一个字面 Enter),然后确认输入行里不再有它。

退出码 / STATUS 行:

- `0` `WOKEN`
- `2` `USAGE` —— 缺 `--root` 或 `--role`
- `3` —— `sessions.tsv`/`tmux-socket` 缺失,或者 socket 上没有 tmux server;swarm
  没在跑,绝不要启动它
- `5` `ERROR` —— 这个角色不在 `sessions.tsv` 里、文本始终没到达输入行,或者到了但
  从未被提交(失败那句话会点名记录在案的 backend —— 拿它跟那个 session 里实际在跑的
  agent 对一下,见 issue #14)

**边界:** `--role` 永远不接受 `--backend` 覆盖;`sessions.tsv` 里记录的 backend 是
唯一来源,因为调用方给的猜测正是这个脚本存在要抓的那种静默失败。

## Verb: `talk role`

跑随包的脚本;与 `wake role` 是同一套「发出去再验证」的契约,只是发的是一条行为切片
而不是 `ready_for_next.sh`:

**网页替不了它。** chat rail 只通 Host lieutenant(`post-chat` → `notify-lieutenant!` →
`inject-role! forge "lieutenant"`),没有任何端点能把任意文本送进某个 project 角色的 pane。
想跟一个 coder 说话,只有这条路。

```sh
scripts/talk-role.sh --root <project-root> --role <name> --message <text> \
  [--target user@host] [--key <path>] [--local]
```

退出码 / STATUS 行:与 `wake role` 同一张表(`0` `SENT`、`2` `USAGE`、`3`、
`5` `ERROR`),同样有那条「文本到了但从未被提交」的 ERROR,并在不匹配时点名 backend。

**边界:** 一条丢掉的 `talk role` 消息是一次丢掉的派发,不只是一次没戳到 —— 验证提交
那一步在这里比在 `wake role` 里更要紧。那一步判断的是输入行,也就是丢掉尾部任何静态
footer **之后**的最后一行非空行。改读物理意义上的最后一行,正是让每一次 Grok 派发都
报 `STATUS=SENT` 却没确认提交键落地的原因(issue #58);而往 pane 更上面读又会把
issue #28 带回来,那次是停在 transcript 历史里的文本被读成了未发送。就是那一行,而
footer 是唯一被跳过的东西。新活从 `roles.tsv` 的 `master` 行进入;没有哪个角色名
(比如 `specifier` 或 `coder`)是普适的 intake role。常规的任务进入方式是 Dashboard
的 New Task,不是 `talk role`:New Task 会创建 Board 卡片,并把稳定的任务名一路带到
`ship project` 读的那个终端 handoff(issue #39)。`talk role` 是给一个运行中的角色
发一条行为消息 —— 它从不创建 Board 任务,也不是 New Task 的替代品。

## Verb: `ship project`

把 swarm **已经干完的活**推上 GitHub，停在一个可 review 的 PR 上。

卡由人在 Dashboard 上切、或由 Host lieutenant 按 `.swarmforge/routes.tsv` 切并推进，
所以这个 verb **既没建过分支，也不提前知道任何 task 名**。它要发什么，全部从 managed
project 自己磁盘上的状态推出来。

而上游到那里就停了。它的 work lifecycle 最后一步写的是「the board moves the card to
Done」，没有第七步；`upstream/lieutenant` 整个分支的 prompt、脚本与文档里搜不到
一处 `git push` 或 `gh pr`，唯一的 GitHub 接触点是 `forge.bb` 把仓库 **clone 进来**。
`lieutenant.prompt` 里的 git 词汇是被刻意清空的：`Never git_handoff. Never merge.`、
`Never git reset yourself.` 最后一公里在 forge 外面，是设计如此，不是缺口。
**不要在 chat rail 里让 lieutenant 去 push。** 它确实是个有 shell 的 agent，但那是
跨出自己 prompt 的即兴发挥，Attention 与 board 都不会留下这次动作的痕迹。

```sh
scripts/ship-project.sh --root <managed-project-root> \
  [--target user@host] [--key <path>] [--local] \
  [--branch <name>] [--base <name>] [--issue <N>]... \
  [--body-file <path>] [--dry-run]
```

**它不走 Dashboard。** 看板、handoff、git 全部从 managed project 自己磁盘上读，所以
`pack_web` 没开也能跑，**Forge 下的 project 也能跑** —— 那种 project 根本没有自己的
`dashboard-url`（`swarmforge.bb` 的 `run-project!` 不起 `pack_web`，只有 Forge 自己那一个）。

### 四道门，按顺序，任一失败就停

**A 定位。** 三种指错地方各自有自己的拒绝语，因为修法不同：`.worktrees/*` 是
生成的角色 checkout（它们坐在 `swarmforge-<name>` 分支上）；forge 根持有 `projects/`
根本不是产品仓；一个子目录会把整个仓推上去却报出一个不是它根的路径。比对
用的是 **解析后**的路径（`pwd -P`），不是你敲进去的字符串 —— git 答的是解开符号
链接的路径，字面比较会把一个完全正常的产品根拒之门外。

**B 看板。** 读 `.swarmforge/board/tasks.tsv`，**不走 dashboard** —— `pack_web` 每次启动
都绑新端口，而人决定发布的时候它未必开着。lane 在看板的每一个版本里都是第 2 列。
在角色 lane 里的卡**阻断**（活干到一半，现在发就是把它切断）；`waiting` 卡**只报
不阻**，计划没做完不是拒绝发布已经做完那部分的理由。

**C 投递失败。** 一次失败且一直没好的投递意味着一棵链条从来没闭合，覆在它上面发布
就是发一棵缺一跳的树。**两条路径都查**，因为两条血统给同一件事起了不同的名字：

- `handoffs/*/failed/`（每个 worktree 一份）—— `handoffd.bb` 的 `fail!` 把永久失败的
  handoff 挪到这里。**本仓自己的 main 血统代码写的是这个，今天会触发的也是这个。**
- `.swarmforge/delivery_attention/` —— lieutenant 血统给同一状态的名字。本仓没有，留着是
  为了同步那条分支之后这道门仍然有效。

只查 `delivery_attention/` 曾经是个 bug：本仓根本不创建那个目录，所以这道门**每次都
静静地放行** —— 一道永远不会触发的门比没有门更坑，它看起来像保护。注意空目录不算：
`prepare-handoff-dirs!` 给每个 worktree 都建了 `failed/`。

**D git 卫生。** 工作区有未提交改动就阻断并点名文件，**绝不代你 commit** —— swarm
跑完后还在 managed project 工作区里的东西，不是某个角色的残留就是人的手改，两者
都不该进一个没人 review 过的 PR。随后 `git fetch origin`，BASE 默认 `origin/main`，
没有就 `origin/master`，都没有就停下来说先加 remote。

**落后只报不阻。** 报告里的 `behind N` 和一条 `WARN=` 告诉你 swarm 是在一个已经移动了的
 base 上干的活 —— 就是「合并后没人 `git pull`」那个坑换了扇门进来。

**为什么只报不阻。** 活已经干完了，拒绝只会把它扒在那里，而 PR 本身仍然是对的（GitHub
按 merge-base 出 diff）。你需要知道的是这批活建立在一个已经移动了的 base 上，不是被拦住。
同一句话会跟进 PR 正文。

**没有 E。这个 verb 不跑你的测试(issue #170)。** 它曾经跑过:自动发现入口、执行、红就
阻断。那建立在一个**在一般情况下为假**的假设上 —— 这个 verb 恰好 ssh 进去的那台主机,
能有意义地跑起 managed project 的测试套件。跑不起来:一个套件需要那个 project 的环境,
而这个 verb 没有资格去搭一个。

**实测怎么塌的。** 在 podsum 上它猜了 `pytest -q`,而那个 project 自己的 CI 跑的是
`python -m unittest discover -s tests`,并且在此之前先装两个依赖组。结果是 20 个
collection error、0 个测试执行,报文却说 `tests failed` —— 一句关于 swarm 产出代码的断言,
实际上是一句关于缺了个模块的断言。这两件事的处理方式完全相反。

**这道检查本来就不必住在这里。** swarm 的角色在交接前自己验证(constitution 的
`engineering.prompt`),而这个 verb 开出来的那个 PR,会被 project 自己的 CI 在
`pull_request` 上测 —— 用对的命令、在准备好的环境里、在任何人合并它之前。一个没有 CI 的
managed project 确实有缺口,**而那个缺口的修法是给它加 CI,不是让一个 operator verb
假装自己是 test runner。**

报文里不再有 `tests:` 行,`--test-cmd` 也撤了。

### 它存在的真正理由：Done 与已合入是两件事

上面四道门里没一条是这个 verb 的核心。核心是第五条检查：

`handoffd` 是在它**投递**终端 handoff 的那一刻把卡标成 `done` 的，master 合入它是
之后的事。在这个窗口里发布，`git log origin/<base>..HEAD` 会安静地带着一个
**子集** —— 一个看起来完整、实际少了一张卡的 PR。所以每条交付记录的 commit 都要
过一遍 `git merge-base --is-ancestor <commit> HEAD`，差一条就阻断并点名，绝不聆聆
肩。过一会儿再跑就好。

「要发什么」这一半曾经是独立的 `accept work` verb，issue #158 把它折了进来。它拿下两个
难点 —— 只从 master worktree 读终端记录，以及排掉 commit 已经到了 origin 的任务。

### 两趟

```text
第一趟  ship-project.sh --root R
          报告 → 四道门 → 建分支 → git push
          → STATUS=NEEDS_PR_BODY（退出 8）
你       派一个子代理：用 to-pr skill 读 origin/BASE..BRANCH 写正文
第二趟  ship-project.sh --root R --body-file <那个文件>
          → gh pr create
```

想先看报告、连分支都不要建，用 `--dry-run`。

分支是在 HEAD 上 **建出来而不 checkout** 的。产品 checkout 留在 swarm 把它留下的
那条分支上，`.worktrees/` 下的角色各自守着自己的 `swarmforge-<name>`；在这里
`checkout` 会把树从正在干活的 agent 脚底下抽走。默认分支名
`feat/swarm-<project>-<yyyymmdd>`，`--branch` 可改。

### PR 正文：字段归脚本，散文归你

**字段归脚本，散文归你。** 脚本只写下游要解析的东西；读过 diff 才写得出来的那几段归你。

`Closes` 只有**一个来源，而且它不是猜的**：

**`--issue N`（可重复）。** 这个 PR 要关掉的每个 issue 都自己写一遍。`#42` 和 `42` 都收。
**不写就一个都不关**，报告里那行是 `will close: none`。

卡文本和卡名都不再参与推导（issue #173）。卡文本里的 `#N` 可能是「实现 #195」、
「见 #160 的分析」、也可能是「别碰 #203 那条路径」，**没有正则能把这三种分开**，区别在
句子里不在语法里。这个 verb 开的第一个真 PR 就因此挂了一个毫不相关的 `Closes #160`。
**关错一个 issue 比一个都不关更糟。**

`--issue` 的结果在报告的 `will close:` 一行里，而且它印在**停在 `NEEDS_PR_BODY` 那一趟**，
比 PR 早 —— 漏了或写错还有一趟可以改。

脚本追加的是卡列表、验证结果、看板计数和发布源路径；你写的是读过 diff 才写得
出来的那几段。空的或不存在的 `--body-file` 都是硬失败，**不回退到元数据正文**：
一个空正文的 PR 看起来完成了、却什么都没说。

按 SwarmForge 自己的文风，**handoff 协议字段、tmux、helper 脚本名不进 PR 正文**。

### 它拒绝做的事

- **绝不 `--force` push、绝不代提交、绝不 merge PR。** merge 是人的决定。
- **绝不从 `.worktrees/` 发布。**
- **绝不开第二个 PR。** push 之后、要正文之前先查这个 head 上有没有开着的 PR，
  所以一次被杀在 push 与 PR 之间的运行，重跑时不会再开一个，也不会为一份没用的
  正文花一次模型调用。

退出码 / STATUS 行：

- `0` `PR_OPENED` —— 报文末尾带 `url:`。
- `0` `NOTHING_TO_SHIP` —— 没有未交付的终端记录，或 HEAD 没超前 `origin/<base>`。
  不是错，没有任何东西被推。
- `0` `DRY_RUN` —— `--dry-run`，只出报告。
- `2` `USAGE`、`5` `ERROR`。
- `6` `BLOCKED` —— 门没过。报告照样打印，末尾带 `blockers:` 列表；什么都没改。
- `8` `NEEDS_PR_BODY` —— 分支已推，PR 未开，等你的 `--body-file`。

报告在**每一条路径**上都打印，包括被阻断的那一条：拒绝的理由只有跟它读到的
状态放在一起才有用。

## 内部实现：`start-swarm.sh`

**这不再是一个公开 verb（issue #158）。** 起一个 project 走 Dashboard 的
`POST /api/projects/open`；这个脚本留着只为一件事:**起 forge 自己**，而那一刻 Dashboard
还不存在——引导问题，网页不可能自解。`provision forge` 已经在委托它。

**不要拿它去启动 forge 管的 project。** `swarmforge.bb` 的 `-main` 判断 `forge-root?`，
project 根不是 forge 根,于是走 `run-main!`,而 `run-main!` **会 `start-pack-web!`**;
forge 自己起它走的是 `run-project!`,**不起**。结果是多出一个 forge 不知道的 dashboard。

下面的契约原样有效,只是调用方从人变成了 `provision forge`。


跑随包的脚本;它用「刻意」的方式启动一个停着的 swarm(issue #26),与 `open swarm`
拒绝自动启动(issue #10)是一体两面。今天唯一的替代路径是手工 `ssh` 加
`nohup ./swarm &`,而手工路径留给记忆的那个细节 —— 不指定的话 `./swarm` 会自动
探测的 terminal backend —— 正是 #10 那次事故的根因:从一个没有真实终端的 ssh 会话
里启动,`osascript` 存在这一点就足以让 `detect-terminal-backend` 选中
`terminal-app`,而背后根本没有真实 window,于是 window watchdog 找不到那个 window,
几秒之内就把整个 swarm 拆了。这种失效模式在手工操作下已经复现过两次。

```sh
scripts/start-swarm.sh --root <project-root> --terminal <value> \
  [--target user@host] [--key <path>] [--local] [--force] \
  [--dashboard-port <N>]
```

`--terminal` 是**必传的**,不是可选的环境变量透传 —— 跟 `--force`
不同,那个是人在知情的前提下豁免一次状态检查;`--terminal` 是跟 `--root` 一样的
必选项:#10/#26 那次事故说明的正是这个选择永远不能被悄悄跳过。可接受的值是
`ghostty`、`iterm2`、`none`、`terminal-app`、`windows-terminal`(与
`SWARMFORGE_TERMINAL` 接受的规范 backend 同一套 ——
`swarmforge/scripts/terminal-adapters/*.sh` 下一个文件一个),外加 `auto`:「我知道有自动探测这回事,
我明确选择用它。」`auto` 永远不会被原样转发给 `SWARMFORGE_TERMINAL` —— 选了 `auto`
时脚本干脆完全不导出那个变量,让 `detect-terminal-backend` 自己的 fallback 链原封
不动地跑。其它任何值都是 `2` `USAGE`,跟缺 `--root` 一样。

**自己拥有 snapshot 的 project 不做 drift 检查**(issue #88)。这个 verb 原本区分的
三种状态 —— FRESH、MANAGED、INCOMPLETE —— 都假设 `swarmforge/scripts` 是 operator
装的,所以 manifest 描述的就是它。当被管 project 自己把那棵树纳入版本控制时,
manifest 就没有什么可「说对」的了:回滚到 project 自己提交的版本会让每一次启动都
报 `4` `DRIFT`,`--force` 于是成了启动的常规做法。状态改由 `git ls-files` 推导。报文会说明它处在哪个世界:`SNAPSHOT=project-owned` 或
`SNAPSHOT=operator-managed`。

`--dashboard-port <N>`(issue #78)会被转发成 `SWARMFORGE_DASHBOARD_PORT`,
`pack_web` 于是绑这个端口,而不是向内核要一个随机的。不传就什么都不导出 ——
`pack_web` 一字不变地保持它一直以来随机挑的端口。`dashboard --tailnet` 需要的正是
固定端口:随机端口没法发布到 tailnet 上,因为根本没有稳定的 URL 可发布。只校验形状
(是数字,否则 `2` `USAGE`);一台主机怎么分配端口是那台主机自己的约定,SwarmForge
对此没有意见。`--terminal` 与 `--dashboard-port` 累积进同一个 `env` 前缀,所以两者
一起到达 launcher。

动手之前,它先检查 swarm 是不是已经在跑 —— 与 `open-swarm.sh` 用的
是同一次 socket 探活读取,只是判断反过来:socket 有应答就意味着再启动一次会拉起
第二个 daemon 和一个撞名的第二个 tmux session,所以它拒绝。一个背后没有活 server
的陈旧 `tmux-socket` 文件(`open swarm` 已经会点名的那种 watchdog 击杀残留)才是
这个 verb 存在意义上要恢复的「停机」状态,不是「已在跑」—— 它会继续启动。

接着,它取一把 project 范围的锁(issue #29),位置在
`$ROOT/.swarmforge/update-lock`,用来排斥同一个被管 project 上并发的另一次
`start swarm` —— 锁已经被人持有就是 `6` `UNSAFE`,并点名持有者。然后,除非传了 `--force`,它会重算被管 project 已装的 `swarmforge/scripts/` 的
确定性 digest,与 `$ROOT/.swarmforge/scripts-manifest` 比对。两个身份 artifact 中
哪些存在,决定接下来发生什么(issue #35):

- **Fresh** —— snapshot 和 manifest 都不存在。这是一个刚建好还没跑过的 project,
  首次运行的 bootstrap 归它自己的 launcher 管,所以 `start swarm` 交接给它,而不是
  拒绝。Fresh 不等于「忽略不一致」:它就是「两者都不存在」这一个精确
  状态。
- **Managed** —— 两者都在。digest 在启动前验证,因此也在任何角色 worktree 镜像有
  机会传播顶层树之前。issue #29 的逐角色保真检查只能证明某个角色的副本与它的来源
  一致,所以一棵损坏的顶层树要么在这里被抓住,要么根本抓不住。
- **Incomplete** —— 恰好只有一个在。装到一半;`4` `DRIFT`,绝不猜哪边是对的。

digest 不匹配同样是 `4` `DRIFT`,而且绝不调用 launcher —— 正是这种失效模式让一个
跑起来的 swarm 带着自家 launcher 不认识的必需脚本走到了 handoff。`--force` 同时
越过锁竞争和 drift 检查(但越不过上面那条「已在跑」,那条没有 override):它抢走
被持有的锁,并完全跳过 digest 比对。这把锁在脚本余下的部分里一直持有,包括启动和
就绪轮询,并在每一条退出路径上释放 —— **只有一个例外**:fresh-bootstrap 路径上的
就绪超时会刻意继续持有它。就绪预算是按「启动一份已装好的 snapshot」估的,而首次
运行还要下载一份,那是无界的;在那里超时并不能证明 launcher 停了,而释放锁会让一次
重试或一次并发的 `start swarm` 变成针对一份仍在进行中的安装的第二个写者。之后要清掉它,就得显式地用 `--force`。

启动本身是脱离终端跑的,本地远端都一样:`SWARMFORGE_TERMINAL=<value> nohup ./swarm
>log 2>&1 &`(选 `auto` 时不带那个环境变量),绝不是裸的前台 `./swarm` —— 裸启动
恰恰活不过启动它的那个 ssh 会话(或本地 shell)关闭,而这是 #10 事故成因的另一半。
然后它轮询其它每个 verb 都信任的那些 runtime 文件(先 `tmux-socket`,再
`tmux -S "$SOCK" list-sessions`),直到它们确认 swarm 真的起来了,而不是因为启动
命令发出去了就报成功。

退出码 / STATUS 行:

- `0` `STARTED` —— swarm 起来了;报出 `SOCK`/`TERMINAL`。
- `2` `USAGE` —— 缺 `--root`、缺 `--terminal`、`--terminal` 不在可接受值里,或者
  `--dashboard-port` 不是数字。什么都不会尝试。
- `4` `DRIFT` —— 已装的 `swarmforge/scripts/` 与 `$ROOT/.swarmforge/
  scripts-manifest` 不匹配,或者后者缺失(issue #29)。launcher 绝不会被调用;让 forge
  重新 open 这个 project 把树铺回去(`forge.bb` 的 `refresh!` 每次 open 都 overlay),
  或者传 `--force` 强行启动。
- `5` `ERROR` —— runtime 文件在预算内始终没有确认就绪。这同时覆盖 `./swarm` 非零
  退出和它单纯没能就绪两种情况:启动是刻意脱离终端的(见上),所以这个脚本从不检查
  launcher 自己的退出码,只看它最终应该产出的 runtime 文件 —— 去看消息里点名的那份
  启动日志。
- `6` `UNSAFE` —— swarm 已经在跑;拒绝启动第二个 daemon。什么都没改。现在这条也覆盖
  project 锁被另一次并发的 `start swarm` 持有的情况(issue #29),并点名持有者 ——
  与「已在跑」不同,`--force` 能清掉被持有的锁。

**边界:** 这个 verb 只管「从零到一」。要不要 `--force` 覆盖一个已经在跑的 swarm 去
重启、还是等一个正在拆除的跑完,是 Dashboard 与 `open swarm` 的地盘,不是它的。
它也不修 window watchdog 自己那个空 window-ID 的误判(那是 launcher/watchdog 侧的
缺陷)—— 它只是让 operator 不至于经由这个 verb 意外撞上去。issue #29 加的锁与 drift
preflight 守的是进入同一个「从零到一」步骤的入口;它们没有扩大这个 verb 本来做的事。
一旦 launcher 自己接手,它会独立地做镜像(删掉重建,不是覆盖写),并在每个角色启动
前校验该角色的 `swarmforge/scripts/` 与已装的来源一致,所以一份陈旧的逐角色副本不
可能比这个 verb 自己的 project 级检查活得更久。

## Testing

`scripts/test-ship-project.sh` 用真 git、桩 `gh` 跑 `ship-project.sh`：`origin` 是一个
本地 bare 仓，所以 fetch/push/rev-list/merge-base 全是真跑的（换成桩 git 就变成在测桩），
只有会真的碰 GitHub 的 `gh` 被打了桩。覆盖快乐路径（报告、建分支、恰好一次 push、停在
`NEEDS_PR_BODY` 且不开 PR）、带正文的第二趟（恰好一次 `gh pr create`）、head 上已有开着
的 PR 时返回旧 URL 且不再创建、一张在角色 lane 的卡阻断而一张 `waiting` 卡不阻断、未提交
改动阻断并点名文件、`delivery_attention` 阻断、**Done 且有交付记录但 commit 还不是 HEAD
祖先时阻断**（master 还在合并的那个窗口，这是这个 verb 存在的理由）、
无未交付记录时 `NOTHING_TO_SHIP` 且不建分支、角色 worktree 与 forge 根各自被拒、空的和
不存在的 `--body-file` 都硬失败且不开 PR、`--dry-run` 不建分支，以及一张 lieutenant 风格
命名的卡不产生任何 `Closes` 行。这五处若被改坏都会红（已实测：去掉「不是 HEAD 祖先」阻断、
去掉脏工作区门、去掉 PR 幂等检查、把 `waiting` 当成 live）。

`test-ship-project.sh` 后来又补了三组，对应本仓真实血统而不是 upstream 文档：
一次**永久失败的投递**在 project 根的 `handoffs/failed/` 与某个 worktree 的
`handoffs/failed/` 里各阻断一次（本仓 `handoffd.bb` 的 `fail!` 写的就是这里），而**空的**
`failed/` 目录不阻断（`prepare-handoff-dirs!` 给每个 worktree 都建了它，对存在性告警会
永远拒绝每一个 project）；`--issue` 把 `Closes` 写进正文，因为大多数卡是 Dashboard 上切的、
卡名带不了 issue 号；以及 **base 在 swarm 干活期间被别人推进过**时照发不误，但报告里出现
`behind N` 与一条 `WARN=`，PR 正文里出现对应的 `NOTE:`。最后这条的 fixture 里
`git clone -b main` 是承重的：`git init --bare` 把 HEAD 留在 `master`，不指定分支的 clone
会落在一个未出生的分支上、后面那个 push 悄悄什么也没干，于是这条用例会对着一份根本不算
`behind` 的实现照样通过。

`Closes` 的来源自己带三个用例（issue #173 之后）：一张卡文本里同时写着「按 #77 做」和
「另见 #78」，**两个号一个都不进** `will close:` 和 `Closes`（把卡文本扫回来会红）；
`--issue` 给的号照样进，同一个号写两遍只出现一次（去掉 `sort -u` 会红）；没有卡文本、
也没有 `--issue` 的卡报 `will close: none` 而不是报错。
`scripts/test-open-swarm.sh` 和 `scripts/test-open-dashboard.sh` 对着打了桩的
cmux/ssh/curl 跑这两条流程,覆盖 topology 配对、复用、修复、停机、drift、无法解析的
mutation 输出、隧道复用,以及端口冲突时的回退。`test-open-dashboard.sh` 还额外给 `ps`
打桩(经由 ssh 桩,外加一份假的 `pack_web.pid`/进程注册表)来覆盖端口归属检查:一个
`--serve` 参数指向另一个根的活进程(退出 4 DRIFT,实际的根打在 stdout 上,完全不调用
cmux)、一个缺失的 `pack_web.pid`,以及一个进程已死的 `pack_web.pid`(两者都退出 3
STOPPED,不是 4)。`scripts/test-wake-talk.sh` 对着打了桩的 tmux 跑 `wake-role.sh` 和
`talk-role.sh`,覆盖经过验证的提交、一个始终没落地的提交键、一个未知角色、一个死掉的
socket,以及两个脚本都绝不用符号键名 `C-m`/`C-j` 提交。

`scripts/test-ship-project-delivery.sh` 是同一个 verb 的**第二套**，覆盖它读交付记录的那
一半（issue #158 之前叫 `test-accept-work.sh`，用例逐条搬过来，没有重写）。**两套用相反的
harness，这是它们没有合成一个文件的原因**：上面那套跑真 git，因为它断言的是这个 verb 对一个
仓库做了什么；这一套跑桩 git，因为它的 fixture 里全是任何真仓库都不存在的 commit 哈希。
覆盖一次干净运行、`inbox/new` 与 `inbox/in_process` 各自阈值内不 WARN 而超出才 WARN、
two-pack 与 four-pack 的终端 handoff 识别、已交付 commit 的排除、跨链条跳的去重、
小数秒与整秒混合宽度时 `completed_at` 的正确胜出、roles.tsv 缺失/零个/两个 master 行各自
的硬失败,以及两次运行绝不改动 `inbox/` 树下的一个字节。

**四处关键逻辑改坏都会红**（实测）：去掉 `completed_at` 的宽度归一（1 红）、去掉已交付排除
（2 红）、master worktree 不再要求恰好一行（6 红）、终端判据退化成只认 `non-forwarding`
（22 红）。

`scripts/test-start-swarm.sh` 对着打了桩的 tmux/ssh 和一个假的 `./swarm` launcher 跑
`start-swarm.sh`,覆盖缺 `--root`/`--terminal`、一个非法的 `--terminal` 值、一个已经
在跑的 swarm(拒绝,launcher 从不被调用)、一个陈旧的死 socket(继续启动)、
`--terminal` 的值到达 launcher 的环境、`auto` 从不被导出,以及启动超时。它那几个关于
脱离终端的用例证明的是真实的进程存活,而不是 argv 的形状:一个假 launcher 记下自己的
PID 并一直睡到 `start-swarm.sh` 早已交还控制权之后,测试断言 start-swarm.sh 在那段
延迟结束之前很久就返回了,然后给 launcher 发一个真实的 `SIGHUP`(本地情形 —— 一个正在
关闭的会话会投递的信号)并确认它之后仍然跑完并写下它的标记文件,以及(远端情形,经由
一个真的执行启动命令而不只是记录它的 `ssh` 桩)标记文件只在那次桩 ssh 调用本身已经返回
之后才出现。`scripts/test-provision-forge.sh` 跑 `provision-forge.sh`。这里有两样东西是**真的**,
不是桩:dashboard 是一个真的 HTTP server(python3),所以 POST 那条路走的是真 curl、
真 JSON、真状态码 —— 一个 curl 桩会让畸形的 body 或读错的状态码蒙混过关,而 body 的
形状正是生产 `pack_web` 那个端点的契约所在;`start-swarm.sh` 是**真的被调用**的,对着
那个打了桩的 tmux 和一个假 launcher(与 `test-start-swarm.sh` 用的是同一个
`SWARM_LAUNCHER` 接缝)—— 委托本身就是这个 verb 的要点,断言一条 argv 字符串证明不了
它。只有网络是假的:helper 来自一个 `file://` URL 指着的假 `get-swarm-forge`,这也正是
让某个用例能决定「装出来的树」里有什么的办法 —— 有本 fork 的 marker,或者像 upstream
那样没有。覆盖:十一种 USAGE(含 `--project` 没配 `--pack`、lieutenant 不需要 `--pack`、
project 名里有空格、`--root` 带引号或是相对路径),而且没有任何一种装了东西;一棵
upstream 的树以 `5` 退出、launcher 一次都没被调用、也没写下 manifest;一次失败的安装
不写 manifest;一个不空又没装完的 root 以 `6` 退出且原封不动;一次成功的安装写下的
manifest digest 与树一致、以换行结尾,而且 `STATUS=` 是 stdout 的**第一行**(装完之后
`get-swarm-forge` 自己那句话曾经抢在它前面);同一条命令再跑一遍跳过装与起并各打一条
`WARN=`;一棵装好但 manifest 缺失的树被补写而不重新下载;POST 的 body 里 name/pack/
mission 逐项正确;`projects/<name>` 已存在时零 POST 并以 `6` 退出;dashboard 不应答时
以 `5` 退出、一个 POST 都没发;以及 `409` 走 `6`、`500` 走 `5` 并带上服务端原话。
