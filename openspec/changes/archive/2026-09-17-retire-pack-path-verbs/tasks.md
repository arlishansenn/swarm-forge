## 1. spec 先行

- [x] 1.1 本 change 的 artifact（proposal / design / adr / specs / tasks）单独一个 PR
- [x] 1.2 `openspec validate --strict retire-pack-path-verbs` 通过
- [x] 1.3 合进 `main` 之后再开工第 2 节

## 2. 删 verb 与脚本

- [x] 2.1 删 `scripts/onboard-project.sh`、`scripts/test-onboard-project.sh`、
      `scripts/test-onboard-start-stop-e2e.sh`
- [x] 2.2 删 `scripts/update-swarmforge-scripts.sh`、`scripts/test-update-swarmforge-scripts.sh`
- [x] 2.3 删 `scripts/run-issue.sh`、`scripts/test-run-issue.sh`
- [x] 2.4 `grep -rn 'onboard\|update-swarmforge\|run-issue' scripts/` 只剩注释性提及，逐条清掉

## 3. 改 `SKILL.md`

- [x] 3.1 删三段 verb 正文
- [x] 3.2 改 frontmatter 的 `description`：去掉 onboard 与 run issue 的触发语
- [x] 3.3 改「不是每个 verb 都已经有脚本」那段的清单
- [x] 3.4 `ship project` 一段：清掉全部以 `run issue` 为参照系的措辞，规则本身保留
- [x] 3.5 改 Testing 一节，删掉已删套件的段落

## 4. 改 `ship-project.sh`

- [x] 4.1 删 `closes_numbers()` 的卡名 `issue-<N>-<slug>` 分支
- [x] 4.2 删 `test-ship-project.sh` 里只针对该分支的断言，保留卡文本与 `--issue` 的用例
- [x] 4.3 删脚本头部与注释里以 `run issue` 为参照的说明
- [x] 4.4 `bash scripts/test-ship-project.sh` 全绿

## 5. 文档

- [x] 5.1 写 `docs/adr/0007-the-fork-keeps-only-the-lieutenant-forge-path.md`
- [x] 5.2 收窄 ADR-0001 / 0002 的措辞（决定不动，只去掉 Pack 分支那一侧的举例）
- [x] 5.3 `docs/operator-runbook.md` 删三个 verb 的条目
- [x] 5.4 `README.md` 删 `run issue` 那句
- [x] 5.5 `docs/fork-deltas.md` 修订指向已删 verb 的行，不留悬空引用
- [x] 5.6 `scripts/provision-forge.sh` 头部那句「第 5 步是 `run issue` 的地盘」改写

## 6. 回归

- [x] 6.1 `.agents/skills/swarmforge-operator/scripts/` 下剩余每个 `test-*.sh` 全绿
- [x] 6.2 确认 `test-start-swarm.sh` 不依赖被删脚本

## 7. 收尾

- [x] 7.1 归档本 change
- [x] 7.2 关闭 #155 与 #152
