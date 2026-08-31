## 1. 安装 schema

- [x] 1.1 复制 `intent-driven` schema 到 `openspec/schemas/`
- [x] 1.2 写 `openspec/config.yaml`，rules 用字符串数组（AGENT_INSTALL 里的 `{}` 形状对
      CLI 1.11.0 无效），语言要求写进 `context`
- [x] 1.3 `openspec schema validate` 输出 `✓ intent-driven`
- [x] 1.4 按 `skills.txt` 装 8 个配套 skill
- [x] 1.5 `openspec init --tools claude,pi,agents`，确认它没有改动仓库自己的
      `CLAUDE.md` / `AGENTS.md` / `README.md`
- [x] 1.6 校验全部 `.agents/skills/*/SKILL.md` 的 frontmatter 可解析

## 2. ADR 归位

- [x] 2.1 `git mv docs/adr adr`
- [x] 2.2 把 `docs/fork-deltas.md`、`docs/agents/domain.md`、
      `docs/research/upstream-task-completion-protocol.md` 里的 `docs/adr/` 改为 `adr/`
- [x] 2.3 新增 `adr/0003-fork-deltas-are-recorded-as-executable-specs.md`

## 3. 写 capability spec

- [x] 3.1 `handoff-inbox-resolution`（D-1）
- [x] 3.2 `tmux-submit-keys`（D-2、D-3）
- [x] 3.3 `handoff-helper-library`（D-4）
- [x] 3.4 `handoff-daemon-redelivery`（D-5）
- [x] 3.5 `role-worktree-script-mirroring`（D-6）
- [x] 3.6 `remote-ssh-stdin-isolation`（D-8）
- [x] 3.7 `script-snapshot-provenance`（D-9）
- [x] 3.8 `dashboard-port-binding`（D-10）

## 4. 验收

- [x] 4.1 `openspec validate record-fork-deltas-as-specs --type change --strict` 通过
- [x] 4.2 `docs/fork-deltas.md` 顶部加索引，每条 B 类差异指向它的 capability
- [x] 4.3 既有测试套件全绿且数量不变（本 change 不改被测代码）：`bb test`、
      `test-sync-worktree-scripts.sh`，以及 operator skill 的 `test-*.sh`
