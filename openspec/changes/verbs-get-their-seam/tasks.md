## 1. 计划先进入 main

- [x] 1.1 Review 本 change 与 ADR-0009；把已确认范围与假设同步到 #177，保留注释/usage 文案例外，不擅自接受此前 audit 提出的收紧项。
- [x] 1.2 运行 `openspec validate verbs-get-their-seam --type change --strict`；记录本仓没有 acceptance-tests runner，不能把 Markdown scenario 称为已执行测试。
- [x] 1.3 经用户授权提交 proposal artifacts 并合入 main，核对准确版本后才 apply。

## 2. 六个 verb 的 fake 骨架

- [x] 2.1 保存基线生产脚本及七套测试的路径与 git 内容标识，运行原七套回归并记录真实结果；不触碰用户原有未跟踪文件。
- [x] 2.2 先写六份 `test-verb-<name>.sh` 的共同成功 contract assertions，入口尚不存在时运行并保存 RED；测试不得读取 spec 或匹配 SKILL 措辞。
- [x] 2.3 新增六个 `scripts/verb-<name>` wrapper（`main` 入口）和六个 `scripts/fakes/<name>.sh`，SF_ADAPTER 选择 fake/real，默认 fake；固定 fake 不读真实状态，stderr 明示 ADAPTER=fake。
- [x] 2.4 运行六份 fake 测试取得 GREEN，报告实际 assertion 数及 real=pending；同时验证未知选择、adapter 缺失不回退、参数边界与输出/退出码透传。
- [x] 2.5 六个 fake 在不存在的 root 与外部命令调用即失败的环境中通过，确认无目标文件及外部操作；骨架尚不替换旧 SKILL 生产入口。

## 3. provision forge

- [x] 3.1 从既有 provision 测试复用最小隔离 setup，固定无 project 成功样本，旧脚本实际运行且不访问真实 Forge。
- [x] 3.2 同一份 contract assertions 分别跑 fake 与 real；real 初次已绿如实记录，不制造 RED。另加默认委托检查，在默认 fake 时取得 RED。
- [x] 3.3 切该 wrapper 默认 real，取得默认委托 GREEN；逐步改写 SKILL 的 provision forge 小节为 seam 调用并保留完整操作约束；运行相关旧回归。

## 4. dashboard

- [x] 4.1 配好隔离 runtime、端口与 cmux fixture，原 open-dashboard.sh 实际运行；fake/real 使用同一组 OPENED 与结果字段 assertions。
- [x] 4.2 默认委托检查 RED → 默认改 real → GREEN；更新 SKILL 对应小节，运行原 dashboard 回归，保留端口归属与 surface 校验。

## 5. ship project

- [x] 5.1 准备临时 git remote、终端 handoff、正文及 gh stub，让原 ship-project.sh 真正到达 PR_OPENED 路径；不使用真实 GitHub，不以 DRY_RUN 代替该路径。
- [x] 5.2 同一组 PR_OPENED/退出码/url assertions 跑 fake 与 real；默认委托检查 RED → 默认改 real → GREEN，证明 gh stub 收到创建调用。
- [x] 5.3 更新 SKILL 对应小节，保留两趟发布、--issue、Managed project gate 与祖先检查说明；运行原 ship-project 及 delivery 两套回归。

阶段 5 的范围变更（2026-09-18，用户已授权，已记入 #177）：`git push -u` 的跟踪分支提示先写 stdout，违反共同 contract 的 STATUS 首行断言。修复仅一行：把该次 push 的 stdout 重定向到 stderr，退出码、诊断与失败处理不变。证据：`red-default.log`（PASS=38 FAIL=5）→ `red-default-after-stream-fix.log`（首行断言转绿，PASS=39 FAIL=4，剩下四条是默认仍 fake）→ `green-default.log`（默认切 real 后 PASS=43 FAIL=0）→ `green-final.log`（补 stderr 诊断断言后 PASS=45 FAIL=0）。

## 6. wake role

- [x] 6.1 用隔离 runtime/tmux fixture 执行原 wake-role.sh；同一组 WOKEN/退出码/ROLE/SESSION assertions 跑 fake 与 real。
- [x] 6.2 默认委托检查 RED → 默认改 real → GREEN；更新 SKILL 小节，运行原 wake-talk 回归；核对不含 transcript 的排队 footer 场景，记录发现但不借本票改生产行为。

阶段 6 的证据（2026-09-18）：`red-default.log`（PASS=46 FAIL=6 —— 显式 `SF_ADAPTER=real` 全绿，默认仍 fake 时六条真实操作断言变红）→ `green-default.log`（PASS=52 FAIL=0 real=tested）。fixture 的 tmux 桩画的是 Grok 排队 footer（`ctrl+o · 1 queued · /queue`，不含 `transcript`）加保留历史的重绘，`FOOTER_RE='ctrl[+]o'` 在该形状下仍把它识别为 chrome，未借本票改生产行为。原 `test-wake-talk.sh` 回归 PASS=28 FAIL=0。

## 7. talk role

- [x] 7.1 复用必要的 wake/talk fixture，原 talk-role.sh 实际运行；同一组 SENT/退出码/ROLE/SESSION assertions 跑 fake 与 real，保留空格文本的参数边界验证。
- [x] 7.2 默认委托检查 RED → 默认改 real → GREEN；更新 SKILL 小节，运行原 wake-talk 回归，保留输入已消费验证。

阶段 7 证据：`/tmp/sf177-talk-evidence/red-default.log` 为 PASS=52 FAIL=6，显式 real 全绿、默认 fake 的委托检查失败；切换后 `green-default.log` 为 PASS=58 FAIL=0。复用 wake fixture，验证含空格、引号与 shell 特殊字符的消息字节及未消费负例，未改旧 adapter。

## 8. open swarm

- [x] 8.1 准备 session 配对、cmux 与 tmux fixture，执行原 open-swarm.sh；同一组 OPENED/退出码/附着字段 assertions 跑 fake 与 real。
- [x] 8.2 默认委托检查 RED → 默认改 real → GREEN；更新 SKILL 小节，运行原 open-swarm 回归，保留 workspace 复用与附着验证。

阶段 8 证据：`/tmp/sf177-open-swarm-evidence/red-default.log` 为 PASS=63 FAIL=11，显式 real 全绿，默认 fake 委托失败；`green-default.log` 为 PASS=74 FAIL=0。覆盖三 session 配对、奇数尾部、逐 surface 验证与复用。此前 `setup-error.log` 是 fixture 的 TMPDIR 双斜杠与 Python 路径归一化不一致，不计为有效 RED。

## 9. skill 2.0 与最终验收

- [x] 9.1 人工审阅重写后的六个 verb：各有用途、输入、前置条件、seam 调用、结果与失败处置；attach role 原路径不迁移，必要安全规则不能因删沿革而丢失。
- [x] 9.2 README 与 runbook 的重复 verb 契约表改为 SKILL 指向；执行指令不依赖 issue/spec/ADR 阅读，不恢复 Kind 或文档 checker。
- [x] 9.3 将 skill 执行文件与测试 fixture 放进不含 openspec/docs 的临时目录，运行六对 fake/real contract 测试，确认留档不是执行依赖。
- [x] 9.4 跑原七套回归（open-dashboard、open-swarm、provision-forge、ship-project-delivery、ship-project、start-swarm、wake-talk）；核对旧生产文件 diff，任何注释/usage 文案例外逐项人工确认。
- [ ] 9.5 汇总每个 verb 的 RED/GREEN、real 调用证据、fake/real 成功 contract 与旧回归结果；未接入项不得报完成。Review 后实现合入 main，再另行 verify/archive。

阶段 9 证据（2026-09-18）：仅复制 scripts 到不含 openspec/docs 的临时目录，六套共同 contract 分别为 provision 56、dashboard 62、ship 45、wake 58、talk 58、open-swarm 74 条，全绿。七套旧回归分别为 open-dashboard 91、open-swarm 39、provision 57、ship-delivery 81、ship 86、start 87、wake-talk 28 条，全绿；分批日志汇总在 `/tmp/sf177-final-evidence/regression-summary.md`。旧生产文件仅 ship 的获授权重定向一行，旧七套测试未改。Spec 独立审查无 blocker，报告 `/tmp/sf177-final-spec-resumed.md`。

Standards 审查发现新增 wake/talk fixture 的分段 capture 输出会触发 SIGPIPE，已在 fixture 中合并为一次小输出，未改生产代码或吞掉错误。父复现旧版 1000 次中 1 次退出 141，修后 1000 次全绿；wake/talk 各重复 10 次均 58/0，并重新通过独立目录测试。证据 `/tmp/sf177-sigpipe-evidence/`。Standards 定点复核已确认阻断解除，独立复跑管道 100/100 通过，报告 `/tmp/sf177-final-standards-resumed.md`。两轴审查现无残留 blocker。9.5 保持未勾选：提交/合入尚未完成，不把工作区实现视为已发布。
