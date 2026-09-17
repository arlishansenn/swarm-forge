---
name: swarmforge-operator
description: "Use when operating a running SwarmForge project from the local machine: opening its role sessions or its pack_web dashboard in cmux, reading role state, waking or messaging a role, running one GitHub issue through the swarm to a stacked pull request, publishing finished swarm work to GitHub as a pull request when the cards were cut in the dashboard or by a lieutenant rather than by this skill, stopping the swarm, installing a fork pack (two-pack, four-pack, six-pack) into a new or existing project directory before the swarm has ever run, or provisioning a whole forge (project-manager, lieutenant) from an empty directory and creating its first project."
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
- `7` `STILL_RUNNING` —— verb 撞上的是 CALLER 设的期限,不是失败。活还在干;同一条
  命令再跑一次就接着往下走。(`run issue --max-wait`。)
- `8` `OWNED` —— 被管 project 把这个 verb 要写的路径纳入了版本控制,所以谁赢是人的
  决定,不能有默认答案。什么都没改。(`update SwarmForge scripts`。)

**失败要用大白话说清原因。** `STATUS=` 行之后,失败的 verb 打印一句话告诉你该做
什么。没有机器可读的 reason 字段:脚本要分支就看退出码,那句话是给人看的。

**成功也可以说话。** verb 干完了活但发现了你必须知道的事,就打印一行或多行
`WARN=<one sentence>`,退出码仍然是 `0`。只报对本次运行成立、且以后可能变成不成立的
事实。永远成立的事实要在成因处修掉,不是拿来 warn 的:每次都出现的警告等于没人看
的警告。

**handover verb 的契约只到交接那一步为止。** 它检查它能检查的,然后把自己替换成
目标程序。之后的退出码属于那个程序,不属于这份契约。

**不是每个 verb 都已经有脚本。** `provision forge`、`onboard project`、`open swarm`、
`dashboard`、`wake role`、`talk role`、`read swarm`、`stop swarm`、`accept work`、
`start swarm`、`update SwarmForge scripts`、`run issue` 和 `ship project` 今天已经
有脚本并遵守这份契约。其余 verb 是本文件里的 shell 步骤;照写的跑,读它们的原始输出。把它们
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

**它与 `onboard project` 的边界。** 两者都落文件,但对象不同:`onboard project` 把一个
pack 装进**一个已有的 product 仓库**;`provision forge` 从空目录建一个**能装很多 product
的 forge**。名字用 `provision` 而不是 `start`,因为 `start swarm` 撞见已在跑的 swarm 是
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

## Verb: `onboard project`

把一个 fork pack 装进被管 project 的目录。这是本 skill 唯一的创建型 verb:落文件,
然后停下。

```sh
scripts/onboard-project.sh --root <project-dir> --pack <two-pack|four-pack|six-pack> [--local]
```

退出码 / STATUS 行:

- `0` `ONBOARDED`
- `2` `USAGE` —— 缺参数,或 pack 不在白名单里(`main` 是 upstream 的文档分支,永远
  不是 pack)
- `4` `OCCUPIED` —— 目标已经有 `swarm` 或 `swarmforge/`;零写入
- `5` `ERROR` —— 下载或解压失败;目标未被改动

pack 来自 `arlishansenn/swarm-forge`,解出来的 archive 是**不可变输入**(issue #38、
ADR-0002)。fork 的每条 Pack 分支已经自带最终 config 和一个指向本 fork `main` 的
launcher,所以装完之后不再有打补丁那一步。正是那一步曾经毁掉 launcher 的可执行位
(issue #33):保住它的字节和权限位靠的是根本不碰这个文件,而不是换一种更小心的
写回方式。`update SwarmForge scripts` 保留了它自己那份独立的 ARCHIVE_URL 改写,作为
给这次改动之前 onboard 的 project 用的历史修复路径。

### `.gitignore` 块,以及 archive 不许覆盖的两个文件

这个 verb 装进被管 project 的所有东西都是**未跟踪**的。`stop swarm` 的 preflight
分不清「这是 SwarmForge 装的」和「这是你忘了提交的」,于是它每一次运行都报 `DIRTY`,
`--force` 成了停任何东西的唯一办法 —— podsum 上实测:根目录 7 个未跟踪路径,外加
每个角色 worktree 里 2 个,永远如此。每次都触发的闸门等于没人看的闸门。**装文件的
那个 verb 有责任让它们安静下来**(issue #87),所以它往 `$ROOT/.gitignore` 追加
一个块:

```
# >>> SwarmForge installed files >>>
# Installed by onboard project. Safe to commit; safe to delete if
# this project version-controls its own SwarmForge instead.
/bb.edn
/swarm
/swarmforge
/test
/.swarmforge/
/.worktrees/
# <<< SwarmForge installed files <<<
```

这些条目是**从刚装进去的那份 archive 推导出来的**,绝不硬编码 —— 只有 artifact
自己知道它放了什么进去,手工维护的清单在某条 Pack 分支新增一个顶层文件的那一刻就
会漂移。`.gitignore` 和 `README.md` 被排除在外,因为它们属于被管 project;
`.swarmforge/` 和 `.worktrees/` 被加进去,因为 swarm 会在之后运行时创建它们。

这个块是追加,绝不替换,而起始标记本身就是完整的幂等判据:装第二次,或者有人事后
删掉了其中几条,都不会得到重复的块,也不会把删掉的行加回来。

`.gitignore` 是这个 verb 唯一会写的、属于 project 的文件。它会在 `git status` 里
出现一次,直到有人提交它为止 —— 这是一个会自行消失的状态,正是 DIRTY 闸门存在的
意义,不像它取代的那个永久状态。

**archive 自己也带 `.gitignore` 和 `README.md`**,`tar` 会直接盖掉 project 的那两个。
这两个文件在解压前被保存、解压后被放回。跟 issue #33 里那个 launcher 是同一条规则,
只是方向相反:那边是不碰 archive 的文件才保住了它;这边是不让 archive 碰 project
的文件。

### 已经 onboard 过的 project

这个块只落在从这次改动之后 onboard 的 project 上。对于已经装了 SwarmForge 的
project,手工把同样的块粘进它的 `.gitignore` 一次,然后提交。条目要从那个 project
上实际读出来,不要照抄上面的例子 —— 不同的 Pack 顶层文件集合不一样:

```sh
ssh -n -i <key> <target> "cd <root> && git status --porcelain | awk '\$1==\"??\"{print \"/\" \$2}'"
```

**边界:** onboard 完不要替用户跑 `./swarm`。三条硬禁令原样不变:绝不启动、绝不
清理、绝不替用户决定启动时机。除了上面那个 `.gitignore` 块之外,脚本从不碰目标
project 的 git 状态 —— `git init` 是 swarm launcher 自己首次运行的行为,这个 verb
仍然从不跑 git。

## Verb: `open swarm`

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

## Verb: `start swarm`

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

`--terminal` 是**必传的**,不是可选的环境变量透传 —— 跟 `stop swarm` 的 `--force`
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
报 `4` `DRIFT`,`--force` 于是成了启动的常规做法。状态改由 `git ls-files` 推导,
与 `update SwarmForge scripts` 拒绝时用的是同一个判据,所以两个 verb 不可能对
「这棵树归谁」产生分歧。报文会说明它处在哪个世界:`SNAPSHOT=project-owned` 或
`SNAPSHOT=operator-managed`。

`--dashboard-port <N>`(issue #78)会被转发成 `SWARMFORGE_DASHBOARD_PORT`,
`pack_web` 于是绑这个端口,而不是向内核要一个随机的。不传就什么都不导出 ——
`pack_web` 一字不变地保持它一直以来随机挑的端口。`dashboard --tailnet` 需要的正是
固定端口:随机端口没法发布到 tailnet 上,因为根本没有稳定的 URL 可发布。只校验形状
(是数字,否则 `2` `USAGE`);一台主机怎么分配端口是那台主机自己的约定,SwarmForge
对此没有意见。`--terminal` 与 `--dashboard-port` 累积进同一个 `env` 前缀,所以两者
一起到达 launcher。

动手之前,它先检查 swarm 是不是已经在跑 —— 与 `stop-swarm.sh`/`open-swarm.sh` 用的
是同一次 socket 探活读取,只是判断反过来:socket 有应答就意味着再启动一次会拉起
第二个 daemon 和一个撞名的第二个 tmux session,所以它拒绝。一个背后没有活 server
的陈旧 `tmux-socket` 文件(`open swarm` 已经会点名的那种 watchdog 击杀残留)才是
这个 verb 存在意义上要恢复的「停机」状态,不是「已在跑」—— 它会继续启动。

接着,它取一把 project 范围的锁(issue #29),位置在
`$ROOT/.swarmforge/update-lock`,用来排斥同一个被管 project 上并发的
`update SwarmForge scripts` —— 锁已经被那个 verb 持有就是 `6` `UNSAFE`,并点名持有
者。然后,除非传了 `--force`,它会重算被管 project 已装的 `swarmforge/scripts/` 的
确定性 digest,与 `$ROOT/.swarmforge/scripts-manifest` 比对。两个身份 artifact 中
哪些存在,决定接下来发生什么(issue #35):

- **Fresh** —— snapshot 和 manifest 都不存在。这是一个 onboard 完就停在那里的
  project,首次运行的 bootstrap 归 Pack 自己的 launcher 管,所以 `start swarm` 交接
  给它,而不是拒绝。Fresh 不等于「忽略不一致」:它就是「两者都不存在」这一个精确
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
重试或一个并发的 `update SwarmForge scripts` 变成针对一份仍在进行中的安装的第二个
写者。之后要清掉它,就得显式地用 `--force`。

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
  scripts-manifest` 不匹配,或者后者缺失(issue #29)。launcher 绝不会被调用;先重跑
  `update SwarmForge scripts`,或者传 `--force` 强行启动。
- `5` `ERROR` —— runtime 文件在预算内始终没有确认就绪。这同时覆盖 `./swarm` 非零
  退出和它单纯没能就绪两种情况:启动是刻意脱离终端的(见上),所以这个脚本从不检查
  launcher 自己的退出码,只看它最终应该产出的 runtime 文件 —— 去看消息里点名的那份
  启动日志。
- `6` `UNSAFE` —— swarm 已经在跑;拒绝启动第二个 daemon。什么都没改。现在这条也覆盖
  project 锁被并发的 `update SwarmForge scripts` 持有的情况(issue #29),并点名持有
  者 —— 与「已在跑」不同,`--force` 能清掉被持有的锁。

**边界:** 这个 verb 只管「从零到一」。要不要 `--force` 覆盖一个已经在跑的 swarm 去
重启、还是等一个正在拆除的跑完,是 `stop swarm` 和 `open swarm` 的地盘,不是它的。
它也不修 window watchdog 自己那个空 window-ID 的误判(那是 launcher/watchdog 侧的
缺陷)—— 它只是让 operator 不至于经由这个 verb 意外撞上去。issue #29 加的锁与 drift
preflight 守的是进入同一个「从零到一」步骤的入口;它们没有扩大这个 verb 本来做的事。
一旦 launcher 自己接手,它会独立地做镜像(删掉重建,不是覆盖写),并在每个角色启动
前校验该角色的 `swarmforge/scripts/` 与已装的来源一致,所以一份陈旧的逐角色副本不
可能比这个 verb 自己的 project 级检查活得更久。

## Verb: `update SwarmForge scripts`

### 当 project 自己拥有 `swarmforge/` 时(issue #88)

有些被管 project 把 `swarm` 和 `swarmforge/` **提交进了版本库**,而不是让这个 verb
去装。pi-governance 就是这样,还带着它自己的 constitution articles。装到那上面不是
update,是接管 —— 而且它过去是悄无声息发生的:一次运行重写了 31 个被跟踪文件、
新增 5 个,并在**六个**位置重写了 `swarm` 的 `ARCHIVE_URL`(根目录加五个角色
worktree,`sync-worktree-scripts!` 会在下次启动时镜像进去)。verb 报了 `UPDATED`
并以 `0` 退出。`start swarm` 随后把已装的树和 manifest 一比,发现两者一致,因为那时
两边描述的都已经是 fork 的版本。根目录那个分支是某个 PR 的 head,所以任何一个角色
的一次 `git add -A` 都会把 38 个 SwarmForge 文件提交进一个毫不相干的 PR。

这个 verb 现在先问 `git ls-files`,并以 `8` `OWNED` 拒绝,列出每一处会被写的
checkout:

```
STATUS=OWNED
<root> tracks the paths this verb writes — installing would overwrite files the project itself version-controls, in 3 place(s):
OWNS=/home/msb/project/pi-governance (31 tracked files under swarmforge/scripts)
OWNS=/home/msb/project/pi-governance/.worktrees/coder (31 tracked files under swarmforge/scripts)
...
```

`--overwrite-tracked` 才是那句刻意的「这里由本 fork 的版本说了算」。它跟 `--force`
分成两个 flag 是有意为之:`--force` 管的是陈旧的锁,而一个意思是「挡路的东西一概
忽略」的 flag 是没人会看的 flag。

成功的运行还会报 `WROTE=`(它实际改动的那一棵树)和 `MIRRORS=`(有几个角色 worktree
会在下一次 `start swarm` 时收到它 —— 不是现在)。

跑随包的脚本;它把**本仓库自己的** `swarmforge/scripts/` 装进被管 project 的
`swarmforge/scripts/`,与 `start swarm` 的 drift 检查是一体两面(issue #29):一个
从 upstream pack onboard 出来的 project(它的脚本来自那个 pack 的 `./swarm` 首次
运行时 `ARCHIVE_URL` 指向的任何地方)可能漂移到本 fork 自己的 launcher 不认作必需
的一组脚本上 —— 正是 podsum 那次真实事故:一个 `ARCHIVE_URL` 那行从没被重新指向过
的历史 `./swarm`,加上一棵缺了当前 launcher 期望的文件的 `swarmforge/scripts/` 树。
这个 verb 是 `start swarm` preflight 所读的那份身份 manifest 的写者;两者永远不会
对「这个 project 的脚本是从哪来的」产生分歧,因为一个写的格式就是另一个读的格式,
逐字节相同。

```sh
scripts/update-swarmforge-scripts.sh --root <project-root> \
  [--target user@host] [--key <path>] [--local] [--force]
```

它先把 operator 自己的 source checkout 落地到一份全新的临时副本里,拿这份 STAGED
副本去过 `swarmforge.bb` 自己的 `check-helper-scripts!` 所强制的同一份
required-helpers 与 terminal-adapters 清单,通过之后才替换被管 project 的脚本树、
manifest 以及(若存在)历史的 `./swarm` launcher —— 三者原子替换,从换入那一步起
任何一步失败就整体回滚。staging 与校验双双通过之前,`$ROOT` 下不会被碰一下。

preflight 的顺序刻意与 `start swarm` 一致(issue #29):1)swarm 已经在跑就拒绝,
没有 override,零副作用,project 锁碰都不碰;2)取 `start swarm` 用的那把同一个
project 范围的锁,排斥并发的启动 —— `--force` 抢走被持有的锁;3)其余一切都在持锁
状态下进行。这个 verb 安装的来源 checkout,永远是从 operator 脚本自己所在的位置
解析出来的,在 operator 自己的机器上,与 `$ROOT` 是本地还是远端无关 —— 如果
`swarmforge/scripts/` 下的来源 checkout 是脏的(有未提交改动),就拒绝,而且**永远
没有 override**:与锁不同,`--force` 对这项检查毫无作用,因为一份未提交的来源
checkout 永远不安全到可以发出去。`--force` 在这里只干一件事 —— 抢走被持有的锁 ——
再无其它。

退出码 / STATUS 行:

- `0` `UPDATED` —— 脚本树、manifest 与历史 launcher(若存在)都已替换;报出
  `ROOT`/`DIGEST`/`SOURCE_COMMIT`。
- `2` `USAGE` —— 缺 `--root`。
- `5` `ERROR` —— 来源 checkout 在 `swarmforge/scripts/` 下是脏的(无 override);
  staged 副本缺一个必需 helper 或 terminal adapter(点名那个文件,`$ROOT` 未被碰);
  manifest 写入失败(已回滚到之前的脚本树);或者历史 `$ROOT/swarm` launcher 的
  `ARCHIVE_URL` 那行改写后不符合预期模式(点名 `$ROOT/swarm`,连脚本换入和 manifest
  写入一起回滚 —— 这正是这个 verb 存在的全部意义)。
- `6` `UNSAFE` —— swarm 已经在跑(无 override),或者 project 锁被并发的
  `start swarm` 持有(点名持有者;`--force` 抢走它)。

**边界:** 这个 verb 永远只安装 operator 自己当前的 source checkout;它从不 fetch,
从不指向别的 commit 或分支,也从不启动或停止任何东西。被管 project 根本没有
`$ROOT/swarm` 文件不算错误 —— launcher 改写那一步直接跳过,毕竟不是每个被管
project 都一定有那个历史文件。它也从不修复一个运行中 swarm 已经加载进内存的进程
状态:`start swarm` 报的 `DRIFT` 意思是「先 update,再 start」—— 这个 verb 是
「update」那一半,永远不是「start」那一半。

## Verb: `dashboard`

跑随包的脚本;它把 pack_web 的 dashboard 页面开成一个 cmux browser workspace:

```sh
scripts/open-dashboard.sh --root "$ROOT" [--window <ref>] \
  [--target admin@host] [--key ~/.ssh/key] [--local] [--tailnet]
```

它按这个顺序问四个问题,在第一个 `no` 处停下(issue #100):**swarm 在跑吗**
(读 `tmux-socket`,探 `list-sessions` —— 与 `open`/`start`/`stop`/`read swarm`、
`wake`/`talk role` 和 `update SwarmForge scripts` 用的是同一个判断)、**有
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

顺序是要紧的,而且过去是错的。`stop swarm` 会删 `pack_web.pid`,但**没有任何东西
会删 `dashboard-url`**,所以停机之后这两者互相矛盾 —— 而当可达性被最先检查时,一个
停着的 project 死于 `5` `ERROR`(「隧道坏了」)而不是 `3` `STOPPED`。在 `--tailnet`
路径上它还更进一步,叫 operator 去跑一条他们已经跑过的 `tailscale serve` 命令。一个
没在跑的 swarm 既没有端口可达、没有所有者可辨认、也没有 workspace 可打开,所以现在
这个问题最先问。

**一个刻意的后果:** 一个 swarm 停着、但 `pack_web` 不知怎么还活着的 project,现在
会被 `3` 拒绝。这个 verb 打开的是*某个 swarm 的* Dashboard;没有 swarm 就没什么可看
的。自 issue #82 起 `stop swarm` 会连 `pack_web` 一起停,所以这种状态只在有东西绕过
这个 verb 停掉 swarm 时才出现。报文里的 `TUNNEL=` 说明走了哪条路:`created`、
`reused`、`tailnet` 或 `local`。

### 怎么跑它

下面这几个设一次,然后按顺序跑各步骤。`SF` 是本 skill 的 `scripts/` 目录。如果
dashboard 就在你所在的这台机器上,照着 `# local:` 注释走:`REMOTE=(--local)`,
读文件时不走 `ssh`。

```sh
SF=.agents/skills/swarmforge-operator/scripts
ROOT=/Users/admin/project/podsum          # the MANAGED project's root, on its host
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

# 6b. show what stopping would interrupt, then stop  (ASK FIRST)
"$SF"/read-swarm.sh  --root "$ROOT" "${REMOTE[@]}"
"$SF"/stop-swarm.sh  --root "$ROOT" "${REMOTE[@]}"

# 6c. start again on this project's port from the table below (7780, 7781, ...)
"$SF"/start-swarm.sh --root "$ROOT" "${REMOTE[@]}" --terminal none --dashboard-port <N>

# 6d. go back to step 3
```

`start swarm` 会以 `6` `UNSAFE` 拒绝一个已经在跑的 swarm,而且没有 override,所以
第 6b 步跳不过去。`tailscale serve --bg` 能扛过重启和 `tailscale down`/`up`,而
`--tcp` 一次只吃一个端口(没有范围语法),这就是 6a 要写成一个每台主机跑一次的循环
的原因。

**绝不用任何其它方式把 dashboard 暴露出去。** 6a 是唯一获准的路径。不要写端口转发
或代理,不要自己加 `ssh -L`,不要改 `pack_web` 绑什么。它绑 `127.0.0.1` 是有意的,
这样一台没有 tailscale 的主机行为跟以前完全一样;在这之前加任何东西,都等于把一个
Teardown 按钮发布给所有够得着它的人。如果这些步骤走不到,就说出来然后停下 —— 不要
临时发明一条路线。

### Dashboard 端口分配

`7780`-`7789` 留给 dashboard,一个 project 一个号,这样光看 URL 就知道你在看哪个
project:

| project | port |
|---|---|
| podsum | `7780` |
| pi-governance (coder2) | `7781` |
| `provision forge` 的验收 forge (macmini) | `7782` |
| unassigned | `7783`-`7789` |

端口跨主机其实不会真的冲突 —— 这张表存在的意义是让读 URL 的人知道那是什么。它是
本 fork 的 operator 手工维持的一条约定:没有任何东西推导它,没有任何东西强制它,
`--dashboard-port` 也不会拿它做范围校验。给新 project 分配下一个空号,并在这里加
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

## Verb: `read swarm`

跑随包的脚本;它按 config 顺序遍历 `sessions.tsv`,截取每个记录在案的 session 的
pane,并分成三态,而不是老的两态猜测:

```sh
scripts/read-swarm.sh --root <project-root> \
  [--target user@host] [--key <path>] [--local]
```

输出是每个角色一行:先 `STATUS=READ`,然后按 config 顺序,`sessions.tsv` 里每一行
输出一条 `<role> <STATE> | <pane text>`:

```
STATUS=READ
coder    BUSY     | Working (esc to interrupt)
cleaner  UNKNOWN  | ⚠ rate limit reached, retrying in 43s
```

退出码 / STATUS 行:

- `0` `READ` —— verb 干完了它的活。这包括某些角色甚至全部角色读成 `UNKNOWN` 的运行:
  对一个职责是如实报告的 verb 来说,准确地报出 `UNKNOWN` 是成功,不是失败。
- `2` `USAGE` —— 缺 `--root`。
- `3` `STOPPED` —— `sessions.tsv`/`tmux-socket` 缺失,或者 socket 上没有 tmux
  server;swarm 没在跑,绝不要启动它。
- `5` `ERROR` —— verb 自己跑失败了(不是「某个角色是 UNKNOWN」)。

`STATE` 是下面三者之一:

这个判断读最后那么一两行非空行,并且先丢掉尾部任何静态 footer(issue #58)。Grok 会
在提示符下面画一条 —— `Grok 4.6 (high) · always-approve · 93K / 500K · ctrl+o
transcript` —— 它不携带状态也从不变化,所以停在 pane 物理意义上的最后一行会让每个
Grok 角色都读成 `UNKNOWN`。在那个窗口里只要任何位置出现 `BUSY`,`BUSY` 就压过
`IDLE`,因为一个忙着的 pane 在 spinner 下面照样显示它的空提示符。

- `IDLE` —— 那里有一行确定地匹配上了已知的 idle 提示符(一个后面什么都没有的裸
  `❯`/`>`,或者字面的 "ask me anything" 占位符),并且没有 busy 标记。
- `BUSY` —— 那里有一行确定地匹配上了已知的 busy 标记(codex 风格的 "esc to
  interrupt" 横幅、claude 风格的「分词 + for Ns」spinner,或者 Grok 的 "Waiting for
  response")。
- `UNKNOWN` —— 两者皆非。这也覆盖**空白 pane**(截到的 scrollback 里根本没有非空
  行)—— 空白不等于 idle,因为一个卡在报错、限流或确认提示上的角色同样可以留下一个
  看起来是空的最后一行。`UNKNOWN` 是安全的默认值,不是拿来猜掉的兜底。

**边界:** 这个 verb 不试图穷举每个 backend 的错误状态 —— `codex`、`grok` 和
`claude` 各画各的,还会随版本漂移,追这个是一场必输的赛跑。认不出来的输出按设计就是
`UNKNOWN`;每个角色的原始 pane 文本永远附上(`IDLE` 和 `BUSY` 也一样),这样人可以
拿证据核对这次判读。这是一个 report verb(`CONTEXT.md` 的 "## Operator verbs"):
它从不调用 `send-keys` 或任何别的会改动 tmux 状态的东西,只用 `list-sessions` 和
`capture-pane`。一个 `IDLE` 角色上出现可见的 handoff 邮件提示,意味着它需要
`wake role` —— 那个判断仍然要由人从附上的文本里做出,不是这个 verb 分类的事。

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
`accept work` 报告的那个终端 handoff(issue #39)。`talk role` 是给一个运行中的角色
发一条行为消息 —— 它从不创建 Board 任务,也不是 New Task 的替代品。

## Verb: `accept work`

swarm 干完一个任务之后由人来验收。链条在回到 **master** Role 时结束;master
worktree 自己的 `inbox/completed/` 里那个文件就是交付记录,而且是唯一的一份
(issue #39)。其它每个 worktree 的 `completed/` 里放的是同一个任务的中间跳 —— 一条
在返程中经过 `cleaner` 的链条也会在那里留下一个 completed 文件,把它当结果报出来
就会报错 `commit:`。脚本从 `.swarmforge/roles.tsv` 里按 **worktree 名(第 2 列)
`== master`** 定位 master,绝不按角色名:哪个角色坐在 master 上因 pack 而异
(two-pack 里是 `coder`,four-pack 里是 `specifier`)。它要求恰好一行这样的记录,
并拒绝去猜。

在 master 的 `completed/` 里是必要条件,不是充分条件。master 也会完成**非终端的**
入站 handoff —— 一个它合并并关闭掉的中间跳同样带着 `task`/`commit`/`completed_at`,
而且就躺在同一个目录里。终端性是发送事件的属性,脚本接受两种信号中的任意一种:

- `non-forwarding: true` —— 当发送方是 pack 的最后一个角色时由 `swarm_handoff.bb`
  盖上,而且那边也强制它:持有一个盖了章的入站 handoff 会让 `swarm_handoff.sh` 拒绝
  再发一个 `git_handoff`。
- `to:` 收件人**集合**等于除发送方之外的所有角色 —— 这是给盖章机制出现之前写下的
  记录用的兼容路径。

第二条是集合相等,不是收件人计数。two-pack 的终端返程 `cleaner → coder` 恰好只有
一个收件人,因为「除 cleaner 之外的所有角色」就是 `coder`;数收件人个数会漏掉它。

Board 会被交叉核对,但从不由它拍板。`handoffd` 是在它**投递**一个终端形状的 handoff
时把卡片挪到 `done` 的,那时还没有任何收件人处理过它,所以 lane 不一致会作为一条
`WARN=` 报出来,记录照样打印。完全没有 Board 时,报文会说明这一点,并退回到只看
handoff。

跑随包的脚本;它从 master worktree 逐任务报出终端 handoff,同时也堵上一个真实的缺口
(issue #17):一个卡在 `inbox/new` 的 handoff —— 已投递但从未被认领,链条断了 ——
过去跟「还没有活干完」读起来一模一样,因为老的手工命令只看 `inbox/completed`。这两种
情况需要的人类反应是相反的(继续等 vs 去查为什么没人接),所以脚本现在会对
`inbox/new` 和 `inbox/in_process` 里积压到「不像正常在途延迟、像链条卡住」的量发出
WARN:

```sh
scripts/accept-work.sh --root <project-root> \
  [--target user@host] [--key <path>] [--local]
```

报文主体,每个尚未交付的任务一段:

- `task:` —— 链条携带的稳定任务名(intake 命名得当时可以映射到 issue,例如
  `issue-50-brief-quality` → `Closes #50`)。
- `commit:` —— 最终提交的状态;这就是人开 PR 时应该带上的东西。
- `completed_at:` —— 链条完成的时间。

退出码 / STATUS 行:

- `0` `REPORTED` —— verb 干完了它的活。这包括打印了一条或多条 `WARN=` 的运行:一条
  卡住的链条是这个 verb 成功报出来的信息,不是 verb 的失败。
- `2` `USAGE` —— 缺 `--root`。
- `5` `ERROR` —— 找不到 `$ROOT/.swarmforge/handoffs`(`--root`/`--target`/`--local`
  给错了,或者目标不可达);或者 `$ROOT/.swarmforge/roles.tsv` 缺失、或者它没有恰好
  一行 `master` worktree 记录(消息里带上实际匹配到的条数)。

**`WARN=` 行**来自两次互相独立的扫描,两者都不改变退出码。

**积压卡住**,每个受影响的 worktree 一行 —— 时间长到不像只是正常的在途延迟
(issue #17;这次扫描仍然覆盖*每一个* worktree,不受上面那条只看 master 的规则影响,
因为链条可能卡在任何一跳):

```
WARN=3 handoffs are stuck in inbox/new in cleaner — the chain is not moving
WARN=1 handoffs are stuck in inbox/in_process in coder — claimed but not finishing
```

**master worktree 里格式不对的 completed 记录** —— 一份交付记录必须是
`type: git_handoff`,并且 `task`、`commit`、`completed_at` 都非空。达不到这个标准的
记录会被点名,而不是被静默丢弃(与已交付检查遵循的是同一条「不确定就说出来」规则):

```
WARN=<file> missing commit — not reported as a delivery record
```

陈旧与否是按每个 handoff 自己的头部时间戳判断的(`enqueued_at`/`dequeued_at`),绝不
用文件系统 mtime —— 与 `handoffd.bb` 自己的重试阶梯用的是同一个事实来源。光是存在
不算卡住:一条健康的链条经常会有文件在投递与取件之间短暂停留(daemon 自己的对账在
5 秒过去之前不会发出第一次重试唤醒),所以 `inbox/new` 只在超过 5 分钟时才 WARN ——
足够长到已经熬过了 daemon 的快速重试档位。`inbox/in_process` 用更长的 30 分钟阈值,
因为一个角色确实可以正当地干上好几分钟的真活;在同样的 5 分钟处告警会打在健康的
进行中工作上,而不是卡住的链条上。

规则(与它取代的那条手工命令相同,未变):

- **排除已经交付过的任务。** 一个 `commit:` 已经在 `origin/main` 上(或是 `HEAD` 的
  祖先)的 completed handoff 已经被验收并合并过了;它不能被再报一次。这项检查是对
  **被管 project 自己的** git 仓库、在 `$ROOT` 处跑 `git merge-base --is-ancestor
  <commit> origin/main` —— 不是对 swarm-forge 跑 —— 跟 `stop swarm` 的 `git status`
  检查是对 project 自己的 worktree 跑是同一个道理。无法确认的检查(commit 不对、
  没有 `origin/main`)一律当作「未交付」,绝不静默丢弃。
- **每个任务一条记录,取 master 上最新的那条。** 中间跳已经因为只读 master worktree
  而被排除了;当 master 自己为同一个 `task:` 持有多条终端返程时(重跑、一次快速的
  `cleaner → coder` 循环),`completed_at:` 最新的那条胜出。排序时先把 ISO8601 UTC
  字符串的小数部分补齐到固定 9 位再比 —— 生产者在正好整秒时会完全省掉小数部分,所以
  `...:55Z` 和 `...:55.000001Z` 都会出现,只有补齐后的形式才能正确排序。这里完全不
  涉及 `date` 解析;macOS 上的 `date` 根本解析不了那个带小数的形状。报文仍然一字不差
  地打印记录里的 `completed_at:`。补齐后仍然相等的时间戳退回到文件名字典序,这是一条
  声明在案的最后手段式打破平局的规则,所以结果永远不会是未定义的。
- handoff 只指向 commit。代码本身在 git 里;开 PR 之前用 `git show --stat <commit>`
  或跑测试来核实。
- 开 PR 时,把 `task:` → issue 的映射带进 PR body(`Closes #N`),让 GitHub 把两者
  关联起来。swarm 从不碰 GitHub;关联是验收的人的活。
- board 目录(`$ROOT/.swarmforge/board/`,存在时)在 `tasks.tsv` 里带着同一个任务名,
  在 `<task>.txt` 里带着 intake 文本;用它来交叉核对这个任务是从哪个 issue 来的。

**边界:** 这是一个 report verb(`CONTEXT.md` 的 "## Operator verbs")—— 它只读。
它从不修改、移动或删除 `inbox/` 下的任何东西:`completed/` 是审计轨迹,`new/` 和
`in_process/` 是活的队列状态,归 daemon 和 `ready_for_next`/`done_with_current`
helper 所有,不归一份面向人的报告所有。它也不试图诊断一个 handoff *为什么*没被认领
—— 可能是 daemon 停了、角色忙着,或者一次唤醒失败了(见 issue #14)—— 这个 verb 唯一
的活是让卡住的链条可见,不是解释它。

## Verb: `run issue`

把**一个** GitHub issue 过一遍 swarm,停在一个可 review 的 PR 上。它走的每一步在本
文件里本来就都是有记载的步骤;缺的是一个按顺序走完它们的 verb。漏掉一步不会报任何
错,而 podsum 两种丢法都丢过:合并之后从没跑过 `git pull`,于是被管 project 的
`main` 与 `origin/main` 分叉并一直分叉着;还有一张叫 `验收 3 个 commit` 的 Board
卡片产出了一个映射不回任何 issue 的 `task:`,验收的人只好反推这个 PR 关掉的是什么。

```sh
scripts/run-issue.sh --root <project-root> --issue <N> \
  [--target user@host] [--key <path>] [--local] [--max-wait <seconds>] \
  [--round <N>]
```

六步,按这个顺序:

1. 读 `$ROOT/.swarmforge/dashboard-url`。**每次运行都读,绝不缓存** ——
   `pack_web` 每次启动都绑一个新端口。
2. 在目标上、在 `$ROOT` 里跑 `gh issue view <N>`,这样 `gh` 会从*被管 project* 自己
   的 git remote 解析出仓库。它的标题变成 slug:分支叫 `feat/issue-<N>-<slug>`,
   任务名叫 `issue-<N>-<slug>`,两者同一个来源。
3. `BASE` = 最新的那个开着的 PR 的 `headRefName`,没有就是 `main`。
4. 读那几个标记 —— Board 卡片的 **lane**、分支,以及(只在 lane 是 `done` 时)PR ——
   并回答每一种状态:两个标记都没有是全新运行,活跃 lane 加上它的分支是续跑,只有
   分支是一次还欠着 POST 的续跑,只有活跃 lane 会被拒绝,而 `done` lane 是一个这个
   verb 会把交付部分做完、但绝不重启的轮次。swarm 在等人时同样拒绝。除非分支已经在
   那里,否则从 `BASE` 创建它 —— **创建之前先 `git fetch origin`,并把 `BASE` 对齐到
   远端**(见下)。
5. `POST {dashboard-url}/api/tasks` 一次 —— 只在卡片已经在 Board 上时才跳过 ——
   然后轮询 Board lane 直到 `done`。
6. 用 `accept work` 取 commit —— **一直重试直到交付记录真的可见**,不是只读一次 ——
   然后 `git push`,停在 `NEEDS_PR_BODY`(退出 8)并把 commit 交回给你。**正文由你
   来写**,写完带 `--body-file` 重跑,第二趟直接走到 `gh pr create --base BASE`。

### 开分支之前先对齐 BASE

`BASE` 的**名字**来自 `gh pr list`,那是远端;它的**内容**是那台机器上次 checkout 留下的。
这两者之间原本没有任何东西去对账 —— 人合并一个 PR 之后,被管 project 的 `main` 就留在
原地,下一轮从旧代码上开分支。**这个 verb 的开头注释本来就把「合并之后从没跑过
`git pull`」记作 podsum 两种丢法之一**,而它自己直到 #122 才真的去做那次 fetch。

实测过一次:podsum#155 合并之后,那台机器的 checkout 落后 `origin/main` **4 个 commit**。

现在建分支之前:

```sh
git fetch origin --quiet
# BASE 在本地存在（通常就是 main）
git merge-base --is-ancestor refs/heads/<BASE> refs/remotes/origin/<BASE>   # 不是祖先 → 拒绝
git checkout <BASE> && git merge --ff-only origin/<BASE>
# BASE 在本地不存在（stacked：它是另一轮推上去的分支）
git checkout -B <BASE> origin/<BASE>
```

**两种形状不能合并成一条 `checkout -B`。** 对 `main` 用 `-B` 会**静默地把本地 commit 甩成
孤儿**,而被管 project 的 canonical checkout 正是最不该让一个野生 commit 无声消失的地方。
所以本地 BASE 不是 `origin/BASE` 的祖先时,这个 verb **拒绝**(`STATUS=UNSAFE`,退出 6),
零 POST、零 push —— 与 pi-governance 的 `step_repo_ff` 是同一条判据。

stacked 那一侧则相反:上一个 PR 的 head 分支可能**本地根本不存在**(它是别的轮次推上去的),
所以直接从远端建出来,没有本地东西可丢。

### 堆叠分支,以及为什么不动 `main`

分支是从最新那个开着的 PR 的 head 上开的,不是从 `main` 上:

```
main                      ← only ever moves when a human merges a PR
 └ feat/issue-27          PR base = main
    └ feat/issue-28       PR base = feat/issue-27
       └ feat/issue-29    PR base = feat/issue-28
```

这一下买到三样东西。一条线性的 `blocked by` 链需要上一个 issue 的 commit 对下一个
issue 的 coder **可见**,而在有人合并之前它们不在 `main` 上。PR 的 diff 保持干净 ——
所有分支都从 `main` 开、又一个都没合并,意味着后面每个 PR 都扛着前面每个 PR 的
commit。而且 swarm 不再直接往 `main` 上提交。一旦有人合并了下层的 PR,GitHub 会自己
把上层那个重新指向 `main`。

这不需要新建 worktree。`merge_and_process.bb` 里恰好只有两条 git 命令
(`merge-base --is-ancestor` 和 `merge --no-edit`),都是针对当前 `HEAD` 的;swarm 里
没有任何东西点名一个分支。`BASE` 每次调用都从 `gh pr list` 重新查一遍 ——
**这个 verb 在两次调用之间不保留任何状态。**

### PR 正文:字段归脚本,散文归你

在 issue #118 之前,正文是四行 `printf`。podsum#149 就是它在 reviewer 眼里的样子:

```text
Closes #138

task: issue-138-brief
commit: 8ff7c7055b
completed_at: 2026-09-09T15:43:01.447590Z
```

**没有一个字是模型写的**,标题是 `gh issue view --json title` 原样搬的。改角色 prompt、
改 skill description、改 `AGENTS.md` 都修不了它:**那条路径上根本没有模型可以指挥。**

现在这个 verb **分两趟**:

```text
第一趟  run-issue.sh --root R --issue 28
          投 task → 轮询 → accept work → git push
          → STATUS=NEEDS_PR_BODY（退出 8），报出 issue/task/branch/base/commit
你       派一个子代理：用 to-pr skill 读 BASE..COMMIT 写正文
          → 正文落到一个文件
第二趟  run-issue.sh --root R --issue 28 --body-file <那个文件>
          → 走同一套标记判断，直接到 gh pr create
```

**为什么正文不由这个脚本去要。** 它曾经内嵌 `pi -p` 去调模型。那把一个 operator verb
绑死在一个 harness 上:一个 Claude Code 编排者,在一台没装 `pi` 的机器上,**这个 verb
根本跑不起来**。每个 harness 都有自己的子代理机制,这里一个都不写死。

**为什么是子代理,而不是你自己读 diff。** 一次改动的 diff 动辄几十 KB,而这个 verb 的
常规用法是连投(`for n in 28 29 30; ...`)。让它进你的上下文,是每张票几十 KB 地累加;
交给子代理,你只收回正文。**这和「派 subagent 去趟噪音大的活、只把结论带回来」是同一条
理由。**

分工:

| 正文的哪部分 | 谁写 | 为什么归那一侧 |
|---|---|---|
| `Closes #N`、`task:`、`commit:`、`completed_at:` | 脚本 | 下游有东西要解析它们;编错一个 issue 号,代价正是这个 verb 存在的理由 |
| 那几个 `##` 小节 | 你派的子代理,用 `to-pr` | 只有读过 diff 的东西写得出来 |

**形状在 `to-pr` skill 里**,不在这个文件里,也不在脚本里。改 PR 正文长什么样是 skills
仓的一次改动,单独 review;人手动跑 `/to-pr` 拿到的是同一个形状。

**什么会让它大声失败**(都是 `STATUS=ERROR` / 退出 5,而且**都不回退到旧的元数据正文**
—— 那个回退才是 bug,它比失败更坏,因为它看起来像成功):

- `--body-file` 指向的路径不存在。
- 那个文件是空的。**一个空正文的 PR 看起来完成了、却什么都没说。**

第一趟停在 `NEEDS_PR_BODY` 时,分支**已经推上去了**、PR **没开**。原样带 `--body-file`
重跑即可,不会开出第二个 PR —— 幂等判断(这个 head 上是不是已经有开着的 PR)仍然在
脚本里。

### 它拒绝弄错的四件事

- **它绝不把同一个任务 POST 两次。** `pack_web` 的 `create-task!` 只检查名字非空,
  所以第二次 POST 真的会造出第二张卡片和第二条 handoff 记录。任何东西被创建*之前*,
  Board 会先按任务名 grep 一遍。不过卡片已存在并不总是意味着「停」—— 如果对应的分支
  也在,那张卡片就是这个 verb 自己在一次被中断的运行里留下的,第二次调用会续跑它
  (issue #65,见*运行被杀掉之后*)。反过来也成立:有分支没卡片,说明是这个 verb
  更早的一次运行在 POST 之前被杀了,所以那次 POST 是*欠着的*,不是该跳过的
  (issue #76)。
- **它绝不复用一个已经完成的任务身份。** 卡片是按它的 **lane 值**读的,不是按它是否
  存在(issue #115)。`CONTEXT.md` 规定任务的 lane 是「这个任务完没完成」的唯一权威,
  所以 `done` lane 就是那个权威在说话:这一轮结束了。在它上面继续并非无害 ——
  `accept work` 只按任务名做键,于是它会回答*已完成*那一轮的交付记录,PR 随后就带上
  一个根本不在它所指 head 上的 commit(podsum `#112` 上真实发生过)。把同一个 issue
  再过一遍要用 `--round N`,它会给推导出来的身份加后缀;绝不是手工去改 Board。
- **swarm 在等人时它就停。** 一个被卡住的 agent 不会失败 —— 它写下一条澄清请求或一个
  待批准项然后等着,于是它的任务永远到不了 `done`。`/api/state` 的 `clarifications`
  (状态 `pending`)和 `approvals` 会在任何东西被创建之前检查一次,并在每一轮轮询时
  再检查一次。这是循环里唯一一个刻意让它停下来的东西,也是 `for ... || break` 这种
  链式写法安全的原因:没有它,循环会走向下一个 issue,并把下一个分支堆在没人看过的
  工作上面。
- **只有 Board lane 才说一个任务完成了。** 链条是 `coder → cleaner → coder`,而
  `/api/state` 的 `work_in_flight[].state` 在两跳之间会把 coder 读成 `idle`。用角色
  状态去判断会把一个只做了一半的任务算成完成;脚本从不读那个字段。
- **轮询超时不是失败。** 它以 `5` `ERROR` 退出并说明任务可能还在跑,而且**绝不重新
  POST** —— 重 POST 会造出第二张卡片和第二条链。
- **Board 的 `done` 和 `accept work` 是两个不同的事件,不是一个。** `handoffd` 在它
  *投递*一个终端形状的 handoff 的那一刻就把卡片标成 `done`,而 `accept work` 只读
  master 的 `inbox/completed/`,所以只要 master 还在 `inbox/in_process/` 里处理那个
  文件,任务在 Board 上就是 `done` 而在报告里不可见。脚本会在这个窗口里重试
  `accept work`(`SF_RUN_ISSUE_DELIVERY_SECONDS`,默认 600s),而不是只读一次。
  issue #63:只读一次让 `#60` 在 podsum `#30` 上的实跑以 `5` 退出,什么都没推、也没
  有 PR,而那次运行的活其实早就干完了。

### 一次调用一个 issue

没有 `--issues 28,29,30`。列表版本会需要恰好一处错误处理,而调用方本来就有:

```sh
for n in 28 29 30; do run-issue.sh --root R --issue "$n" || break; done
```

退出码 / STATUS 行:

- `0` `PR_OPENED` —— 报文主体带 `issue:`、`task:`、`branch:`、`base:`、`commit:`、
  `resumed:` 和 `url:`。`resumed: yes` 意味着这次调用续的是更早那次被中断的运行,
  而不是 POST 了一个新任务。
- `2` `USAGE` —— 缺 `--root` 或 `--issue`,或者 `--issue` 不是数字。什么都不会跑。
- `5` `ERROR` —— `dashboard-url`/`roles.tsv` 缺失、`gh`/`git`/`curl` 失败、撞到轮询
  上限(`SF_RUN_ISSUE_TIMEOUT_SECONDS`,默认 7200s),或者 Board 说了 `done` 但交付
  记录在整个交付窗口(`SF_RUN_ISSUE_DELIVERY_SECONDS`,默认 600s)里始终对
  `accept work` 不可见 —— 绝不从一个 commit 未经确认的分支上开 PR。两种上限都不会
  push、不会开 PR、也不会重新 POST 任务。
- `6` `UNSAFE` —— 三种之一:一张处在**活跃** lane、但分支不存在的卡片,说明它不是这
  个 verb 的卡片;一张处在 lane **`done`**、且那一轮已经交付过的卡片(它的分支没了,
  或者它 head 上的 PR 是 `MERGED`/`CLOSED`),说明这个身份用完了,报文会点名
  `--round N`;或者有待处理的澄清/批准在挡路。三种情况下什么都没被创建。处在活跃
  lane 且分支*在*的卡片是续跑,不是拒绝;一张那一轮还没交付的 `done` 卡片也是。
- `7` `STILL_RUNNING` —— `--max-wait` 用完了。任务已经 POST,swarm 还在干:什么都没
  push、没开 PR,任务也**没有**被重新 POST。主体带 `lane:` 和 `waiting_for:`,让调用
  方知道它走到了哪一步,重跑同一条命令会从那里接着往下走。它跟 `5` 是两个码,这是
  有意的。`for ... || break` 链在两者上都会断,但「还在干,再叫我一次」和「出事了」
  需要读到这次中断的人做出不同反应 —— 与 GNU `timeout` 用 `124` 退出、而不是复用它
  超时掉的那条命令的退出码,是同一个道理。

PR 永远带着显式的 `--title`/`--body` 打开。**绝不用 `--fill`:** 那会用 swarm 自己的
commit message,而那里面没有 `Closes #N` —— 一个 PR 最后需要人来推断它关掉了哪个
issue,正是这么来的。body 里带 `Closes #<N>`,外加一字不差的 `accept work` 的
`task:`/`commit:`/`completed_at:`,不带 diff 副本:代码在 git 里,PR 只需要那个指针。

任务主体就是 `#26`/`#27` 已经验证过的那份最小交接 —— 读 issue、动手前先盘点、TDD,
以及那条 **从 `roles.tsv` 推导出来的**、而不是写死的 handoff 链,因为角色名因 pack
而异。issue 正文本身刻意不复制过去;coder 自己能读,而副本会过期。

**它还会跟随目标 project 是否使用 OpenSpec**(issue #94)。如果
`$ROOT/openspec/config.yaml` 存在,主体会点名那个文件声明的 `schema:`,并把 coder
指向 `openspec/schemas/<name>/schema.yaml`;如果不存在,主体与之前逐字节相同。是
推导而不是加 flag,理由跟 `CHAIN` 从 `roles.tsv` 推导一样:这个 verb 服务任意被管
project,而其中不少并不用 OpenSpec,所以「走一遍 OpenSpec 循环」对它们是一条错误的
指令。artifact 的顺序刻意**不**写在脚本里 —— 那是 schema 的属性,在这里放一份副本
就等于多了一个 OpenSpec 知识来源,在某个 schema 第一次新增 artifact 时就会悄悄漂移。
podsum 就是这条存在的原因:它合并了自己的 schema,而这个 verb 紧接着的那次运行产出
了 4 个 commit、+414 行和 22 个绿测试,`openspec/changes/` 下面却什么都没有。

**它同样跟随目标 project 有没有约定过 test seam**(pi-governance#455)。如果
`$ROOT/openspec/seams.md` 存在,主体会点名这份名单并要求动手前先读它;不存在时主体与
之前逐字节相同。同样是推导而不是加 flag,理由与上一段一致:没约定过缝的 project 没有
名单可读。

**这一段只给信息,不给流程。** 它不说什么时候该停、什么时候该新立一条缝、缝该切在哪 ——
那些是判断。早先有一版把它们写成了流程,触发条件是「模块不在名单里」,而**在多数被管
project 里那是常态不是例外**:等于把每一轮都变成要人回一趟。判断错了由检查
兜着,不由这段话兜着 —— `code-review` 的 seam baseline 本来就报「新引入的外部依赖没登记
成 seam」与「测试替身的对象不在名单里」,那两条正是「这里到底有没有缝的问题」的信号。

停也不需要这里教。每个角色都读 swarm constitution,那里写着卡住就问操作员;而
`refuse_if_blocked()` 会把任何 pending clarification 变成硬退出 6。**两半都早于这段话
存在,且对所有事有效,不只对 seam。**

### 从 agent 会话里跑它

**这个 verb 会阻塞整条链的时间 —— 几分钟到几小时。那不是卡死。** 它每
`SF_RUN_ISSUE_POLL_SECONDS`(默认 15s)轮询一次,最多到
`SF_RUN_ISSUE_TIMEOUT_SECONDS`(默认 7200s),Board 转成 `done` 之后再最多加
`SF_RUN_ISSUE_DELIVERY_SECONDS`(默认 600s)等交付记录。这个循环是纯 shell:每轮
两次短往返(`curl /api/state`、`cat tasks.tsv`),**没有 model 调用**,所以不管等多久
都不烧 token。烧 token 的是目标主机上 swarm 自己的那些 agent,而那与轮询间隔无关。

**知道你所在 harness 的上限,并传一个 timeout。** 咬人的是*客户端*的默认值,不是
shell tool 自己的天花板:

- **pi 的 `bash`** 在不传 `timeout` 时根本不装定时器
  (`dist/core/tools/bash.js:75-80`,在 `pi-agent-core` 的
  `dist/harness/tools/bash.js:11-19` 里有对应实现),它的天花板是 `MAX_TIMEOUT_MS =
  2_147_483_647` ms —— 大约 24.8 天(`dist/core/tools/bash.js:16`)。这棵树里没有任何
  东西会按时钟中止一次 tool 调用;`AbortController` 只在用户中止和会话销毁时触发,而
  超时消息是用调用方传进来的 `timeout` 值拼出来的,所以它只可能打印某人发过来的数字。
  因此 issue #65 里记下的那 **120 秒**不是 pi 的:那是客户端注入的默认值,传一个显式
  的 `timeout` 就能去掉它。(在 `@earendil-works/pi-coding-agent@0.84.3` 上实测:不传
  `timeout` 时 `sleep 150` 在 120s 被杀;传 `timeout: 300` 时同样的 `sleep 150` 跑
  完了。)
- **Claude Code 的 `Bash`** 默认 2 分钟(`BASH_DEFAULT_TIMEOUT_MS`),并**硬性**
  封顶在 10 分钟(`BASH_MAX_TIMEOUT_MS`)。没有任何参数能抬高那个天花板。

所以,按这个顺序来:

1. 在 tool 接受 timeout 的地方传一个**显式的大 timeout**(pi 的 `bash` 收的
   `timeout` 单位是秒)。
2. 在硬上限低于一条真实链条的地方 —— Claude Code 的 10 分钟就是 —— 用 **`--max-wait`**
   取一个略低于它的值,让 verb 干净地以 `7` `STILL_RUNNING` 退出而不是被 SIGKILL,
   然后再调用一次。干净退出会报出它走到的 lane;被杀掉什么都报不出来。
3. 用 harness 的**后台模式**,如果它有的话(Claude Code 的 `Bash` 收
   `run_in_background: true`)。
4. 实在不行就让它被杀掉,然后**重跑同一条命令**。那是一条受支持的路径,不是修补
   (见下)。

不要为了躲开上限而把调用包进 `nohup ... &`。取消一次 pi 的 tool 调用会杀掉整棵进程
树,连那个脱离出去的作业一起带走,而一次脱离运行的输出会跑到没人在读的地方去。

不要在它跑着的时候用第二次调用去 `read swarm` 「看一眼」—— 脚本已经在轮询了,第二个
读者告诉不了你任何它自己不会打印的东西。

### `--max-wait <seconds>` —— 调用方的期限

`SF_RUN_ISSUE_TIMEOUT_SECONDS` 和 `SF_RUN_ISSUE_DELIVERY_SECONDS` 是*被调用方*的
天花板;在 issue #76 之前,调用方没有办法说出自己能等多久,而一个在 600s 处杀掉它的
harness 产出的是 SIGKILL 而不是一次退出。`--max-wait` 是调用方自己的预算,墙钟时间,
覆盖整次调用。语义就是 `kubectl wait --timeout` 的语义,刻意不去发明第四种:

| 值 | 含义 |
|---|---|
| 正数 | 最多等这么久,然后以 `7` `STILL_RUNNING` 退出。对这次调用取代上面两个天花板。 |
| `0` | 检查一次就返回:欠着 POST 就 POST,然后报出当前 lane。 |
| 负数 | 保持既有的天花板。这是默认值(`-1`),所以不带这个 flag 时行为不变。 |

到达它是一次**干净退出,不是被杀**:什么都没 push,没开 PR,任务从未被重新 POST,
报文会点名它停在哪个 lane。这份预算同时覆盖轮询**和** `accept work` 的交付窗口,
所以是一个数字框住整条命令,而不是框住它的某一个阶段。

### 运行被杀掉之后

**重跑一模一样的命令。** 这个 verb 会检测出它自己更早那次运行,并从停下的地方接着
走:它绝不 POST 第二个任务、绝不创建第二个分支、也绝不开第二个 PR。续跑的运行会在
报文主体里打印 `resumed: yes`。

它看什么,以及它做什么:

| `issue-<N>-<slug>` 的 lane | 分支 `feat/issue-<N>-<slug>` | 会发生什么 |
|---|---|---|
| 没有 | 没有 | 全新运行 |
| 没有 | **在** | **续跑** —— 跳过建分支,POST 那个从没 POST 出去的任务 |
| 活跃(`coder`、`cleaner`、…) | 在 | **续跑** —— 跳过建分支和 POST,从轮询接上 |
| 活跃 | 没有 | `6` `UNSAFE` —— 那张卡片不是这个 verb 的;什么都不碰 |
| **`done`**,head 上没有 PR | 在 | **续跑** —— swarm 那一半结束了,交付那一半没有:`accept work`、push、开 PR |
| **`done`**,PR 是 `OPEN` | 在 | 那个 PR *就是*终态:`0` `PR_OPENED`,再报一次,什么都不重做 |
| **`done`**,PR 是 `MERGED`/`CLOSED` | 在 | `6` `UNSAFE` —— 这一轮完了;用 `--round N` 重跑 |
| **`done`** | 没有 | `6` `UNSAFE` —— 这一轮完了,分支也没了;用 `--round N` 重跑 |

分支之所以是那个标记,是因为这个 verb 永远在 POST *之前*创建它。一张处在**活跃**
lane、分支却不存在的卡片,是有人手工敲进 Dashboard 的、或者是别的什么东西造的,在
它上面继续会推上去这个 verb 从未界定过范围的工作。

lane 是按**值**读的(issue #115)。一个只问卡片存不存在的判断,分不出一个已完成的
轮次和一个被中断的轮次,而这两者需要相反的答案。但 `done` 本身也不构成停止:一轮有
两半 —— swarm 走到 `done`,然后这个 verb 把它交付出去 —— 而 `STILL_RUNNING` 承诺过
重跑会继续第二半。它指向的那个窗口(Board 上是 `done`、交付记录还不可见、什么都没
push)恰好就是「一张 `done` 卡片,有分支,没有 PR」,所以 PR 是第三个标记:没有 PR、
或者有一个开着的,都意味着这一轮仍然该由这个 verb 收尾。

第二行是那两次写入**之间**的窗口,大约两次 ssh 往返那么宽,而在 issue #76 之前它没有
出口:没有卡片,verb 走全新路径,对一个已经存在的分支跑 `git checkout -b`,然后以
`5` `ERROR` 失败 —— 每一次重跑都如此,直到有人手工删掉那个分支。现在每次运行都会读
两个标记,而那两个决定(建分支、POST 任务)各自只对自己的标记负责,所以这两次写入
无论以什么顺序发生,都产生不出一个没有出路的状态。

不跑任何东西就想知道自己处在哪个状态:

```sh
scripts/read-swarm.sh --root <project-root>          # is the swarm still working?
ssh <target> "grep '^issue-<N>-' <root>/.swarmforge/board/tasks.tsv"   # lane, column 2
```

**活跃** lane 意味着任务已经 POST,重跑永远是对的动作。**`done`** lane 意味着 swarm
干完了:还没有 PR 就重跑把它交付出去,已经有了就用 `--round N`。

**边界:** 这个 verb 开一个 PR 然后停下。它从不合并(`--merge` 和 `--auto` 永远不会
被传),从不回答澄清(`read swarm` 甚至不知道有这个概念 —— 那是另一个 issue),也从不
改 Dashboard 的监听地址或角色 topology。从 `UNSAFE` 恢复是人的活:在 Dashboard 里
解决澄清;用 `--round N` 给一个用完的身份开新一轮;至于活跃 lane 里的外来卡片,在
Dashboard 里给它改名,或者手工用 `accept work` 接走它的工作。

**绝不为了强制重跑而手工清掉 Board 或 handoff 状态。** 一张 Board 卡片和
`inbox/completed/` 下的那些记录是历史,不是操纵杆:`CONTEXT.md` 规定任务的 lane 是
「这个任务完没完成」的唯一权威,而这个 verb 自己的契约让 `accept work` 成为一份不改
动 `inbox/` 下任何东西的报告。为了让这个 verb 看到一次「全新」运行而从 `tasks.tsv`
里删掉一行、或删掉一个 completed handoff,是在手工做这个 verb 必须自己判断的事 ——
而且这件事根本做不干净:任务名是三个互相独立的状态来源(卡片、分支、交付记录)的
键,所以清掉续跑表里点名的那两个,仍然会剩下第三个被下一次运行匹配上。podsum `#112`
开出一个所指 commit 根本不在它 head 上的 PR,就是这么来的:那次运行对「本轮交付
记录」的等待,被*上一轮*的记录满足了,比真正那一份早了 8 分钟。

**用 `--round N` 重跑一个已完成的 issue。** 身份仍然是推导出来的 ——
`issue-<N>-<slug>-r2`,分支 `feat/issue-<N>-<slug>-r2` —— 所以第 2 轮自己也可以靠
重跑同一条命令来续跑,而第 1 轮的卡片、分支和交付记录原封不动地留在那里,作为它们
本来就是的历史。第 1 轮不带后缀,所以这个 verb 曾经产出过的每一个名字都未变。

## Verb: `ship project`

把 swarm **已经干完的活**推上 GitHub，停在一个可 review 的 PR 上。它与 `run issue`
的分工就一句话：**卡是谁切的。**

`run issue` 发布的是它自己派下去的那一张卡 —— 分支是它建的，task 名是它从 issue
推的，所以它从头到尾都知道自己在等什么。上游的 lieutenant forge 是另一种形状：
卡由人在 dashboard 上切、或由 lieutenant 按 `.swarmforge/routes.tsv` 切并推进，这边
既没建过分支，也不提前知道任何 task 名。

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
  [--branch <name>] [--base <name>] [--test-cmd <cmd>] [--issue <N>]... \
  [--body-file <path>] [--dry-run]
```

**它不走 Dashboard。** 看板、handoff、git 全部从 managed project 自己磁盘上读，所以
`pack_web` 没开也能跑，**Forge 下的 project 也能跑** —— 那种 project 根本没有自己的
`dashboard-url`（`swarmforge.bb` 的 `run-project!` 不起 `pack_web`，只有 Forge 自己那一个）。

### 五道门，按顺序，任一失败就停

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
 base 上干的活 —— 就是「合并后没人 `git pull`」那个坑换了扇门进来。`run issue` 在同一个
条件上是**拒绝**，因为它正要在那上面**开工**；这里活已经干完了，拒绝只会把它扒在那里。
同一句话会跟进 PR 正文。

**E 验证。** 自动发现入口（`make test` / `npm test` / `pytest` / `./gradlew test`），
`--test-cmd` 可覆盖。**红就阻断，没有绕过的 flag** —— 一个 `--allow-failing-tests`
只会在它最该拦住你的那一天被用一次。找不到入口就报 `skipped (no test entry
point found)`，并把这一句带进 PR 正文。

### 它存在的真正理由：Done 与已合入是两件事

上面五道门里没一条是这个 verb 的核心。核心是第六条检查：

`handoffd` 是在它**投递**终端 handoff 的那一刻把卡标成 `done` 的，master 合入它是
之后的事。在这个窗口里发布，`git log origin/<base>..HEAD` 会安静地带着一个
**子集** —— 一个看起来完整、实际少了一张卡的 PR。所以每条交付记录的 commit 都要
过一遍 `git merge-base --is-ancestor <commit> HEAD`，差一条就阻断并点名，绝不聆聆
肩。过一会儿再跑就好。

「要发什么」本身不在这里重算：它直接跑 `accept-work.sh`。那个脚本已经拿下了两个
难点 —— 只从 master worktree 读终端记录，以及排掉 commit 已经到了 origin 的任务。

### 两趟，跟 `run issue` 一样的形状

```text
第一趟  ship-project.sh --root R
          报告 → 五道门 → 建分支 → git push
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

与 `run issue` 同一条分工，但 `Closes` 有**三个来源，并集去重，三个都不猜**：

**卡文本里的 `#N`。** 卡文本就是 operator 在 New Task 里敲的东西（`pack_board` 的
`write-body!` 写在 `.swarmforge/board/<卡名>.txt`），它带着 issue 号。**只读本次要发的
那几张卡**，不扫整块板 —— 不在这个 PR 里的卡不得往里面放 `Closes`。

**`--issue N`（可重复）。** 卡文本里没写、或要补一个时用。`#42` 和 `42` 都收。

**卡名推导，只对 `issue-<N>-<slug>` 生效。** 那是 `run-issue.sh` 自己铸的形状。这一条
**是精确形状匹配，不是扫描**，因为卡名是**推导出来的**；卡文本是一个正对着 issue 的
人**手敲的**，这是扫它公平而扫卡名不公平的区别。

推导结果在报告的 `will close:` 一行里，而且它印在**停在 `NEEDS_PR_BODY` 那一趟**，
比 PR 早 —— 推错了还有一趟可以改。

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
- `0` `NOTHING_TO_SHIP` —— `accept work` 没有未交付记录，或 HEAD 没超前 `origin/<base>`。
  不是错，没有任何东西被推。
- `0` `DRY_RUN` —— `--dry-run`，只出报告。
- `2` `USAGE`、`5` `ERROR`。
- `6` `BLOCKED` —— 门没过。报告照样打印，末尾带 `blockers:` 列表；什么都没改。
- `8` `NEEDS_PR_BODY` —— 分支已推，PR 未开，等你的 `--body-file`。

报告在**每一条路径**上都打印，包括被阻断的那一条：拒绝的理由只有跟它读到的
状态放在一起才有用。

## Verb: `stop swarm`

跑随包的脚本;它在停任何东西之前先做 preflight(issue #11):`stop swarm` 过去是一次
裸的 `close-swarm` 调用,没有宽限期,也不检查角色状态和未提交的工作,等同于拔电源
而不是关机。脚本现在会报出一次停机会打断什么,并要求人先做决定,然后才碰 tmux。

```sh
scripts/stop-swarm.sh --root <project-root> \
  [--target user@host] [--key <path>] [--local] [--force] \
  [--close-swarm <path-on-target>]
```

### `close-swarm` 在哪(issue #82)

`close-swarm` 是**在目标上**跑的,而默认路径是 operator 自己那台机器的:
`/Users/admin/project/swarm-forge/close-swarm`。被管 project 不带这个文件 —— 它有
`./swarm` 但没有 `close-swarm`,`swarmforge/scripts/` 里也没有 —— 所以在一台 home
不是 `/Users/admin` 的目标机上,你必须说明它在哪:

```sh
# find it once per target, then pass it
ssh -n -i <key> <target> 'ls ~/project/swarm-forge/close-swarm'

scripts/stop-swarm.sh --root <root> --target <target> --key <key> \
  --close-swarm /home/<user>/project/swarm-forge/close-swarm
```

环境变量里的 `CLOSE_SWARM` 仍然有效;flag 压过它。给错了这个 verb 现在会说出来 ——
`5` `ERROR`,带着 close-swarm 自己的 stderr,而不是 `STOPPED`。

它读 `sessions.tsv`,用与 `read swarm` 完全相同的方式对每个角色的 pane 分类(同一套
`BUSY`/`IDLE`/`UNKNOWN` 判断,同一份共享代码 —— 这两个 verb 绝不能对一个角色的状态
产生分歧),然后读 `roles.tsv` 的 worktree 路径列,对每一个跑 `git status --porcelain`
(去重,因为 `master`/`none` 两种行都解析到 project 根)。只有当每个角色都读成
`IDLE`、每个 worktree 都干净时,它才跑 `close-swarm` 一直以来做的那次停机 —— 然后
**检查它真的生效了**。

它随后还会按 `$ROOT/.swarmforge/pack_web.pid` 里的 pid 停掉 `pack_web`,并报
`PACK_WEB=stopped|absent`。`close-swarm` 只知道 tmux;留着一个还在跑的 dashboard,
意味着之后一次在固定端口上的启动会让同一个 `$ROOT` 有两个活的 `pack_web` 进程,而
那正是 `dashboard` 的端口归属检查存在要拒绝的蹲位情况。

退出码 / STATUS 行:

- `0` `STOPPED` —— 每个角色都是 `IDLE`,每个 worktree 都干净(或者传了 `--force`);
  swarm 以它今天一贯的方式被停掉了。
- `2` `USAGE` —— 缺 `--root`。
- `3` `STOPPED` —— `sessions.tsv`/`roles.tsv`/`tmux-socket` 缺失,或者 socket 上没有
  tmux server;没有东西可停。
- `5` `ERROR` —— verb 自己跑失败了,**或者 `close-swarm` 没跑成**(issue #82)。主体
  带上 close-swarm 自己的 stderr 和试过的那个路径。swarm 仍然活着;什么都没被停掉。
  在这一项被检查之前,一个在目标上根本不存在的 `close-swarm` 会打印
  `STATUS=STOPPED` 并以 `0` 退出,而每个 tmux session 都还活着。
- `6` `UNSAFE` —— 某个角色读成 `BUSY` 或 `UNKNOWN`,或者某个 worktree 是脏的(或者它
  的状态根本无法核实 —— 一律当作不安全,绝不当作干净)。**什么都没改**:没有
  `kill-session`,没有 `close-swarm` 调用。把 `PREFLIGHT` 块报给用户,让人来决定是等
  还是带 `--force` 重跑。

  一条只点名 SwarmForge 自己安装的文件的 `DIRTY` 行,意味着那个 project 早于
  issue #87,从没拿到那个 `.gitignore` 块 —— 见 `onboard project` 下面的*已经 onboard
  过的 project*。把那个块加上并提交;不要伸手去拿 `--force`,它连 project 真正未提交
  的工作也一起豁免掉了。

在 `6` `UNSAFE` 时,stdout 会在 `STATUS=` 之后带一个 `PREFLIGHT` 块,每发现一个不安全
条件一行:

```
STATUS=UNSAFE
PREFLIGHT
BUSY=cleaner
UNKNOWN=coder
DIRTY=.worktrees/cleaner (12 files)
```

**`--force` 完全跳过 preflight 闸门** —— 不读状态文件,除了停机本身之外不为任何事去
碰 tmux。它是人明确做出的、要打断正在跑的东西的决定;脚本从不替它假设。它豁免的只有
preflight:停机到底跑没跑成仍然会被检查,所以 `--force` 照样可能以 `5` `ERROR` 退出。

**边界:** 这个 verb 不实现逐 agent 的优雅关闭 —— 不向任何 backend 发 `/exit`,也不等
它收尾。它只是在一次不可逆的 `kill-session` 之前把状态摊给人看。它也从不替某个角色
提交:一个脏的 worktree 会挡住停机,但这里没有任何东西会写 commit —— 那仍然是人的
决定。如果干净停机或强制停机之后清理仍不彻底,重新解析这个 project 的 socket,只杀
那一个 tmux server,并用精确的 project 根去匹配 `handoffd.bb`;确认其它 project 的
daemon 仍在运行。

## Testing

`scripts/test-ship-project.sh` 用真 git、桩 `gh` 跑 `ship-project.sh`：`origin` 是一个
本地 bare 仓，所以 fetch/push/rev-list/merge-base 全是真跑的（换成桩 git 就变成在测桩），
只有会真的碰 GitHub 的 `gh` 被打了桩。覆盖快乐路径（报告、建分支、恰好一次 push、停在
`NEEDS_PR_BODY` 且不开 PR）、带正文的第二趟（恰好一次 `gh pr create`）、head 上已有开着
的 PR 时返回旧 URL 且不再创建、一张在角色 lane 的卡阻断而一张 `waiting` 卡不阻断、未提交
改动阻断并点名文件、`delivery_attention` 阻断、**Done 且有交付记录但 commit 还不是 HEAD
祖先时阻断**（master 还在合并的那个窗口，这是这个 verb 存在的理由）、测试红阻断而绿照报、
无未交付记录时 `NOTHING_TO_SHIP` 且不建分支、角色 worktree 与 forge 根各自被拒、空的和
不存在的 `--body-file` 都硬失败且不开 PR、`--dry-run` 不建分支，以及一张 lieutenant 风格
命名的卡不产生任何 `Closes` 行。这五处若被改坏都会红（已实测：去掉「不是 HEAD 祖先」阻断、
去掉脏工作区门、去掉 PR 幂等检查、把 `waiting` 当成 live、去掉测试红阻断）。

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

卡文本那条路径自己带三个用例：`#N` 从**本次要发的**卡里读出来并出现在 `will close:` 与
`Closes` 里、另一张 `waiting` 卡文本里的 `#999` 一个字都不进来（读整块板会红）、`--issue`
与卡文本合并后同一个号只出现一次（去掉 `sort -u` 会红）。没有卡文本的卡报 `will close: none`
而不是报错。
`scripts/test-open-swarm.sh` 和 `scripts/test-open-dashboard.sh` 对着打了桩的
cmux/ssh/curl 跑这两条流程,覆盖 topology 配对、复用、修复、停机、drift、无法解析的
mutation 输出、隧道复用,以及端口冲突时的回退。`test-open-dashboard.sh` 还额外给 `ps`
打桩(经由 ssh 桩,外加一份假的 `pack_web.pid`/进程注册表)来覆盖端口归属检查:一个
`--serve` 参数指向另一个根的活进程(退出 4 DRIFT,实际的根打在 stdout 上,完全不调用
cmux)、一个缺失的 `pack_web.pid`,以及一个进程已死的 `pack_web.pid`(两者都退出 3
STOPPED,不是 4)。`scripts/test-wake-talk.sh` 对着打了桩的 tmux 跑 `wake-role.sh` 和
`talk-role.sh`,覆盖经过验证的提交、一个始终没落地的提交键、一个未知角色、一个死掉的
socket,以及两个脚本都绝不用符号键名 `C-m`/`C-j` 提交。`scripts/test-read-swarm.sh`
对着打了桩的 tmux 跑 `read-swarm.sh`(capture-pane 按 session 分别打桩,所以一次运行
可以给两个角色不同的 pane 内容),覆盖一个明确的 idle 标记、一个明确的 busy 标记、
一个空白 pane(必须读成 `UNKNOWN`,绝不能是 `IDLE`)、认不出来的错误文本(`UNKNOWN`,
且原始文本照样附上)、一个死掉的 socket,以及脚本从不调用 `send-keys`。
`scripts/test-stop-swarm.sh` 对着打了桩的 tmux/git/close-swarm 跑 `stop-swarm.sh`,
覆盖一个 `BUSY` 角色、一个 `UNKNOWN` 角色、一个 `DIRTY` worktree、`--force` 绕过闸门、
一次全干净的停机,以及一个死掉的 socket —— 并断言在每一种被拦下的情况里,
`kill-session` 和 `close-swarm` 一次都没被调用过。`scripts/test-accept-work.sh` 对着
打了桩的 `git` 跑 `accept-work.sh`(find/sed 是对着 fixture 文件真跑的,用 `--local`
所以 ssh 从不被调用),覆盖一次没有卡住 handoff 的干净运行、一个还新鲜(尚未变陈旧)
因而不能 WARN 的 `inbox/new` 文件、一份陈旧的 `inbox/new` 积压和一份陈旧的
`inbox/in_process` 积压(两者都要带上条数和 worktree 名 WARN)、一个在它更长阈值之内
因而不能 WARN 的进行中 `inbox/in_process` 文件、已交付 commit 的排除、跨链条跳的终端
handoff 去重,以及两次运行绝不改动任何 `inbox/` 树下的一个字节。
`scripts/test-start-swarm.sh` 对着打了桩的 tmux/ssh 和一个假的 `./swarm` launcher 跑
`start-swarm.sh`,覆盖缺 `--root`/`--terminal`、一个非法的 `--terminal` 值、一个已经
在跑的 swarm(拒绝,launcher 从不被调用)、一个陈旧的死 socket(继续启动)、
`--terminal` 的值到达 launcher 的环境、`auto` 从不被导出,以及启动超时。它那几个关于
脱离终端的用例证明的是真实的进程存活,而不是 argv 的形状:一个假 launcher 记下自己的
PID 并一直睡到 `start-swarm.sh` 早已交还控制权之后,测试断言 start-swarm.sh 在那段
延迟结束之前很久就返回了,然后给 launcher 发一个真实的 `SIGHUP`(本地情形 —— 一个正在
关闭的会话会投递的信号)并确认它之后仍然跑完并写下它的标记文件,以及(远端情形,经由
一个真的执行启动命令而不只是记录它的 `ssh` 桩)标记文件只在那次桩 ssh 调用本身已经返回
之后才出现。`scripts/test-update-swarmforge-scripts.sh` 对着打了桩的 tmux/ssh 跑
`update-swarmforge-scripts.sh`,staging、算 digest、校验与替换都用真实的本地文件系统
操作(只在 ssh/tmux 边界处打桩,依 issue #29 的 Testing Decisions),对着用本仓库自己
脚本的真实副本搭出来的一次性 fixture git 仓库跑,这样「脏来源」那个用例永远不依赖当前
checkout 自己的实时 git 状态。覆盖缺 `--root`、一个已经在跑的 swarm(带 `--force` 也
拒绝,零文件系统改动)、project 锁竞争并点名持有者以及 `--force` 抢走它、一份脏的来源
checkout、一棵缺了必需 helper 或 terminal adapter 的 staged 树(点名那个文件,`$ROOT`
未被碰)、一次成功的本地 update(manifest 的 digest/commit/repo 正确、旧树消失、历史
launcher 已重写并核实,`swarmforge.conf`/roles/constitution/`sessions.tsv` 前后逐字节
相同)、一个 `ARCHIVE_URL` 始终不符合预期模式的历史 launcher(回滚脚本换入和 manifest
写入,不只是回滚 launcher)、一次 manifest 写入失败(旧树被恢复)、一个根本没有历史
`./swarm` 文件的 project(跳过 launcher 改写,不算错误)、一次经由桩 ssh 的 tar 管道
传输的完整远端 update,以及那个必需的跨 verb 用例:本脚本自己成功 update 之后,不带
`--force` 的 `start-swarm.sh --local` 直接走到 `STATUS=STARTED` 而不是 `DRIFT`,证明
本脚本写下的 digest 与 `start-swarm.sh` 自己对它的读取是真的一致的。
`scripts/test-run-issue.sh` 对着打了桩的 `gh`/`git`/`curl` 和一个打了桩的
`accept-work.sh` 跑 `run-issue.sh`,用 `--local` 所以 `ssh` 从不被调用,而
`dashboard-url`、`roles.tsv` 和 Board TSV 都是被真实 `cat` 读的真实文件。lane 的推进
由桩驱动 —— POST 桩在 master lane 里创建卡片,每次 `/api/state` 调用把它往前推一个
脚本化的 lane —— 所以「它等了多少轮」是一个可断言的数字,而不是一次竞态。它覆盖缺失/
非数字的参数(什么都不跑)、一张重复的 Board 卡片(退出 6,没有 POST,board 和
handoff 逐字节相同,没有创建分支)、POST 之前的一个待处理澄清和一个待处理批准(退出
6 并点名 id,什么都没创建)、轮询中途出现的一个澄清(在它出现的那一轮精确退出 6,没有
PR)、`BASE` 取自一个开着的 PR 的 head 以及回退到 `main`、分支与任务名共用一个 slug、
任务主体点名从 `roles.tsv` 推导出来的 handoff 链、一个在 lane 仍是 `coder`/`cleaner`
时中途转 idle 的 coder(继续等,而且 `work_in_flight` 在脚本里除注释外从不出现)、
轮询上限(退出 5,恰好一次 POST,没有 PR),以及 PR 的 argv 本身:`--base`/`--head`/
`--title`/`--body` 都在,body 里有 `Closes #N` 和 `accept work` 的 `commit:`,而
`--merge`、`--auto`、`--fill` 都不在。有两个用例覆盖 issue #63 的交付窗口,用的是一个
会成功报告、但在设定的次数内省略当前任务那一段的 `accept work` 桩:一个是记录在第三次
调用时出现(退出 0,恰好一次 push、恰好一次 `gh pr create`,而且仍然只有一次 POST),
另一个是它始终不出现(退出 5 并点名 `in_process`,没有 push、没有 PR、没有重新 POST)。
issue #65 的续跑路径靠对同一份 fixture 跑两遍脚本来覆盖:第一遍在 POST 之后被切断
(一个永远到不了 `done` 的 lane,加上一个为零的轮询上限),第二遍必须以 0 退出并带
`resumed: yes`,同时 Board 里仍然恰好只有一张卡片,两次运行合起来恰好产生一次 POST、
一个分支、一次 push 和一次 `gh pr create`。第三个用例在 head 已经有 PR 之后重跑,并
断言 `gh pr create` 不会被再次调用。issue #76 那个死胡同有它自己的用例:分支注册表里
预置了那个分支而 Board 留空 —— 正是一次在第 4 步和第 5 步之间被杀掉的运行会留下的
状态 —— 这次运行必须以 0 退出,没有创建第二个分支,恰好 POST 了一个任务,并开了一个
PR。那个用例之所以真的咬得住,是因为 `git` 桩的 `checkout -b` 现在会像真 git 一样
**在分支已存在时失败**;换成一个永远成功的桩,它对着有 bug 的脚本也会通过。
`--max-wait` 从四个方向被覆盖:`0` 在恰好一次 lane 检查之后以 `7` `STILL_RUNNING`
退出,没有 push 也没有 PR,并且之后可以像任何一次被杀掉的运行一样续跑;交付窗口期间
的 `0` 退出 `7` 而不是 `5`;一个负值仍然走到老的 `5` `ERROR` 上限;一个非数字值退出
`2`,一条命令都没跑。issue #115 把卡片那一行按 lane 值拆开,拿到五个用例:一张带着
分支、没有 PR 的 `done` 卡片,仍然把它被留在的那一轮交付出去(退出 0,`resumed: yes`,
不重新 POST);同一张卡片但 head 上带着一个 `CLOSED` PR 时退出 `6`,点名那个 PR 和
`--round`,board 与 handoff 逐字节相同且没有 push;同一张卡片但 PR 是 `OPEN` 时仍然
退出 0 并报出它;一张没有分支的 `done` 卡片退出 `6` 并点名 `--round`,而且明确**不**
给出老的「删掉它或改个名」补救说法,与此同时一个没有分支的*活跃* lane 一字不差地保留
那句补救说法;以及 `--round 2` 在带后缀的身份下全新跑一遍,第 1 轮的卡片原封不动,而
`--round 0` 和一个非数字值在任何命令跑起来之前就退出 `2`。有一项结构性检查为它们兜底:
脚本必须在注释之外把 `EXISTING_LANE` 与 `done` 做比较,因为一个只测 lane 是否为空的
判断本身就是那个 bug,不管那些行为用例看起来多绿。为了这些用例,`git` 桩维护一份真实
的分支注册表 —— `checkout -b` 记下一个名字,`rev-parse --verify` 从它那里作答 ——
因为一个永远退出 0 的桩会让续跑用例和「不是我们的卡片」用例都因为错误的理由而通过。
它的 `accept work` 桩会先打印一行 `WARN=` 和一段诱饵任务块,这样一个按行偏移而不是按
`task:` 前缀解析的解析器就会失败。任何一次改动脚本或桩的契约之后,都要跑一遍它们。

`scripts/test-provision-forge.sh` 跑 `provision-forge.sh`。这里有两样东西是**真的**,
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
