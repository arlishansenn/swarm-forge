## REMOVED Requirements

### Requirement: 安装是原子的，失败整体回滚

**Reason**: 主体是 `update SwarmForge scripts`（requirement 正文的 `Feature:` 行写明），
该 verb 被删除。forge 路径上的原子性由 `script-snapshot-provenance` 的
「安装是原子的，并留下 manifest」继续承载。

### Requirement: source checkout 脏就拒绝，且无 override

**Reason**: 约束的是 `update SwarmForge scripts` 从本仓 source checkout 取树这一动作，
该 verb 被删除。`provision forge` 不从 source checkout 取树，它调 `get-swarm-forge` 下载
已发布的 artifact。

### Requirement: managed project 自己版本控制的树不被静默覆盖

**Reason**: 这是 `update SwarmForge scripts` 的 `8` `OWNED` 闸门，守的是该 verb 自己的写入。
verb 删除后没有任何 operator verb 会写 managed project 的 `swarmforge/scripts/`，闸门失去
守护对象。

**注意**：本 capability 的另外两条 requirement **不删** ——「自管 snapshot 的项目不做 drift
判定」的主体是 `start swarm`，「装 script snapshot 的 verb 负责写描述它的 manifest」是
ADR-0006，约束 `provision forge`。两个 verb 都保留。
