# Research: upstream 的 lieutenant 是什么、有什么用

> **2026-09-17 后记：** 本报告的结论（dispatcher lieutenant 与 `run-issue.sh` 是替代关系，
> 不是互补关系）已被采纳为决定，见
> [ADR-0007](../adr/0007-the-fork-keeps-only-the-lieutenant-forge-path.md)：`run issue`、
> `onboard project`、`update SwarmForge scripts` 三个 verb 已删除，本 fork 只保留
> lieutenant forge 一条路径。下文提到 `run-issue.sh` 的地方读作写作当时的现状。

Pinned refs：`upstream/main@f4f5fbcae0de6f7dcc26e82400334227647cfdb2`（2026-09-04）、
`upstream/lieutenant@23653942488281a3c6d9a60b7e9378be0a1ca1c2`（2026-09-07）、
`upstream/project-manager@2cc1795fbd1f5cedefd0c371aa1835464d1b4a15`（2026-09-04，用于第 B
节的逐条对照）、`main@e32af056b85a601e0e04c352e1a734331f770b9e`。`git remote -v`：
`upstream` → `https://github.com/unclebob/swarm-forge.git`。

---

**`lieutenant` 是三层，不是两个：同一个角色名字 `swarmforge/roles/lieutenant.prompt`，在
`upstream/main` 上只有 11 行、是被动参谋（禁止实施 project 活，只能总结/建议/指点
`mission.md`），在 `upstream/lieutenant` 分支上被改写成 90+ 行的 planner & dispatcher（
「You are the planner and dispatcher. ... You cut cards.」，靠 `pack_board create/move/stop`
主动切卡、起卡、停卡，靠 `.swarmforge/routes.tsv` 决定一张卡经过哪些 role）；而
`upstream/lieutenant` 本身又是 upstream 的第五个 `get-swarm-forge` 产品分支（本 fork 没有）。
对本 fork 而言，`swarmforge-operator` skill（尤其 `run-issue.sh`）扮演的正是分支版
dispatcher lieutenant 的角色，两者是**替代关系**，不是互补关系——`main` 版被动参谋才是与
operator skill 边界互补的那一个。**

## Summary

读了：`upstream/main` 上的 `swarmforge/roles/lieutenant.prompt`、`swarmforge/scripts/
swarmforge.bb`（parse/launch/run-host! 相关函数）、`swarmforge/scripts/pack_web.bb`（chat/
inject/dashboard-state 相关函数）、`swarmforge/scripts/pack_dashboard_request.bb`、
`swarmforge/scripts/pack/dashboard.html`（chat 渲染片段）、`README.md`、`project-board.md`、
`get-swarm-forge`；`upstream/lieutenant` 上的 `README.md`、`.swarmforge/project-pack/` 树、
**同名但内容完全不同的 `swarmforge/roles/lieutenant.prompt`**（planner & dispatcher 版，
90 行）、`.swarmforge/project-pack/swarmforge/swarmforge.conf`（四条 `card` 路由）、
`swarmforge/scripts/pack_board.bb`（`create`/`move`/`stop` 子命令）、`swarmforge/scripts/
card_type.bb`（路由查表）、`swarmforge/scripts/swarmforge_config.bb`（`card` 行解析、
`.swarmforge/routes.tsv` 写入）；`upstream/project-manager:README.md`（对照用）；本 fork 的
`.agents/skills/swarmforge-operator/SKILL.md`、`docs/fork-deltas.md`（第 92、354、445、475、
485 行附近）、本 fork issue #135 全文含评论；以及三个真正命中 `lieutenant` 的测试文件——
`test/dashboard/dashboard.spec.js`、`test/swarmforge/pack_ui_test.clj`、
`test/swarmforge/script_test.clj`（初次按已知事实第 5 条的印象猜文件名，猜成了
`pack_web_test.bb`/`handoff_test.clj`，两者在 `upstream/main` 上根本不存在；用
`git grep -ci lieutenant upstream/main` 核实后改读对的三个文件，见 Findings D）。

**本报告第一版把 `swarmforge/roles/lieutenant.prompt` 当成一个跨分支不变的文件，是一处需要
返工的实质错误：这个路径在两条分支上是同名不同内容的两份 prompt。** `main` 上 11 行，被动
参谋；`upstream/lieutenant` 上 90+ 行，开头即「You are the planner and dispatcher. Project
roles do not ask the operator for the next feature. You cut cards.」（`git show
upstream/lieutenant:swarmforge/roles/lieutenant.prompt` 第 22-23 行）。已知事实第 1 条已经
把「lieutenant 是 host 角色」和「lieutenant 是产品分支」分成两个不能混为一谈的东西；这里是
第三层——同一个角色（同一个 `swarmforge/roles/lieutenant.prompt` 路径）在这两条分支上装的
是两份完全不同的 prompt，行为不能互相代入。

核心发现：

1. **host lieutenant 的启动是独立的运行模式，不是「多一个 role 行」。** `run-host!`
   （`swarmforge.bb:936-960`）单独构造只有一行 `:roles` 的 ctx（`lieutenant-row`），既不跑
   `prepare-worktrees!`/`prepare-handoff-dirs!` 也不起 `handoffd`（对比 `run-project!`），
   只起 tmux 会话、`pack_web`、打开终端。
2. **`Lieutenant <backend> [args...]` 由专用 parser 读，缺行不报错、缺 prompt 文件才报错。**
   `parse-lieutenant-config`（`swarmforge.bb:887-895`）在配置行缺失时静默 fallback 到
   `SWARMFORGE_LIEUTENANT_AGENT` 或 `"grok"`；但 `run-host!` 在 `lieutenant.prompt` 文件本身
   缺失时用 `fail!` 硬失败（`swarmforge.bb:942-944`）。
3. **operator 在 dashboard 打字 → tmux pane 是一条单向注入链，没有专门的“提交键”修正。**
   `POST /api/chat` → `write-chat-request!` 落盘一个 pending 文件 → `inject-master!` 找到
   `worktree-name == "master"` 的行（forge 模式下就是 lieutenant 自己）→ `inject-target!`
   永远发字面 `-l text`、`C-m`、`C-j`（`pack_web.bb:127-134`），不区分 backend。lieutenant
   自己回话靠 `pack_dashboard_request.sh answer <id> <file>`，把同一个 pending 文件挪进
   `done/` 并写 `response` 字段，dashboard 下一次轮询 `/api/state` 时把它渲染进聊天气泡
   （`dashboard.html:1362-1372`）。
4. **`upstream/lieutenant` 分支不是「再装一份 pack」，是单模板 forge，`.swarmforge/
   project-pack/` 是唯一被提交的项目模板**，与 `project-manager` 下载三条 pack 分支到
   `packs/` 形成整洁对照——已在已知事实第 6 条给出，这次用 upstream README 逐字核对无误。
5. **`upstream/lieutenant` 分支的 lieutenant 是一套指挥模型，不只是「多几条 prompt 规则」：**
   人给方向（`mission.md`、New Task 选 LT 是指令而非建卡）→ lieutenant 主动提议下一批卡、
   求批准（「Do not wait for the operator to name those cards.」）→ 批准后它自己用
   `pack_board create --type`/`move --caller lieutenant` 切卡起卡 → role 按
   `.swarmforge/routes.tsv` 走 handoff → `card-done` notify 回到 lieutenant 触发下一轮。
   卡的类型（`utility`/`component`/`QA`/`review`）直接决定这件事经过哪些 role、按什么顺序，
   prompt 里的选型硬规则就是路由决策——见 Findings B。
6. **`main` 版被动参谋与 `swarmforge-operator` skill 边界互补，但 `lieutenant` 分支版
   dispatcher 与 operator skill 是替代关系，不是互补关系：** 本 fork 的 `run-issue.sh`
   （POST task → 轮询到 done → accept work → push → 开 PR）扮演的正是 dispatcher lieutenant
   「决定下一件事做什么、批准后驱动它走完」的角色，只是决策方是调用方而不是一个常驻 LLM——
   见 Findings C。两者往 pane 里发文本的机制仍有差异：operator skill 的 `wake-role.sh`/
   `talk-role.sh` 按 backend 分支提交键（CSI-u/裸回车，fork 自己的 D-2 修复），而 `main` 上
   dashboard 的 `inject-target!` 从未做这个区分（Findings A4、Gaps）。

## Findings

### A. 角色层：host lieutenant 的运行时生命周期

**本节全部证据来自 `upstream/main`。** `main` 上的 `lieutenant.prompt` 是被动参谋（Findings
B 已确认）；`upstream/lieutenant` 分支的同名文件被改写成 planner & dispatcher，运行时脚本也
被拆成 `swarmforge_config.bb`/`swarmforge_launch.bb`/`swarmforge_terminal.bb` 等，函数签名
可能同名但实现不同（例如下面 A1 引用的 `forge-root?`，在该分支上判据从「只查 `packs/`」变成
「`packs/` 或 `projects/` 二选一」——`git show upstream/lieutenant:swarmforge/scripts/
swarmforge.bb` 里同名函数第 336-338 行）。以下 A1-A5 讲的启动流程、chat 注入链路只在 `main`
上核实过，不能直接套到 `lieutenant` 分支。

**A1 → 起点是 `./swarm`，落到 `run-host!`，不是 `run-project!`。** 判定依据是 `forge-root?`
（`swarmforge.bb:911-912`：`(fs/directory? (fs/path root "packs"))`）——只要 host 目录下有
`packs/`（`project-manager` 装的），`swarm` 就走 forge 分支而非单 project 分支。`run-host!`
全文（`swarmforge.bb:936-960`）：

```clojure
(defn run-host! [root]
  ...
  (let [row (lieutenant-row ctx)
        ctx (assoc ctx :roles [row] :host? true ...)]
    (when-not (fs/exists? (fs/path (:roles-dir ctx) "lieutenant.prompt"))
      (fail! ...))
    ...
    (fs/create-dirs (fs/path (:working-dir ctx) "projects"))
    ...
    (doseq [name lingering] (run-stop-project! ...))  ; 清理上次遗留的 open-projects
    (kill-existing-sessions! ctx)
    (boot-sessions! ctx)
    (start-pack-web! ctx)
    (launch-roles! ctx)
    (announce-ready! ctx)
    (open-terminal-surfaces! ctx)))
```

对照 `run-project!`（`swarmforge.bb:1004-1017`），`run-host!` **不调用**
`prepare-worktrees!`、`prepare-handoff-dirs!`、`start-handoff-daemon!`——host 层没有 worktree、
没有 handoff 队列，lieutenant 不是收发 handoff 的 pack 角色。

**A2 → `Lieutenant <backend> [args...]` 由 `parse-lieutenant-config` 单独解析，与 pack
角色行（`window <role> <backend> <worktree> ...`）不共用一套 parser。**
`swarmforge.bb:887-895`：

```clojure
(defn parse-lieutenant-config [ctx]
  (let [file (:config-file ctx)
        fallback (str/lower-case (or (not-empty (System/getenv "SWARMFORGE_LIEUTENANT_AGENT")) "grok"))]
    (if-not (fs/regular-file? file)
      {:agent fallback :extra-args nil}
      (or (some (fn [raw] ...
                  (when (and (>= (count fields) 2) (= (str/lower-case (first fields)) "lieutenant"))
                    ...))
                (str/split-lines (slurp (str file))))
          {:agent fallback :extra-args nil}))))
```

配置文件不存在、或存在但没有 `lieutenant` 行，两种情况都静默 fallback 到 `grok`（可用
`SWARMFORGE_LIEUTENANT_AGENT` 环境变量覆盖），**不报错**。`lieutenant-row`
（`swarmforge.bb:907-909`）把 worktree 名硬编码成字面量 `"master"`，这是 `special-worktree?`
识别的哨兵值（`window-row` 里 `:worktree-path` 直接取 `(:working-dir ctx)`，不是
`.worktrees/lieutenant`）——lieutenant 就跑在 forge 根目录本身，不占用一个独立 worktree。

真正会硬失败的是 prompt 文件本身缺失，`swarmforge.bb:942-944`：

```clojure
(when-not (fs/exists? (fs/path (:roles-dir ctx) "lieutenant.prompt"))
  (fail! (str red "Error:" reset " Missing lieutenant prompt at " ...)))
```

**A3 → lieutenant 的 pane 里跑的是纯 prompt 文件，不套 `constitution.prompt` 前缀，也不带
初始一次性 user prompt。** `write-agent-instruction-file!`（`swarmforge.bb:450-459`）：

```clojure
(if (= role "lieutenant")
  (fs/copy (fs/path (:roles-dir ctx) "lieutenant.prompt") prompt-file {:replace-existing true})
  (spit (str prompt-file) (str "Read swarmforge/constitution.prompt, ..." ...)))
```

普通 pack 角色的 prompt 文件是拼出来的（先读 constitution，再读角色 prompt，再插入
`tool-startup-section`）；lieutenant 的 prompt 文件就是 `lieutenant.prompt` 原文，未加工。
`launch-command`（`swarmforge.bb:501`）里 `initial-prompt? (not= role "lieutenant")`——lieutenant
是唯一一个启动时**不会**把 prompt 文件内容再当一次性初始消息喂给 agent CLI 的角色（其余角色
`claude`/`codex`/`copilot`/`grok` 都会）；它的全部指令都来自 `--append-system-prompt-file`
（claude）/ `--rules`（grok）等系统级 prompt 挂载点。

**`swarmforge/roles/lieutenant.prompt` 与 `.swarmforge/prompts/lieutenant.md` 不是两条独立
路径，是「源模板 → 启动时字节复制产物」的一条链，前者是后者唯一的来源。** `context`
（`swarmforge.bb:759-763`）里 `state-dir` 绑定到 `<root>/.swarmforge`（运行期状态根，
`gitignore` 掉），随后在返回的 map 里 `:roles-dir` 绑定到 `<root>/swarmforge/roles`
（`swarmforge.bb:775`，提交进仓库的源模板目录），`:prompts-dir` 绑定到
`<root>/.swarmforge/prompts`（`swarmforge.bb:784`）。`run-host!`（`swarmforge.bb:942-944`）检查的是**源模板**
`(:roles-dir ctx)/lieutenant.prompt` 存不存在，缺了就 `fail!`；`write-agent-instruction-file!`
（`swarmforge.bb:450-454`）在真正启动那一刻把这份源模板**原样字节复制**（`fs/copy`，对
lieutenant 是唯一路径，不像其它角色那样拼接）到 `prompt-file`，也就是 `launch-command`
里算出的 `(:prompts-dir ctx)/lieutenant.md`（`swarmforge.bb:498`）；再由 `launch-command` 把
这份运行期副本的路径喂给 `--rules "$(cat ...)"`（grok）或 `--append-system-prompt-file`
（claude）。测试 `grok-lieutenant-launch-waits-for-chat`（`test/swarmforge/script_test.clj:397-413`）
与 `lieutenant-launch-reads-host-conf`（同文件 `:415-430`）用 `swarmforge.bb --test-lieutenant-launch-command`
这个测试钩子（钩子本体在 `swarmforge.bb:1017-1023`）断言的正是这条链的产物：命令行里出现
`.swarmforge/prompts/lieutenant.md`，且该文件在断言时刻已经被 `fs/copy` 写到磁盘上。

**A4 → operator 在 dashboard 打字之后，数据流是「落盘请求文件 → tmux 注入 → lieutenant CLI
落盘应答文件 → dashboard 轮询渲染」，中间没有 WebSocket，也没有直接的进程间调用。**

```
POST /api/chat  (pack_web.bb:1732)
  → post-chat (pack_web.bb:1003-1008)
      write-chat-request! root text        ; .swarmforge/dashboard/requests/pending/<id>.request
      inject-master! root (chat-wake id text)   ; text = "[id] text" 或 "[id]\n<multiline>"
        → master-row root                   ; 选 roles.tsv 里 worktree-name == "master" 的行
        → inject-role! root role text
            → inject-target! socket target text
                send-keys! socket target "-l" text
                (sleep 150ms) send-keys! socket target "C-m"
                (sleep  50ms) send-keys! socket target "C-j"
```

（`pack_web.bb:127-134` 定义 `inject-target!`；`pack_web.bb:154-155` 定义 `inject-master!`；
`pack_web.bb:721-737` 定义 `chat-id`/`chat-wake`/`write-chat-request!`；`pack_web.bb:1003-1008`
定义 `post-chat`。）forge 模式下 `master-row` 命中的正是 lieutenant 那一行——因为它的
`worktree-name` 字段（`roles.tsv` 第 2 列）被硬编码成 `"master"`（A2）。lieutenant 收到
`[id] text` 之后，prompt 里写明的应答方式是：

```
pack_dashboard_request.sh answer <id> ./tmp/answer.txt
```

`answer-request!`（`pack_dashboard_request.bb`）把 `pending/<id>.request` 挪到
`done/<id>.request`，写入 `response` 字段；`clarify` 走一套平行的目录
（`dashboard/clarifications/{pending,done}`），由 lieutenant **主动发起**而不是回应 operator。
dashboard 侧 `list-chat`（`pack_web.bb:692-694`）同时扫 `pending/` 与 `done/`，
`renderChat`（`dashboard.html:1360-1372`）按 `id` 增量渲染，并把 `lieutenant_status`（forge
状态里 `pane-status-lines-for root "lieutenant"` 摘的最近两条状态句，`pack_web.bb:785,803`）
显示在最新一条还没应答的气泡下面，作为“正在思考”的实时提示，不是应答本身。

**A5 → `forge-dashboard-state`（`pack_web.bb:780-825`）是 forge 模式独有的状态聚合函数**，
与单 project 的 `dashboard-state`（`pack_web.bb:747-757`）平行存在；`:master_role
"lieutenant"`、`:master_display "Lieutenant"` 是硬编码字面量，不是从 `roles.tsv` 推导——forge
模式下 host 角色的名字永远叫 `lieutenant`，与项目内谁是 `master` worktree（`coder`/
`specifier`，因 pack 而异）是两回事。

### B. 产品层：`upstream/lieutenant` 分支装出来是什么

**B1 → 结构：两级、一个可编辑模板。** `upstream/lieutenant:README.md:19-46`：

```text
<forge>/
  swarm
  swarmforge/{swarmforge.conf, roles/lieutenant.prompt, scripts/, constitution/articles/}
  .swarmforge/
    project-pack/                # 唯一被提交的部分
      swarmforge/{swarmforge.conf, constitution.prompt, roles/{specifier,coder,cleaner,
                  architect,hardender,QA}.prompt}
  projects/                      # 生成的项目，forge 自己的 git 忽略
```

`.swarmforge/project-pack/` 在 upstream 树上确有其文件（`git ls-tree -r upstream/lieutenant`
命中全部 8 个路径，与 README 描述的六个角色 + `constitution.prompt` + `swarmforge.conf`
一一对应）。`get-swarm-forge`（`upstream/main`）安装时按产品分叉：`product == "lieutenant"`
时调 `install_project_pack`（把这份模板复制到 `.swarmforge/project-pack/`），其余产品调
`install_named_packs`（下载三条独立 pack 分支到 `packs/`）——`get-swarm-forge:247-264`。

**B2 → host 配置行示例是 `Lieutenant codex`**（`upstream/lieutenant:README.md:62-64`），
与 `project-manager` 默认无 `Lieutenant` 行时 fallback 到 grok（对照 A2）形成对比——两条
产品分支都用同一个 `parse-lieutenant-config`（来自 `main` 的共享 `swarmforge.bb`），只是各自
提交的默认 `swarmforge.conf` 不同。

**B3 → 项目模板自带一套 upstream/main 上没有的“card 路由”语法**，即已知事实第 4 条提到的
“typed card routes”。`.swarmforge/project-pack/swarmforge/swarmforge.conf` 的语法是：

```text
card <type> <first-role> [<next-role>...]
window[-invisible] <role> <backend> <worktree> [task|batch] [forward-only|back-one|back-all] [...]
```

四种默认 card：`utility`（`coder → cleaner → Done`）、`component`（加 `specifier`/
`architect`/`hardender`）、`QA`（再加 `QA`）、`review`（`cleaner → architect → hardender →
QA → Done`，不新增行为）。`README.md:109-112`（`upstream/main`）明确说这层扩展语法**不是**
`main` 共享的语法，是 `lieutenant` 分支自己的解析器负责的：「Branches may extend the grammar
for their own control plane... The selected branch README and its parser are the authority
for those extensions.」

**B4 → 分支装出来的不只是「单模板 forge」，是一套不同的指挥模型：人给方向，lieutenant
排班、切卡、追进度，只在特定动作上停下来找人。** 引用与行号全部来自 `git show
upstream/lieutenant:swarmforge/roles/lieutenant.prompt`：

- **角色定位**（第 22-23 行）：「You are the planner and dispatcher. Project roles do not
  ask the operator for the next feature. You cut cards.」——这份文件自己的第 19-20 行还留着
  一句与 `main` 版几乎同源但用词已经改过的话：「You may summarize status, suggest a project
  or a card, and point at `mission.md`.」（`main` 版原文是「suggest a **pack or project**」，
  这里已经改成「a **project or a card**」）。第 22-23 行的「You cut cards」把这句「suggest」
  从建议改成了指令——同一份文件里前半段还是被动参谋的措辞，后半段已经宣布自己会真的动手切卡，
  两段不是互相矛盾，是「前半段管日常问答、后半段管排班决策」的分工。
- **选卡型 = 选路由**（第 25-39 行）：「Choose among the card types configured for that
  project. The route written to `.swarmforge/routes.tsv` is authoritative」，随后是三条硬性
  排除规则——第 32 行「Never review for new product behavior」、第 33-34 行「Never utility
  for a protocol or business rule. Never component for a new button, menu, or visible
  layout.」把 B3 那四种 card 路由变成一张判定表：新产品行为不许走 `review`（只经
  `cleaner→architect→hardender→QA`，没有 `specifier`/`coder` 写新行为）、协议/业务规则不许
  走 `utility`（只有 `coder→cleaner`，没有 `specifier` 写 Gherkin、没有 `architect`/
  `hardender` 把关）、新按钮/菜单/可见布局不许走 `component`。
- **提议 → 求批准 → 自己起卡**（第 40-52 行）：「As soon as the next cards are obvious,
  propose them ... and ask for approval. Do not wait for the operator to name those
  cards.」批准之后，`create --type … --waiting` 落一张等待卡，某条 starting lane 一空出来，
  lieutenant 自己用 `pack_board move ... --caller lieutenant` 把它起进去——这一步**不需要**
  再问一次操作者（`request-allow` 是不允许的路径）。
- **notify 驱动重新排班**（第 53-61 行）：`git_handoff` 到达记 `<from>-handoff`，卡走完记
  `card-done`；New Task 记 `new-task`；新开的 project 记 `new-project`（触发读那个
  project 的 `mission.md` 并行动）；`allow` 记消费一个批准令牌；`reverse-cleared` 记回收
  逆向集成后重新评估所有等待卡；pack 发的 `clarify` 记「找卡住的地方」。这七种 notify 是
  lieutenant 重新规划的全部触发点，不是靠轮询。
- **打扰人类有闸门，起已批准的卡没有：**（第 65-69、84-87 行）Board 的 `done`/`stop`/
  `increment-audit`，以及移动一张**在跑（live）**的卡，都要求先过 Attention；但「Starting a
  waiting card into its starting lane does not need Attention」——只有已经在跑的卡被打断才
  惊动操作者，把一张已批准的等待卡排进空出来的 lane 不需要。
- **New Task 打了 LT 标记时是指令，不是建卡请求**（第 88-91 行）：「New Task marked LT is a
  directive: fit that name and text into the plan... It does not create a card.」——与
  `main` 版把每条 chat 消息都当自由格式请求处理不同，这条路径有专门的语义。

这套模型的运行时支撑不是 prompt 单方面承诺的：`pack_board.sh` 的 `create --type ... [--waiting]
[--caller lieutenant]`/`move`/`stop` 子命令确有其事（`swarmforge/scripts/pack_board.bb:13-14`
usage 行，`142-146` 的子命令分发表）；卡型到路由的查表在 `swarmforge/scripts/card_type.bb`
（`chain`/`next-role`/`last-role` 等函数读 `.swarmforge/routes.tsv`）；`.swarmforge/
routes.tsv` 本身由 `swarmforge/scripts/swarmforge_config.bb` 解析 `swarmforge.conf` 里的
`card` 行写出（`138` 行判断 `(str/starts-with? line "card ")`，`177` 行 `write-routes-file!`）。

**B5 → 与 `project-manager` 逐条对照，轴换成「谁决定下一件事做什么、谁决定它经过哪些
role」：**

| 维度 | `project-manager` | `lieutenant` |
|---|---|---|
| 项目模板来源 | 安装时下载 3 条独立 pack 分支到 `packs/`，不提交进 forge 自己的树 | 1 个模板提交在 `.swarmforge/project-pack/`，随 forge 分支一起版本控制 |
| New Project 时选什么 | 从 `packs/` 里选 two/four/six-pack，人替每个 project 选定一条固定管线 | 只有一个模板，六个角色、四种路由都装进同一个 project，具体某个任务走哪条路由由 lieutenant 逐卡决定 |
| 谁决定下一件事做什么 | 人：New Task、New Project 都是人发起的显式动作 | lieutenant 主动提议，人只批准/否决（`main` 版则连提议都不做，见 B4 第一条） |
| 谁决定经过哪些 role | 人在装 project 时选好 pack，之后固定不变 | lieutenant 逐卡选 card type，即逐卡决定路由（B4 第二条） |
| 项目内路由语法 | 沿用 `main` 的固定管线语法（`window` 行，顺序即管线） | 多一层 `card <type> <role>...`（`.swarmforge/project-pack/swarmforge/swarmforge.conf:11-14`），同一份 conf 里先声明角色再声明四条路由 |
| host lieutenant 默认 backend | 无 `Lieutenant` 行时 fallback grok（`project-manager:README.md` 明写） | 提交的默认配置显式写 `Lieutenant codex` |
| Open Project 刷新什么 | 刷新脚本、shared articles、conf 模板来源 | 同样刷新受管脚本/文章/角色 prompt，但**保留项目自己的 `swarmforge.conf`**（README 原文强调这点） |

**B6 → operator 典型工作流（按 README 与 B4 合并）：** `get-swarm-forge lieutenant && ./swarm`
→ 只起 dashboard + 一个 lieutenant tmux 会话，`projects/` 是空目录 → operator 在 dashboard 上
New Project 或用 chat 给方向（写进 `mission.md`）→ lieutenant 读 mission/board，主动提议一批
卡，operator 在 chat 里批准或否决 → lieutenant 切卡、起卡，role 按 route 走 handoff，卡走完
notify `card-done` → lieutenant 重新评估、提下一批。Attention 只在卡被打断（stop/live 卡
移动）或 lieutenant 主动 `clarify` 时出现，日常排班不打扰人。chat 的注入机制（tmux send-keys）
仍是 A4 描述的那条链——host 侧运行时脚本确实是从 `main` 复制过去的（README 原话：「The
runtime scripts... their canonical home... are on main; this branch carries the copies
required for a standalone lieutenant install.」）——但**装进 pane 里跑的 prompt 完全不同**，
chat 承载的是「给方向、批卡」而不是「问状态」。

### C. 对本 fork 有什么用：lieutenant vs `swarmforge-operator` skill

**这里必须分两版单独回答，因为两版 lieutenant 对 operator skill 的关系正相反。** `main` 版
被动参谋与 `lieutenant` 分支版 dispatcher 是同一个角色名下两份完全不同的 prompt（Summary 与
Findings B 已确认）——拿 `main` 版去跟 operator skill 对照、得出「边界互补」，回答的是错误的
问题：本 fork 实际会拿来对照的候选是分支版 dispatcher，不是 `main` 版参谋。

**C1 → `main` 版被动参谋：与 operator skill 边界互补，各管各的。** 轴线是「谁往 pane 里发
东西、谁汇总状态」——两者都做这两件事，但机制和精度不同：

| 能力 | `main` 版 host lieutenant（角色 prompt + `swarmforge.bb`/`pack_web.bb`） | `swarmforge-operator` skill（本 fork） |
|---|---|---|
| 状态汇总 | dashboard 的 `/api/state` 全量聚合，lieutenant 靠读 pane 与 chat 上下文自己组织语言 | `read-swarm.sh`：逐 role 三态分类（`IDLE`/`BUSY`/`UNKNOWN`），report verb，附原始 pane 文本供人核对 |
| 往 pane 里发东西 | dashboard chat → `inject-target!`，永远 `-l text` + 裸 `C-m`/`C-j`，**不区分 backend**（Findings A4） | `wake-role.sh`/`talk-role.sh`：按 `sessions.tsv` 记录的 backend 分支提交键，并**验证**提交真的落地 |
| 实施 project 的活 | **明文禁止**——`lieutenant.prompt`（`main`）：「Do not implement project work. That belongs to pack agents.」 | `run-issue.sh` **正是干这个的**：POST task → 轮询 Board 到 `done` → `accept work` 取 commit → `git push` → 开 PR |
| 能力形态 | LLM 角色，没有固定的「正确回答」 | 确定性脚本，固定退出码 |

`main` 版止步于「总结、建议、指向 `mission.md`」，从不驱动任何一件事走到底；`run-issue.sh`
才是那个真正把一件事从提出到 PR 走完的东西。两者管的是不同的事，互不覆盖，这条结论站得住。

**C2 → `lieutenant` 分支版 dispatcher：与 operator skill 是替代关系，不是互补关系。** 轴线
换成 Findings B4/B5 用的那两条——「谁决定下一件事做什么」「谁决定它经过哪些 role」：

| 决策点 | `lieutenant` 分支的 dispatcher | 本 fork 的 `swarmforge-operator` skill |
|---|---|---|
| 谁决定下一件事做什么 | lieutenant 主动提议卡（名字、类型、依赖），操作者只批准/否决（`lieutenant.prompt:40-44`） | 调用方（人或另一个 agent）逐个决定要不要对某个 issue 跑 `run-issue.sh`，脚本自己不提议 |
| 谁决定它经过哪些 role | lieutenant 逐卡选 card type，即决定路由（`.swarmforge/routes.tsv`，`lieutenant.prompt:25-39` 的选型硬规则） | 路由由 project 自己的固定 pack 配置决定（two-pack/four-pack/six-pack 装的时候就定了），`run-issue.sh` 不改路由，只把一个任务喂给已经固定的管线 |
| 起下一批工作要不要再问人 | 已批准的等待卡起进空闲 lane **不需要**再过 Attention（`lieutenant.prompt:84-87`） | `run-issue.sh` 每次调用都是一次显式的人工/agent 决策（`--issue N`），没有「自动起下一个」这一层 |
| 卡住/完成之后谁接手重新规划 | lieutenant 收 `card-done`/`clarify` 等 notify 自己重新排班（`lieutenant.prompt:53-64`） | `accept-work.sh` 只读完成记录报给人看，不自动接着做下一步；下一步仍是调用方决定 |
| 实现载体 | 常驻 LLM 角色，行为由 prompt 与当次上下文决定，出错模式是「切错卡型」「提议了不该提议的」 | 一次性调用的确定性脚本，出错模式是可枚举、可测试的固定退出码 |

`run-issue.sh` 已经在做「决定一件事该走到 PR」这件事——只是决策权在调用它的人/agent 手上，
一次一个 issue；`lieutenant` 分支的 dispatcher 把同一件事做成了常驻、批量、主动提议的版本，
决策权在 lieutenant（受操作者批准约束）手上。这是**同一种能力的两种实现**，不是两种能力，
所以是替代关系：真要把 dispatcher 模型接进本 fork，`run-issue.sh` 承担的角色会被
lieutenant 取代或吸收，而不是与它并存互补。

### D. 测试钉住了 lieutenant 的哪些行为

**本节引用的测试全部来自 `upstream/main` 的测试套件**（`test/swarmforge/`、
`test/dashboard/`），钉的是 `main` 那版被动参谋的行为。`upstream/lieutenant` 分支的
dispatcher lieutenant（切卡、`.swarmforge/routes.tsv`、`pack_board create/move/stop`，见
Findings B）有没有对应的测试、测试住了哪些场景，本次研究没有读那个分支的测试文件，不在这四
条之内。

五条钉子（D4 打包了两个 deftest），横跨启动命令、forge state、dashboard UI 三层，逐一读原文
核实过行号：

**D1 → forge state 有一个 lieutenant 专属字段，读的是一个专属会话目录下的 pane 文件，不是
Work Queue 的一行。** `forge-state-includes-lieutenant-status-lines`
（`test/swarmforge/pack_ui_test.clj:2525-2543`）：种下 `.swarmforge/roles.tsv` 的
lieutenant 行（见 D3）和 `.swarmforge/sessions/lieutenant/pane.txt` 两行状态句，跑
`swarmforge.bb --test-state`，断言返回的 JSON 里 `forge: true` 且 `lieutenant_status` 等于
那两行原文。这条字段的产生路径是 `pack_web.bb` 的 `forge-dashboard-state`
（`pack_web.bb:803`：`:lieutenant_status (pane-status-lines-for root "lieutenant")`）→
`pane-status-lines-for` → `live-pane-text`（`pack_web.bb:1418-1421`：先试 `capture-pane`
实时 `tmux capture-pane`，失败再退到 `recorded-pane`）→ `recorded-pane`
（`pack_web.bb:1441-1448`）的「direct」分支：`.swarmforge/sessions/<role>/pane.txt` 存在就
直接 `slurp` 整份，不走按任务分子目录（`pane-files`/`pane-for-task`）那条路径——那条路径是给
有 worktree、按 `task:` 分子目录记录 pane 快照的 pack 角色用的，lieutenant 没有 worktree、
没有 task，天然只可能命中「direct」这一支。

**D2 → dashboard 上 Work Queue 与聊天面板之间有一条独立的可拖拽分割线，纯布局，不是第二条
状态链路。** `"Work Queue / lieutenant split is draggable"`
（`test/dashboard/dashboard.spec.js:136-153`）操作的是 `.rail-splitter` 把 `.work-sec`
（Work Queue 区）和 `.ts`（聊天面板）的高度此消彼长地拖动，断言只是两个 `boundingBox()` 的
高度增减——没有涉及 `lieutenant_status` 或 chat 数据本身，是纯 UI 布局测试。

**D3 → chat 的「正在处理」提示，颜色和内容都被钉住。**
`"pending lieutenant chat shows green status under the request"`
（`test/dashboard/dashboard.spec.js:347-366`）直接手写两份 fixture——`.swarmforge/dashboard/
requests/pending/req-1.request`（一条 pending 聊天请求）和 `.swarmforge/sessions/lieutenant/
pane.txt`（两行状态句，与 D1 用的是同一份文件、同一套状态提取机制）——断言页面上
`#chat-history [data-chat-id="req-1"] .bubble-status` 同时包含两行状态句（各自带 `"| "` 前缀）
且 CSS `color` 是 `rgb(47, 107, 58)`（绿色）。这就是 A4 里说的「显示在最新一条还没应答的气泡
下面」在测试里的确证：`lieutenant_status`（D1 的字段）与 chat 的 pending/done 文件（A4 的
`.request` 文件）是两条独立取数的链路，只在这一个 UI 位置合流渲染——没有第三个位置消费
`lieutenant_status`，也没有 chat 内容本身依赖 pane 文本。

**D4 → 启动命令的形状按 backend 分叉，且 `--test-lieutenant-launch-command` 是唯一验证入口。**
`grok-lieutenant-launch-waits-for-chat`（`test/swarmforge/script_test.clj:397-413`）在默认
（无 `Lieutenant` 配置行）情况下断言命令含 `grok --cwd `、`--minimal --rules "$(cat `、
`.swarmforge/prompts/lieutenant.md`，且**不含** `--verbatim`（即 A3 说的「不带初始一次性
user prompt」），并断言该 `.md` 文件此刻确实已经落盘。`lieutenant-launch-reads-host-conf`
（同文件 `:415-430`）种下 `swarmforge/swarmforge.conf` 里的 `Lieutenant claude --yolo`，
断言命令换成了 `claude --append-system-prompt-file ` 且带 `--yolo`、不再含 `grok --cwd `——
证实 A2 说的「`Lieutenant <backend> [args]` 配置行确实决定 launch command 里的 backend 与
透传参数」，backend 切换不是只换了个字符串，两种 agent 拼接的 flag 集合完全不同。

**D5 → `roles.tsv` 里 lieutenant 行的八个字段，逐一对上 `write-roles-file!`
（`swarmforge.bb:248-260`）的列定义：**

```
lieutenant  master  <root>  swarmforge-lieutenant  Lieutenant  grok  task  forward-only
role        wt-name wt-path session               display-name agent recv-mode propagation
```

（fixture 来自 `test/swarmforge/pack_ui_test.clj:2532-2534`。）`wt-name = master` 正是
Findings A4 里 `master-row`（`pack_web.bb:117-118`：`(some #(when (= "master" (nth % 1 nil)) %)
...)`）能命中 lieutenant 那一行的直接原因——第 2 列（0 起标的 index 1）就是 `worktree-name`，
forge 模式下这一列被 `lieutenant-row`（`swarmforge.bb:907-909`）硬编码成字面量 `"master"`，
不是因为 lieutenant 恰好落在某个真的叫 `master` 的 worktree 上（A2 已指出它的
`:worktree-path` 直接是 `working-dir` 本身）。`recv-mode = task`、`propagation = forward-only`
是 `window-row` 调用时的固定实参，但 `run-host!` 从不启动 `handoffd`（Findings A1），也没有
第二个角色能收到 lieutenant 的 handoff——这两个字段在 forge 模式下没有对应的运行时消费者，
是「行必须填满这两列」的语法要求，不是「lieutenant 真的会转发/回溯 handoff」的行为声明；
`git grep -ni lieutenant` 对 `swarmforge/scripts/handoffd.bb` 与 `swarmforge/scripts/
swarm_handoff.bb` 两个文件**都没有匹配到任何一行**，两份 handoff 收发逻辑里没有任何一处按角色名
`"lieutenant"` 分支，与 A1「`run-host!` 从不起 `handoffd`」互相印证。

## Gaps

- **未证实：`project-board.md` 的权威性。** 它读起来像一份多项目 forge 的设计/规格文档
  （按章节编号列「4. Host dashboard API」「5. Cockpit UI」「6. Lieutenant」「7. Restart」
  「8. Tests and README」这种验收清单式写法），与 `platoon-brainstorm.md` 不是同一类文档（它
  没有 brainstorm 的发散语气，读起来已经是收敛后的实施规格），但本次研究没有找到它与
  `project-manager`/`lieutenant` 实际实现之间的 commit 级对应关系，不能断言它是「先写规格、
  后按规格实现」还是「先实现、后补规格」，也不能排除它已经过时（部分描述，例如「Teardown
  kills the lieutenant」，本次只在 README 层面交叉核对过，未在代码里逐条验证 Teardown 的
  具体实现）。引用它的结论（B5、A4 的部分措辞）已经优先用 README 与源码复核过一遍，但
  `project-board.md` 本身在本文里只作为背景说明，不作为独立证据。
- **需要人决定：`inject-target!` 不分 backend 是不是一个真实的缺陷。** Findings C 指出
  dashboard chat → lieutenant/master 的注入路径（`pack_web.bb:127-134`）与本 fork
  `wake-role.sh`/`talk-role.sh` 的 CSI-u 分支修复（对应 `docs/fork-deltas.md` 的 D-2）覆盖的
  不是同一段代码——D-2 钉的是 `handoffd.bb` 的 `submit-keys`（daemon 唤醒角色去跑
  `ready_for_next.sh`），不是 `pack_web.bb` 的 chat 注入。本次研究**没有**实测过一个
  backend 是 `claude` 的 lieutenant（或 `master`）在收到 dashboard chat 消息时，裸 `C-m`
  是否真的会被提交——如果不会，这是 upstream 自己在两条独立代码路径上留的口子，只有其中一条
  被本 fork 意外堵上；如果会（claude CLI 在某些模式下裸 Enter 也能提交），那这条 Gap 不成立。
  这需要真机验证，不是读源码能确定的。
- **需要人决定的不是「要不要多供应一个产品分支」，而是要不要把本 fork 的指挥模型从「人直接
  操作 project（New Task、`run-issue.sh` 逐个喂 issue）」换成「人批准方向，lieutenant 排班、
  切卡、追进度」（Findings C2）。** 这不是本次研究要回答的问题——issue #135 已经把「要不要
  跟进 `lieutenant` 分支」定性为产品决定，本文只补充了两版 prompt 的行为细节、以及它和本 fork
  现有 `run-issue.sh` 是替代而非互补关系这一点，供那个决定使用。
