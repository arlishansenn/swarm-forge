# 0008. Dashboard 有两个盲区：接入与输入，所以那两个 verb 不删

Status: accepted
Date: 2026-09-17

## Context

ADR-0007 把本 fork 定在 lieutenant forge 一条路径上。那条路径的设计是**操作都在 Dashboard
上做**，于是每次架构 review 都会出现同一个提议：**「网页都有了，operator verb 全删吧。」**

这个提议大部分是对的。按 `pack_web` 的实际端点逐个对账之后，十个 verb 里有三个确实被覆盖得
更好，一个不该再是独立 verb（issue #158）：

| verb | 网页里的对应物 |
|---|---|
| `read swarm` | `role_heats` + `work_in_flight` + agent pane 页 |
| `stop swarm` | `POST /api/projects/close`、`/api/teardown` |
| `start swarm` | `POST /api/projects/open` |
| `accept work` | 并入 `ship project`（它只剩一个调用方） |

**但有两个不是。** 它们不是「网页还没做」，是**网页在结构上做不到**。这份 ADR 存在的唯一
目的，是让下一次 review 不必重新把这两条推导一遍。

## Decision

**`dashboard` 与 `wake role` 不随其余 verb 一起退役。**

### 盲区一：接入 —— 网页开不了通往自己的路

`dashboard` 这个 verb 做的不是「显示网页」，是**让网页可达**：ssh local-forward，或
`tailscale serve` 发布，外加端口归属校验与 cmux browser surface 的复用与校验。

`pack_web` 只绑 `127.0.0.1`。在 operator 的机器上，那个端口在被打通之前**不存在**。一个跑在
远端主机上的网页，不可能自己把自己发布出来给还没连上它的人看——这是引导问题，不是功能缺口。

### 盲区二：输入 —— 网页只能看 pane，不能往里打字

**`pack_web_pane.bb` 从头到尾只有 `capture-pane`。** `inject-role!` 确实存在于
`pack_web_notify.bb`，但它只被 notify 内部调用（`new-task`、`allow`、`reverse-cleared`），
**没有任何 HTTP 端点接受任意文本送进某个 project 角色的 pane**。

而 chat rail 通向的是 Host lieutenant，不是 project 角色：`post-chat` →
`notify-lieutenant!` → `inject-role! forge "lieutenant"`。

`wake role` 存在的原因正是网页这个形状救不了的场景：一个角色卡在 TUI 提示上，唤醒键被 TUI
吞掉。看得见，动不了。

## Consequences

- **六个 verb 保留**：`provision forge`、`dashboard`、`open swarm`、`wake role`、
  `talk role`、`ship project`。每一个都落在网页做不到的那一侧：装一个新 forge（那时网页还
  不存在）、接入、附着、往 pane 里打字、推 GitHub。
- **`open swarm` 与 `talk role` 的定位收窄**，不是删：前者的卖点是**能打字的附着终端**，
  网页的 pane 是只读 capture；后者的卖点是**跟 project 角色说话**，chat rail 只通 Host
  lieutenant。
- **`start-swarm.sh` 撤掉 verb 名但留脚本**：起 forge 自己的那一刻 Dashboard 还不存在，
  同一个引导问题。它成为 `provision forge` 的内部步骤。
- **这份 ADR 会过期，而且是可检测的。** 上游哪天给 pane 页加了一个写端点，盲区二就消失，
  `wake role` 该退役。判据写死在这里：`pack_web_pane.bb` 里出现 `send-keys`，或者出现一个
  接受文本并调用 `inject-role!` 的 HTTP 路由。盲区一要消失则需要 `pack_web` 不再只绑
  `127.0.0.1`，那是另一个决定（而且有它自己的安全理由）。

## Supersedes

无。本 ADR 延伸 ADR-0007，不推翻它。
