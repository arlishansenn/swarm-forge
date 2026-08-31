## 1. 顺序

- [ ] 1.1 把 pid / `--serve` 归属检查整块移到 HTTP 可达性检查之前
- [ ] 1.2 确认 `pack_web.pid` 缺失或其进程已死时退 `3`，报文说明 swarm 没在跑
- [ ] 1.3 确认端口被别的项目占用时仍然 `4` `DRIFT`，且此时不再先留下一条 ssh 隧道

## 2. `--tailnet` 的失败报文

- [ ] 2.1 可达性失败时，先查一次该端口是否已发布在 tailnet 上
- [ ] 2.2 未发布 → 保持今天的报文（目标 URL + `tailscale serve` 命令原文）
- [ ] 2.3 已发布但无人监听 → 报文说明真实原因，且不出现 `tailscale serve` 建议
- [ ] 2.4 判别本身失败（读不到 serve 配置）→ 退回中性报文，列出两种可能，不猜

## 3. 测试

- [ ] 3.1 停机 fixture（pid 缺失）在**不带** `--tailnet` 时退 `3`
- [ ] 3.2 停机 fixture（pid 缺失）在**带** `--tailnet` 时退 `3`
- [ ] 3.3 pid 存在但进程已死，同样两条路径都退 `3`
- [ ] 3.4 端口已发布但无人监听时，报文不含 `tailscale serve`
- [ ] 3.5 端口确实未发布时，报文仍含 `tailscale serve`
- [ ] 3.6 **把两段检查的顺序换回改动前的版本，3.1–3.3 必须红**

## 4. 验收

- [ ] 4.1 `test-open-dashboard.sh` 全绿，既有的 `0` / `3` / `4` 用例一条不红
- [ ] 4.2 共用 `lib-wake-talk.sh` 的其余套件不受影响
- [ ] 4.3 `openspec validate dashboard-reports-stopped-before-reachability --type change --strict`
- [ ] 4.4 SKILL.md 与 README 的 `dashboard` 一节同步：停机报 `3`、`--tailnet` 报文的两种情形
