## Why

本 fork 相对 upstream 的每条有意差异，今天只记在 `docs/fork-deltas.md` 这份散文清单里。
清单挡不住 merge：git 的冲突检测是行级的，upstream 在**全新代码**里重犯一个本 fork 已经
修过的 bug 时，没有文本重叠，merge 干净通过，测试也可能照绿。issue #45 与 #67 各真实发生
过一次——#67 那次 merge 零冲突，`bb test` 却是 103 failures / 82 errors。

清单还有一个更慢的失效方式：它描述差异，但不判定差异是否还在。走一遍清单靠人回忆「这条
应该是什么样」，而人会累。本 fork 已经在 `docs/fork-deltas.md` 里写死了判据——「每条差异
都必须有一条会因为 upstream 的版本而失败的测试」——但那句话本身没有可执行的载体。

OpenSpec 的 intent-driven schema 提供那个载体：behaviour spec 带 Gherkin scenario，加上
跨 change 持久的 ADR。差异从「一段要读的散文」变成「一组要过的 scenario」。

## What Changes

- 安装 `intent-driven` schema 到 `openspec/schemas/`，配 `openspec/config.yaml`，并装它的
  8 个配套 skill 到 `.agents/skills/`。
- `docs/adr/` 移到仓库根的 `adr/`，因为 intent-driven 的 adr artifact 规定 repository-level
  ADR 写在 `<repo>/adr/`（openspec/ 的同级），不在 openspec/ 内部。两份既有 ADR 内容一字未动。
- 把 `docs/fork-deltas.md` 的 B 类差异与两条可判定的 A 类差异，改写成 8 个 capability 的
  behaviour spec。每个 scenario 写成「换成 upstream 的版本就会失败」的形状。
- `docs/fork-deltas.md` **保留**，改为指向 spec 的索引与 merge 操作手册，不再是差异的唯一
  真相源。**BREAKING**（对流程而言）：merge upstream 之后的验收从「走一遍清单」改为「跑一遍
  scenario，再走清单确认没有新差异漏登记」。

## Capabilities

### New Capabilities

- `handoff-inbox-resolution`: handoff 收件箱路径从 `roles.tsv` 的 worktree 列派生，不从进程 cwd（D-1）
- `tmux-submit-keys`: 提交键按 agent backend 分发，claude 用 CSI-u Enter，其余用裸回车（D-2、D-3）
- `handoff-helper-library`: handoff helper 只有一份，集中在 `handoff_lib.bb`（D-4）
- `handoff-daemon-redelivery`: handoffd 对未领取的 handoff 做电平对账与重试，不是一次性投递（D-5）
- `role-worktree-script-mirroring`: script snapshot 到 role worktree copy 是完整镜像，并比对可执行位（D-6）
- `remote-ssh-stdin-isolation`: 所有 remote ssh 调用带 `-n`，不吞调用方的 stdin（D-8）
- `script-snapshot-provenance`: managed project 的 script snapshot 来自本 fork，且安装是原子的、留下 manifest（D-9）
- `dashboard-port-binding`: pack_web 可绑固定端口，不设变量时行为与 upstream 一致（D-10）

D-7（`swarmforge-operator` skill）是本 fork 相对 upstream 最大的一块：upstream 完全没有
operator verb，它的动作是人手敲的 ssh 命令。它的契约此前只以散文写在 `SKILL.md` 里，
下面十个 capability 把它变成可验收的行为：

- `operator-verb-contract`: 每个 scripted verb 的 STATUS 行与那张跨 verb 唯一的退出码表
- `swarm-start-safety`: `--terminal` 必须由人选、已在跑拒绝二次启动、脱离式启动只信 runtime 文件
- `swarm-stop-safety`: 停机前报告会打断什么、没真停下来就不许报 STOPPED、pack_web 不比 swarm 活得久
- `dashboard-access`: 端口归属检查、绝不代为启动、`--tailnet` 不建隧道也不碰 tailscale
- `role-state-reading`: 读不准报 UNKNOWN 绝不报 IDLE、分类跟着真实 pane 形状、读状态绝不写 pane
- `role-message-delivery`: 送进去要确认真的送到、绝不用符号键名提交
- `work-acceptance`: 只报未入库的工作、两次运行不改动任何 inbox 文件、卡住才 WARN
- `issue-to-pr-pipeline`: 四格状态全部有出口、只认 Board lane、等不到不是失败、有人在等回答就停
- `snapshot-install-safety`: 原子安装与整体回滚、脏 source 无 override 拒绝、自管的树不被静默覆盖
- `project-onboarding`: launcher 原样安装绝不解压后改写、从本 fork 的 Pack 分支下载

### Modified Capabilities

无。`openspec/specs/` 此前为空，本 change 是第一批。

## Impact

- 新增 `openspec/`、`adr/`、`.pi/`，以及 `.agents/skills/` 下 19 个新 skill 目录。
- `docs/fork-deltas.md`、`docs/agents/domain.md`、`docs/research/upstream-task-completion-protocol.md`
  里指向 `docs/adr/` 的路径改为 `adr/`。
- 不改任何被测代码：本 change 只记录既有行为，不改变它。既有测试套件必须保持全绿且数量不变。
- D-7（`swarmforge-operator` skill）现已覆盖，见上面十个 capability。它是 A 类，upstream
  merge 从不碰它，所以这些 spec 的用途不是 merge 验收，而是**契约本身有个可验收的载体**：
  `SKILL.md` 说的是同一批事，但散文说不清「换成别的实现会不会失败」。
