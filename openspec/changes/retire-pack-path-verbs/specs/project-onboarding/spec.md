## REMOVED Requirements

### Requirement: launcher 原样安装，绝不解压后改写

**Reason**: `onboard project` 被删除，本 capability 整体失去主体。决定本身（安装是纯解压、
不事后 patch）不随之失效——它由 ADR-0002 承载，并继续约束 `provision forge` 走的
`get-swarm-forge` 路径。

### Requirement: 从本 fork 的 Pack 分支下载

**Reason**: 同上。「来源必须是本 fork」这条决定由 `script-snapshot-provenance` 的
「script snapshot 来自本 fork」继续承载，只是到达方式从 Pack 分支收窄为 `get-swarm-forge`。
