## Context

`docs/research/upstream-lieutenant.md` 已经把两条血统的差别记全：`upstream/lieutenant` 的
`lieutenant.prompt` 是 90+ 行的 **planner & dispatcher**，靠 `pack_board create/move/stop`
主动切卡、靠 `.swarmforge/routes.tsv` 决定路由；`upstream/main` 上同名文件只有 11 行，是
**被动参谋**。那份报告的结论是：本 fork 的 `run issue` 扮演的正是分支版 dispatcher
lieutenant 的角色，**两者是替代关系，不是互补关系**。

当时那句话是个警告。操作者决定转向 lieutenant forge 之后，它变成了本 change 的依据。

## Goals / Non-Goals

**Goals**

- 让本 fork 只剩一条安装与派活路径：lieutenant forge。
- 把「为什么放弃 Pack 路径与三种 topology」变成可查的决定，而不是某次会话里的口头共识。
- 删干净：脚本、测试、SKILL.md 正文、spec、以及 `ship project` 里的寄生措辞。

**Non-Goals**

- 不删 `origin/two-pack`、`origin/four-pack`、`origin/six-pack` 三条 product 分支。删分支是
  单独一次决定，而且分支留着不产生维护成本。
- 不动 `swarmforge/scripts/`（本仓 `main` 上那份 main 血统的 script snapshot）。它是
  `two-pack` 等分支的来源，本 change 只退休消费它的 operator verb。
- 不迁移任何现存 managed project。迁移是操作者的动作，不是本 change 的交付物。
- 不改 `origin/lieutenant`。

## Decisions

### 1. 三个 verb 一起删，不分批

它们由同一个前提支撑（Pack 路径存在），前提一倒三个一起倒。分批删会留下一段
「`onboard project` 没了但 `update SwarmForge scripts` 还在」的中间状态——后者的存在理由
恰恰是「修补 onboard 出来的树」，单独留着它比删掉更难解释。

### 2. `ship project` 的卡名 `Closes` 分支跟着删

`closes_numbers()` 有三个来源：卡文本的 `#N`、`--issue N`、卡名 `issue-<N>-<slug>`。第三个
**只有 `run issue` 会铸出来**。`run issue` 一删，它在一个周期之内变成死代码，而死代码是会被
后来的人当成还在服务某个真实场景的。删它不损失能力：卡文本的 `#N` 覆盖同一需求，而且
`ship project` 的 `will close:` 行在 `NEEDS_PR_BODY` 那一趟就把结果印出来。

### 3. capability 按 requirement 摘，不按文件删

`snapshot-install-safety` 的 5 条里有 2 条不属于被删的 verb：

- 「自管 snapshot 的项目不做 drift 判定」的主体是 **`start swarm`**，那个 verb 保留。
- 「装 script snapshot 的 verb 负责写描述它的 manifest」是 **ADR-0006**，约束的是所有安装
  路径，`provision forge` 首当其冲。

整份文件删掉会静默丢掉这两道守卫。**降级方向必须是少删，不是多删。**

`script-snapshot-provenance` 的 2 条一条都不删，只收窄措辞：两条决定（snapshot 来自本 fork、
安装原子且留 manifest）对 forge 路径照样成立，要去掉的只是「Pack 分支自带的 swarm launcher」
那一侧的举例。

### 4. 立 ADR，而不是只写在 proposal 里

`two-pack` 是一个会被反复提议补回来的东西：它更轻、更便宜，而「lieutenant forge 只有一个
6 角色模板」这个约束藏在 `forge.bb` 一行 `pack-dir [root _pack]` 里，不看代码看不出来。
`improve-codebase-architecture` 的规矩是 ADR 记录的决定不再被重新提议——这正是需要它的形状。

### 5. #152 随本 change 关闭，不单独修

#152 记的是 `run issue` 在 Forge 下的三处断点（project 没有自己的 `dashboard-url`、
`POST /api/tasks` 在 forge 根缺 `project` 会 400、`/api/state` 的澄清与批准跨 project 聚合）。
主体删掉之后这三处不存在了。修一个即将被删的 verb 是纯浪费。

## Risks / Trade-offs

- **三种 topology 没了。** 轻量的两角色流水线不再可得。接受，理由记进 ADR；真的需要时，
  恢复路径是把 `two-pack` 的 `swarmforge.conf` 改写成 lieutenant forge 的一个 card route，
  而不是把 `onboard project` 复活。
- **lieutenant forge 在本 fork 尚未跑通一张卡到 PR。** 本 change 删掉的是当前唯一被验证过的
  派活路径。缓解：删除全在 git 里，`git revert` 可整体退回；且 `provision forge` 的验收 forge
  已经起过（SKILL.md 的端口表 7782）。
- **`docs/fork-deltas.md` 的 D 表会出现指向已删 verb 的行。** 本 change 一并修订，不留悬空
  引用。

## Migration Plan

1. spec 先行：本 change 的 artifact 单独一个 PR，合进 `main`。
2. 实现：删脚本、删测试、改 `SKILL.md`、改 `ship-project.sh`、改文档，第二个 PR。
3. 归档本 change，关闭 #155 与 #152。

顺序按 `openspec-git-discipline`：OpenSpec 状态变更要在下一阶段依赖它之前先过 `main`。

## Open Questions

无。三种 topology 的取舍已由操作者拍板。
