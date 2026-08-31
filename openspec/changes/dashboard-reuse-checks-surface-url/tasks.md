## 1. 校验与导航

- [ ] 1.1 复用路径上读一次该 browser surface 当前指向的 url（`cmux browser --surface <ref> get-url`）
- [ ] 1.2 与本次要开的 URL 不一致时 `goto` 过去
- [ ] 1.3 一致时不产生任何 cmux mutation
- [ ] 1.4 导航后仍不符时不报成功

## 2. 测试

- [ ] 2.1 陈旧 surface（指向另一个地址）→ 跑完之后它指向本次 URL，报 `REUSED`
- [ ] 2.2 报文的 `URL=` 与 surface 实际指向的一致
- [ ] 2.3 已经一致的 surface → 零 cmux mutation（不 goto、不 new-surface、不 new-workspace）
- [ ] 2.4 **去掉校验，2.1–2.2 必须红**
- [ ] 2.5 既有的 `0` / `3` / `4` 用例一条不红，含新建路径与「legacy 缺 surface 时重建」

## 3. 验收

- [ ] 3.1 `test-open-dashboard.sh` 全绿
- [ ] 3.2 共用 `lib-wake-talk.sh` 的其余套件不受影响
- [ ] 3.3 `openspec validate dashboard-reuse-checks-surface-url --type change --strict`
- [ ] 3.4 SKILL.md 与 README 的 `dashboard` 一节同步：复用时会校验并纠正 surface 指向
