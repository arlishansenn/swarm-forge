# Deliverable：verbs-get-their-seam verification

日期：2026-09-18。Schema：intent-driven。实现版本：`c733ca95f466b1fd7f954a553c823b800936fb51`，已进入本地 main，未 push。本报告与 tasks 状态更新尚未提交。

## 结论

实现核验通过，无 CRITICAL；有两项文档状态 WARNING，不影响隔离行为验证。27/27 tasks 已核对，10 条 requirements 均有实现证据，13 个 scenarios 中 12 个以可运行 shell 检查覆盖，1 个迁移期场景按历史记录与人工 review 核对。没有对 SKILL 措辞写自动测试。

| 维度 | 结果 |
|---|---|
| Completeness | 27/27 tasks；10/10 requirements 有证据 |
| Correctness | 六套 contract 新鲜复跑全绿；七套旧回归采用同实现的提交前完整结果 |
| Coherence | 独立 verb seam、两个 adapter、无运行时 spec 依赖，符合已授权设计 |

## Completeness 与 Correctness

以下 scripts 路径相对 `.agents/skills/swarmforge-operator/`；spec 路径相对本 change。

### 入口选择与透传

Requirement：`specs/operator-verb-adapters/spec.md:3`。
六个 `scripts/verb-*` 的 `main`（各文件 4–19 行）使用固定 fake/real 分支，`exec "$adapter" "$@"` 保持参数与输出。共同测试 `scripts/test-support/verb-contract.sh:95–136` 覆盖未知/空选择、adapter 缺失与不可执行、NUL 分隔 argv、stdout/stderr 字节及退出码 23 透传。对应 spec 的三个 scenarios 均覆盖。

### 六个可替换 seam

共同成功断言位于 `scripts/test-support/verb-contract.sh:29–45`，fake、显式 real、默认 real 均调用它（63–84 行）；每个 test-verb 文件只指定 verb、状态、字段及 fixture。不是另写一套较宽松的 real 断言。

- provision：`test-verb-provision-forge.sh` 与 `test-support/provision-fixture.sh:3,90`，真实安装样本、manifest、launcher 调用证据；56/0。
- dashboard：`test-verb-dashboard.sh` 与 `test-support/dashboard-fixture.sh:3,78`，归属和可达性检查后操作 browser 的证据；62/0。
- ship：`test-verb-ship-project.sh` 与 `test-support/ship-fixture.sh:3,70`，本地 bare remote 真 push、gh recorder 收到创建，不用 DRY_RUN 冒充；45/0。
- wake/talk：各自 test-verb，复用 `test-support/wake-fixture.sh:3,71`，输入字节、backend 提交键与未消费负例；各58/0。只修 fixture 分段输出的 SIGPIPE 竞态，未改生产消费逻辑。
- open-swarm：`test-verb-open-swarm.sh` 与 `test-support/open-swarm-fixture.sh:3,99`，三 session 配对、奇数尾部、逐 surface 检查及重复调用复用；74/0。

以上六项分别对应 spec 六条 Seam requirements 及六个成功 scenarios。

### fake 隔离

Requirement：spec:126。六个 `scripts/fakes/*.sh` 只输出固定样本和 stderr 标识，无目标读取或外部调用。共同测试 56–71 行以不存在的 root 和调用即失败的命令环境检查无副作用、固定输出与 fake 标识，覆盖该 scenario。

### 逐 verb 接入

Requirement：spec:140。默认 real 委托 scenario 由共同测试 80–85 行与各 fixture 的操作记录验证。迁移期“real 尚未通过时保留旧入口”属于历史流程与 prompt 约束，依据 tasks、交接记录、RED/GREEN 日志及人工 review 核对；未以自动文本断言验证，也不能从最终单个实现 commit 单独重建每个中间状态。

默认委托历史证据均位于 `/tmp/sf177-<verb>-evidence/`：provision 49/7→56/0，dashboard 55/7→62/0，ship 在授权 stream 修正后39/4→43/0（增强后45/0），wake46/6→52/0（增强后58/0），talk52/6→58/0，open-swarm63/11→74/0。open-swarm setup-error 不算有效 RED；ship 首次流错与默认 fake 失败分开记录。

### 留档不参与执行

Requirement：spec:162。本次重新复制仅 scripts 到临时目录，以临时目录为 cwd 运行六套测试，全部通过（`/tmp/sf177-final-evidence/verify/results.json`）。目录没有 openspec、docs 或 SKILL。运行代码不需要留档；SKILL 自足性由人工 Spec review 另核对，不能拿 shell 测试代替 prompt 审查。

## Coherence

六个 wrapper 保持各自 seam，没有总 dispatcher、registry、Kind 或文档 checker。既有 `.sh` 保持 real adapter；fake 永久保留，报错不回退。共享 fixture 仅用于测试，未 source 旧 runner 或更改原七套回归。attach role 原 SSH 交接与 start-swarm 内部角色保留。

旧生产脚本相对规划前后基线的差异只有 `ship-project.sh:709` 的 `>&2`，与 tasks 阶段5记录的用户授权一致。README/runbook 直接导航 SKILL。独立 review 报告为 `/tmp/sf177-final-spec-resumed.md` 与 `/tmp/sf177-final-standards-resumed.md`，Standards 的唯一 blocker 经定点复核解除。

## Issues by priority

### CRITICAL

无。

### WARNING

1. **已处理：规划中的行为不变表述未注明已授权例外。** proposal 的 What Changes 与完成判据、design 的 Non-Goals、ADR-0009 的 Decision 各补一句，点名 `ship-project.sh` 的 `git push` stdout→stderr 为经用户授权的唯一例外，并指向 tasks 阶段 5。只补说明，不改已合入的决定本身。
2. **待人决定：ADR 状态尚为 proposed。** `docs/adr/0009-operator-verbs-own-adapter-seams.md:3` 与 change 的 `adr.md` 仍记 proposed，虽然规划与实现均已进入本地 main。建议由决策维护者确认是否改为 accepted，并同步 manifest；不代替人批准 ADR。

### SUGGESTION

本轮关键原始日志在 `/tmp`，可能被系统清理。tasks 与本报告已记录数字、来源和实现定位；若要长期保存原始输出，归档前另留存受控证据副本，不将临时日志视为永久存储。

## 验证边界与下一步

本次新执行六套 standalone contract；旧七套回归未重复执行，使用提交前同批全绿证据（`/tmp/sf177-final-evidence/precommit/results.json`）：91、39、57、81、86、87、28 条。已核对实现文件与 c733ca9 无差异，只有本轮文档状态更新。

未执行 Gherkin runner：本仓无 acceptance-tests，Markdown scenarios 是留档。未连接真实 Forge、角色 pane 或 GitHub。Dashboard 不支持 Forge 共享 runtime 的既有限制保留。

实现具备归档条件，但建议先处理两项文档 WARNING，并提交本轮 tasks/report，再决定 archive。未 push、未 archive，也未创建后续 commit。
