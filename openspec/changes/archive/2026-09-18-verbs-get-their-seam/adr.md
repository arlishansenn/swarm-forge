# ADR Review Manifest

- Status: completed
- Review date: 2026-09-18

## Review Summary

已完成本 change 的 ADR review。新决定为 Operator verb 拥有可替换执行 seam，既有脚本作为 real adapter。它补充现有决定，不 supersede。

本 manifest 只记录 review 与新文件位置，不把既有 ADR 的存在当成本 change 已完成的证明。新 ADR 初为 proposed，实现与 verify 完成后经用户确认为 accepted（2026-09-18）。

## In-Force ADRs Reviewed

- ADR-0001、ADR-0002：安装来源与完整 artifact；0002 替换 0001 的实施手段，来源约束仍有效。
- ADR-0003、ADR-0004：行为差异留档与 `docs/adr/` 位置；没有引入 spec 的 runtime 消费者。
- ADR-0005、ADR-0006：runbook 位置、安装者写 manifest；本 change 不改变安装职责。
- ADR-0007、ADR-0008：lieutenant Forge 路径与六个 verb；本 change 不恢复其他 verb。

## New Durable ADRs Created

- `docs/adr/0009-operator-verbs-own-adapter-seams.md`：verb seam 与 real/fake adapter、逐个替换及留档不参与执行。
