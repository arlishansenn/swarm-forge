## 1. 判据

- [x] 1.1 `BUSY_RE` 增加 participle 紧跟省略号的形状判据（单字符与三点都接受）
- [x] 1.2 `FOOTER_RE` 放宽到两种 footer 变体共有的 `ctrl+o`
- [x] 1.3 确认 braille spinner 字符**没有**被写进判据，原有理由仍然成立

## 2. 测试

- [x] 2.1 `Thinking…` 读作 BUSY
- [x] 2.2 `Responding…` 读作 BUSY
- [x] 2.3 排队 footer 变体下仍能读到 spinner 行
- [x] 2.4 排队 footer 变体下的空闲 role 仍读作 IDLE（防止修过头）
- [x] 2.5 `stop swarm` 对 `Thinking…` 的 role 退 `6` 并点名，close-swarm 未被调用

## 3. 验收

- [x] 3.1 test-read-swarm.sh / test-stop-swarm.sh / test-wake-talk.sh 全绿
- [x] 3.2 共用 lib 的其余套件不受影响
- [x] 3.3 `openspec validate role-state-survives-grok-spinner-wordings --type change --strict`
