## 1. 脚本骨架与参数面

- [x] 1.1 新建 `.agents/skills/swarmforge-operator/scripts/provision-forge.sh`，`set -euo pipefail`，
      `. lib-wake-talk.sh`，沿用 `TARGET`/`KEY`/`--local` 的既有默认值与形状。
- [x] 1.2 参数：`--root`（必传）、`--forge project-manager|lieutenant`（必传）、
      `--terminal`（默认 `none`，值集与 `start-swarm.sh` 一致）、`--dashboard-port`（必传，
      只校验是数字）、`--project <name>`、`--pack two-pack|four-pack|six-pack`、
      `--mission <text>`、`--target`、`--key`、`--local`。缺项或非法值一律 `2` `USAGE`，
      第一行 `STATUS=USAGE`。
- [x] 1.3 `--project` 与 `--pack` 互为前提：给了一个没给另一个是 `2` `USAGE`；两个都没给
      就是「停在第 3 步」那条合法路径。
- [x] 1.4 `--root` 含单引号时 `2` `USAGE`（与 `onboard-project.sh` 同一条防线）。

## 2. 安装阶段

- [x] 2.1 已装判据：forge root 同时有 `swarm` 与 `swarmforge/scripts`。成立就跳过安装并打
      一行 `WARN=`，继续往下走。
- [x] 2.2 未装：在目标主机上取本 fork 的 `get-swarm-forge`（`default_repo_url` 已指向
      `arlishansenn`），`chmod +x`，在 `--root` 里跑 `get-swarm-forge <forge>`。失败是
      `5` `ERROR`，并说明目标目录的状态。
- [x] 2.3 来源自证：`handoffd.bb` 必须含 `reconcile-once!`，`handoff_lib.bb` 必须含
      `roles.tsv`。任一不满足就 `5` `ERROR` 并点名来源不对，**在起 forge 之前**。
      在脚本里留一行注释点明这是两个 marker 而非全树等价性证明。
- [x] 2.4 写 `$ROOT/.swarmforge/scripts-manifest`：`DIGEST=` 用 `remote_scripts_digest`
      算 `$ROOT/swarmforge/scripts`，另两行写 `SOURCE_REPO=<repo_url>#<forge>` 与
      `SOURCE_COMMIT=unknown`。安装失败绝不写。
- [x] 2.5 已装但 manifest 缺失（上一次跑到一半被中断）时补写，不重装。

## 3. 启动阶段

- [x] 3.1 已起判据：`.swarmforge/tmux-socket` 上 `list-sessions` 有应答。成立就跳过启动并
      打 `WARN=`。
- [x] 3.2 未起：调 `start-swarm.sh --root "$ROOT" --terminal "$TERMINAL"
      --dashboard-port "$PORT"` 并透传 `--target`/`--key`/`--local`。**不传 `--force`。**
      非零退出就原样把它的 STATUS 与退出码往上抛。
- [x] 3.3 确认 manifest 写在启动之前，否则 `start-swarm.sh` 会先看到 INCOMPLETE。

## 4. 建 project 阶段

- [x] 4.1 没给 `--project` 就在这里成功退出 `0`，报出 `ROOT=`、`FORGE=`、`URL=`。
      实现时调了顺序：报 `URL=` 就要先有 4.2 的 readiness，所以 readiness 无条件先跑，
      再分叉到这里。行为不变。
- [x] 4.2 dashboard readiness：等 `.swarmforge/dashboard-url` 出现并且那个端口握手成功，
      预算 20 次 × 0.5s（照抄 `open-dashboard.sh`，用同名的可覆盖变量供测试缩短）。
      超时是 `5` `ERROR`，并点名 forge 已起、project 未建。
- [x] 4.3 `projects/<name>` 已存在就 `6` `UNSAFE`，零改动，提示改名或从 dashboard 打开。
- [x] 4.4 在目标主机上 `curl` `127.0.0.1:<port>/api/projects`，body 为
      `{name, pack, mission?}`。不建隧道、不写 `tailscale serve`、不改 `pack_web` 绑什么。
- [x] 4.5 HTTP 非 2xx 时分流：`409` → `6` `UNSAFE`；其余 → `5` `ERROR` 并原样带上服务端
      那句话。**计划时写的「按 body 里的 `error` 分流（`exists` / `already-open`）」是错的**：
      `pack_web.bb` 的 `http-error` 只序列化 `{:error <message>}`，`forge.bb` 放在 ex-data 里的
      `:error` keyword 到不了线上。`409` 是这个端点唯一的冲突状态，同时覆盖两种冲突。
- [x] 4.6 成功：`STATUS=FORGED`，退出 `0`，打印 `ROOT=`、`FORGE=`、`URL=`、`PROJECT=`、
      `PROJECT_PATH=`。

## 5. 测试

- [x] 5.1 新建 `scripts/test-provision-forge.sh`（`#!/usr/bin/env bash`，与既有 `test-*.sh`
      同一套 `ok`/`fail` 形状）。
- [x] 5.2 argv 与 USAGE：缺 `--root`、缺 `--forge`、非法 `--forge`、非法 `--terminal`、
      非数字 `--dashboard-port`、`--project` 无 `--pack`、`--root` 含单引号。
- [x] 5.3 来源自证：造一棵缺 `reconcile-once!` 的假 snapshot，断言在**调用 launcher 之前**
      失败（用 stub launcher 记录是否被调用过）。
- [x] 5.4 manifest：装完之后 `DIGEST=` 等于 `scripts_digest` 的输出；安装失败时 manifest
      不存在；已装但缺 manifest 时补写而不重装。
- [x] 5.5 可续跑：已装未起 → 跳过安装继续启动；已起 → 跳过启动继续建 project；
      `projects/<name>` 已存在 → `6` `UNSAFE` 且零改动。
- [x] 5.6 dashboard readiness 超时 → `5` `ERROR` 且没有发出任何 POST。
- [x] 5.7 跑一次 `bash test-provision-forge.sh > /tmp/t.out 2>&1; tail -1 /tmp/t.out`，
      **输出重定向到文件，不要用 `$(...)` 捕获，不要放进 `for` 循环**。
- [x] 5.8 回归：单独跑 `test-start-swarm.sh` 与 `test-onboard-start-stop-e2e.sh`，确认
      manifest 相关断言仍然全绿（本 change 不改 `start-swarm.sh`，但改了 manifest 的
      writer 集合）。
- [x] 5.9 跑一次 `bb test`，与 `main` 的基线 265 tests / 1173 assertions / 0 failures 对齐
      （非零退出码来自未安装的 Playwright dashboard 套件，不是失败）。

## 6. 真机验收

- [x] 6.1 在 macmini（`admin@100.64.0.4`）一个全新目录里跑一次完整 provision：
      `--forge project-manager --dashboard-port 7782 --project <name> --pack two-pack`。
      **不要碰 `~/project/podsum`，它正在跑并占着 `7780`。**
- [x] 6.2 验收：`STATUS=FORGED`、退出 `0`、`projects/<name>` 存在、该 project 被记为 open、
      dashboard 在 `7782` 上应答。
- [x] 6.3 再跑一次同一条命令，断言它跳过装与起、在 project 重名处 `6` `UNSAFE` 且零改动。
- [x] 6.4 停掉那个 forge 后不带 `--force` 跑一次 `start-swarm.sh`，断言它判为 MANAGED、
      digest 通过、正常启动——这是 ADR-0006 的核心验收。
- [x] 6.5 验收用 `project-manager` 而不是 `lieutenant`：`lieutenant` 的 fork 差异刚移植完、
      还没在真 forge 上跑过，拿它当对象会把两种失败混在一起。

## 7. 文档与收尾

- [x] 7.1 `SKILL.md` 新增 `## Verb: provision forge` 一节：契约、退出码、与
      `onboard project` 的边界、为什么 `--terminal` 默认 `none`。
- [x] 7.2 `SKILL.md` 的 Dashboard 端口表加一行（新 forge 占 `7782`），并更新
      「不是每个 verb 都已经有脚本」那段的 verb 计数。
- [x] 7.3 `CONTEXT.md` 补三个词条：`Forge`、`Project slot`、`Host lieutenant`。
- [x] 7.4 `docs/fork-deltas.md`：D-7 的表加 `provision forge` → `forge-provisioning` 一行，
      并在 `snapshot-install-safety` 一格注明 manifest 现在有第二个 writer。
- [x] 7.5 开一张 issue 记「forge 的 snapshot 怎么更新」（`update SwarmForge scripts` 不认
      forge）—— issue #146。验收时另外摸到一条，开成 issue #147：`stop swarm` 停不了 forge，
      因为 forge root 不是 git repo，DIRTY preflight 恒定触发。
- [x] 7.6 `openspec validate add-provision-forge-verb --type change --strict` 通过。
- [x] 7.7 commit 拆分：spec/ADR/文档一组，脚本与测试一组（动过 `openspec/` 内 spec 的工作
      要 spec 与 code 分 commit）。
