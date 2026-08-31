## 1. 脚本

- [x] 1.1 在 `run-issue.sh` 里读 `$ROOT/openspec/config.yaml`，取 `schema:` 的值
- [x] 1.2 值非空时把一段 OpenSpec 说明追加进 `TASK_TEXT`；基础文本一字不动
- [x] 1.3 确认脚本里不出现任何硬编码的 schema 名与 artifact 顺序

## 2. 测试

- [x] 2.1 目标项目声明 `schema: foo-bar` → payload 含 `foo-bar`
- [x] 2.2 目标项目无 `openspec/config.yaml` → payload 不含该名字，且既有的两条 body
      事实（指向 issue、chain 从 roles.tsv 派生）仍然成立
- [x] 2.3 换一个项目声明 `schema: other-schema` → payload 含新名字、不含旧名字，
      证明值是读出来的而不是常量
- [x] 2.4 脚本非注释行里搜不到 artifact 顺序
- [x] 2.5 不新增任何针对 task body 措辞的断言（AGENTS.md 禁止）

## 3. 验收

- [x] 3.1 `scripts/test-run-issue.sh` 全绿
- [x] 3.2 `openspec validate run-issue-follows-target-openspec --type change --strict`
- [x] 3.3 其余既有套件不受影响
