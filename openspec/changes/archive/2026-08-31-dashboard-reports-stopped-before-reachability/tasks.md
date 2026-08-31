## 1. 接上共用的 liveness gate

- [x] 1.1 `open-dashboard.sh` source `lib-wake-talk.sh`，改用 `read_file` 读 runtime 文件
- [x] 1.2 在一切检查之前加 gate：读 `tmux-socket` 并 `tmux_remote list-sessions` 探活
- [x] 1.3 socket 缺失或其后没有 server → 退 `3`，报文说明 swarm 没在跑
- [x] 1.4 gate 未通过时 MUST NOT 建隧道、MUST NOT 打 tailnet 地址、MUST NOT 调 cmux

## 2. 归属检查前移

- [x] 2.1 把 pid / `--serve` 归属检查整块移到 HTTP 可达性检查之前
- [x] 2.2 确认 `pack_web.pid` 缺失或其进程已死时退 `3`
- [x] 2.3 确认端口被别的项目占用时仍然 `4` `DRIFT`，且此时不再先留下一条 ssh 隧道
- [x] 2.4 `--tailnet` 的「端口未发布」报文**不动**——顺序修好后它只在 swarm 在跑时可能出现

## 3. 测试

- [x] 3.1 socket 失活（文件在、无 server）→ 两条路径都退 `3`，零 cmux 调用
- [x] 3.2 停机 fixture（pid 缺失）在不带 `--tailnet` 时退 `3`
- [x] 3.3 停机 fixture（pid 缺失）在带 `--tailnet` 时退 `3`
- [x] 3.4 pid 存在但进程已死，两条路径都退 `3`
- [x] 3.5 **去掉 gate 与还原顺序，3.1–3.4 必须红**
- [x] 3.6 既有的 `0` / `3` / `4` 用例一条不红，含「ran no tailscale command」两条

## 4. 验收

- [x] 4.1 `test-open-dashboard.sh` 全绿
- [x] 4.2 共用 `lib-wake-talk.sh` 的其余套件不受影响
- [x] 4.3 `openspec validate dashboard-reports-stopped-before-reachability --type change --strict`
- [x] 4.4 SKILL.md 与 README 的 `dashboard` 一节同步：新增的 gate、停机报 `3`、以及
      「swarm 停了但 pack_web 独活会被拒」这一有意取舍
