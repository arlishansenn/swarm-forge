## REMOVED Requirements

### Requirement: 同一张 issue 绝不投第二次

**Reason**: `run issue` 被删除，本 capability 整体失去主体。

### Requirement: 只有 Board 的 lane 判定任务完成

**Reason**: 同上。该判据本身仍然成立，且已由 `ship project` 的门 B 继承——它读
`.swarmforge/board/tasks.tsv` 的 lane，停在角色 lane 的卡阻断发布。

### Requirement: 等不到不是失败

**Reason**: 同上。`run issue` 的 `7` `STILL_RUNNING` 随 verb 一起消失。

### Requirement: 有人在等回答时立刻停

**Reason**: 同上。lieutenant forge 里「有人在等回答」由 Dashboard 的 Attention 呈现，由操作者
处置，不再由某个 verb 轮询拦截。

### Requirement: task body 跟随目标项目是否使用 OpenSpec

**Reason**: 同上。卡文本由切卡的人或 Host lieutenant 写，不再由 verb 拼装。

### Requirement: artifact 顺序不由本 verb 保存

**Reason**: 同上。
