# Managed project 的 script snapshot 跟随本 fork，不跟随 upstream

一个 managed project 的 `swarm launcher` 首跑时下载 script snapshot，而 upstream 的
pack 分支把下载地址硬编码成 `unclebob/swarm-forge` 的 `main`。本 fork 的
`handoffd.bb` 修复（未领取 handoff 的电平对账、唤醒失败不隔离、cap 耗尽告警、收件箱按
`roles.tsv` 解析 worktree）都在本 fork 的 `main` 上，不在 upstream，所以照 upstream
流程 onboard 出来的项目会静默拿到一份 handoff 会卡死的 snapshot。

决定：`onboard project` 在装完 pack 之后改写目标项目 `swarm` 里的 `ARCHIVE_URL` 默认值，
指向 `arlishansenn/swarm-forge`。

代价：upstream 对 `swarmforge/scripts/` 的更新不再自动到达 managed project，需要人主动
把改动同步进本 fork 的 `main`。这在事实上已经发生（podsum 的 snapshot 是被手动同步的），
本决定只是把它变成明写的默认值。备选方案是每次 onboard 输出一条警告让人自己处理，但那条
警告恒定为真，恒定为真的警告会被无视，等于没有。
