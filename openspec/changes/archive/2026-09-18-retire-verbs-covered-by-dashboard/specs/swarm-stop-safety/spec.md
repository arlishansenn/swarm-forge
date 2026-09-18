## REMOVED Requirements

### Requirement: 停机前先报告会打断什么

**Reason**: `stop swarm` 被删除。停一个 project 改走 Dashboard 的 close
（`POST /api/projects/close`），停整个 forge 走 `/api/teardown`。

### Requirement: 没有真的停下来就不能报 STOPPED

**Reason**: 同上。`close-project!` 的 `mark-closed!` 是 forge 自己的记录，
比这个 verb 的事后探活更权威——**而 `stop swarm` 恰恰碰不到它**，这正是它必须退役而不是
保留的原因：它杀掉 session 之后 forge 仍然认为 project 开着，漂移是静默的。

### Requirement: pack_web 不会比 swarm 活得更久

**Reason**: 同上。lieutenant forge 的 `pack_web` 属于 forge 而不是任何一个 project
（`run-project!` 不起 `pack_web`），它的生命周期由 `/api/teardown` 管。
