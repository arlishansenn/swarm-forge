## REMOVED Requirements

### Requirement: 读不准就报 UNKNOWN，绝不报 IDLE

**Reason**: `read swarm` 被删除，本 capability 整体失去主体。Dashboard 的 `role_heats` 与
`work_in_flight` 是活的角色状态来源，pane capture 页给原始证据。

### Requirement: 分类必须跟着真实 pane 形状走

**Reason**: 同上。`lib-wake-talk.sh` 的 `classify()`/`classify_pane()` 与 `BUSY_RE`/`IDLE_RE`
在两个消费者（`read swarm`、`stop swarm`）都删除后成为死代码，一并移除。

### Requirement: 读状态绝不写 pane

**Reason**: 同上。这条 report-verb 边界由 `ship project` 继续承载——它同样只读
`inbox/`，从不修改。

### Requirement: spinner 判据按形状，不按文案

**Reason**: 同上。这条判据服务的是 `classify()`，随它一起移除。

### Requirement: footer 判据只认它稳定的那部分

**Reason**: 同上。
