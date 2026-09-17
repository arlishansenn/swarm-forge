## 1. spec 先行

- [x] 1.1 本 change 的 artifact 单独一个 PR
- [x] 1.2 `openspec validate --strict retire-verbs-covered-by-dashboard` 通过
- [x] 1.3 合进 `main` 之后再开工第 2 节

## 2. 退两个 verb

- [x] 2.1 删 `scripts/read-swarm.sh`、`scripts/test-read-swarm.sh`
- [x] 2.2 删 `scripts/stop-swarm.sh`、`scripts/test-stop-swarm.sh`
- [x] 2.3 `grep -rn 'read-swarm\|stop-swarm' scripts/ ../SKILL.md` 逐条清掉

## 3. 合并 accept work 进 ship project

- [x] 3.1 把 `accept-work.sh` 的逻辑折进 `ship-project.sh`，去掉子进程与 awk 文本解析
- [x] 3.2 用例逐条搬过来了，但**落在 `test-ship-project-delivery.sh` 而不是
      `test-ship-project.sh`**：两套需要相反的 harness（真 git vs 桩 git），合成一个
      文件就必须重写其中一套，正是本节禁止的事。偏离理由写在该文件头部。
- [x] 3.3 删 `scripts/accept-work.sh`、`scripts/test-accept-work.sh`
- [x] 3.4 用例数对账：合并后的套件 ≥ 86 + 76
- [x] 3.5 删 lib-wake-talk.sh 的 classify()/classify_pane()/BUSY_RE/IDLE_RE——两个消费者
      都删掉后它们是死代码（pane_lines 留着，input_line_has 还在用）
- [x] 3.6 变异测试：去重、已交付排除、master worktree 唯一性各改坏一次，确认都会红

## 4. `start swarm` 降级

- [x] 4.1 `SKILL.md` 的 verb 列表撤下它，改写成 `provision forge` 的内部步骤
- [x] 4.2 脚本与测试原样保留，头部注释说明它不再是公开 verb
- [x] 4.3 写明：**不要**拿它去启动 forge 管的 project（会多出一个 dashboard）

## 5. 改定位，不动代码

- [x] 5.1 `open swarm`：卖点收窄成「要交互式附着，不是只看」——网页的 pane 是只读 capture
- [x] 5.2 `talk role`：收窄成「跟 project role 说话」——chat rail 只通 Host lieutenant

## 6. 文档

- [x] 6.1 写 `docs/adr/0008-the-dashboard-cannot-reach-itself-or-type.md`
- [x] 6.2 `SKILL.md`：**停 project 的正确动作是 Dashboard 的 close**，写在显眼处
- [x] 6.3 `docs/operator-runbook.md` 删两个 verb 的条目，verb 数改成六
- [x] 6.4 `README.md` 的 verb 数改成六
- [x] 6.5 `docs/fork-deltas.md` 的 D-7 内容列表更新；历史验收记录不动

## 7. 回归

- [x] 7.1 剩余每个 `test-*.sh` 全绿
- [x] 7.2 `test-start-swarm.sh` 仍全绿（脚本没删）

## 8. 收尾

- [ ] 8.1 归档本 change
- [ ] 8.2 关闭 #158
