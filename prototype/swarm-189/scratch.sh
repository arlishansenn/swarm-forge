#!/usr/bin/env bash
# PROTOTYPE, wipe me. 建一个一次性 git repo + 两棵长期 worktree，给 swarm.mjs 用。
#
# 放在 $HOME 下而不是 /tmp，因为 ~/.pi/agent/trust.json 只信任 /Users/admin 子树，
# /tmp 下的 cwd 会触发 project trust 提示。
set -euo pipefail

ROOT="${1:-${SWARM189_ROOT:-$HOME/.swarm-189-scratch}}"
rm -rf "$ROOT"
mkdir -p "$ROOT/repo"
cd "$ROOT/repo"

git init -q -b main
git config user.name  "swarm-189"
git config user.email "swarm-189@example.invalid"

cat > notes.md <<'MD'
# scratch

一行都别当真，这是原型用的一次性仓库。
MD
git add -A
git commit -q -m "chore: scratch seed"

# 两棵长期 worktree，各自一条分支 —— handoff 的载荷就是分支上的一个 commit
git worktree add -q -b coder   "$ROOT/worktrees/coder"   main
git worktree add -q -b cleaner "$ROOT/worktrees/cleaner" main

# role prompt 通过每棵 worktree 里的 AGENTS.md 落地。
# 故意不提交：两条分支要互相 merge，提交了会平白造出一个 AGENTS.md 冲突。
# 光「不 git add」不够 —— role 自己会跑 `git add -A`，第一次跑就被它顺手提交了。
# info/exclude 是 common dir 里的，两棵 worktree 共用这一份。
echo "AGENTS.md" >> "$ROOT/repo/.git/info/exclude"
# #182 查实 system prompt 是每次 createAgentSession 按当前磁盘内容重新生成的，
# 所以这就是新仓库里 role prompt 的真实落点。

cat > "$ROOT/worktrees/coder/AGENTS.md" <<'MD'
# 你是 coder

你在自己的 git worktree 里干活，分支叫 `coder`。别去动别人的树。

协议（来自 swarm-forge 宪法，这几条是协议不是 harness 适配）：

- 收到一张卡就干活。改完 `git add -A && git commit -m "..."`，**必须提交**，
  handoff 的载荷就是那个 commit。
- 干完**无条件**调 `handoff`，把 commit 交给 `cleaner`，哪怕改动很小、哪怕只是格式化。
  `to` 填 `cleaner`，`task` 原样保留你收到的任务名。
- `handoff` 交出去之后会挂着，直到下一张卡到来才返回。这是正常的，不要重复调用。
- 遇到歧义或者你拿不准的事，调 `ask_operator` 问人，**不要自己拍板**。
MD

cat > "$ROOT/worktrees/cleaner/AGENTS.md" <<'MD'
# 你是 cleaner

你在自己的 git worktree 里干活，分支叫 `cleaner`。别去动别人的树。

协议（来自 swarm-forge 宪法，这几条是协议不是 harness 适配）：

- 收到一次 handoff 时，**先合并**：`git merge <commit>`。
  **合并冲突由你自己解**，不要退回去、不要发明别的合并办法。解完提交。
- 合并之后按卡上说的继续干，改完 `git add -A && git commit`。
- 你是这条链路的末端（non-forwarding）：**不要再往下转发**。干完调 `handoff`
  但**不要填 `to`**，那表示「这一轮结束，等下一张卡」。
- 遇到歧义或者你拿不准的事，调 `ask_operator` 问人，**不要自己拍板**。
MD

echo "scratch ready:"
echo "  repo     $ROOT/repo"
echo "  coder    $ROOT/worktrees/coder"
echo "  cleaner  $ROOT/worktrees/cleaner"
