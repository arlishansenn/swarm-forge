# fork 拥有它安装的完整 Pack artifact，onboard 不再事后 patch

ADR 0001 定下「script snapshot 跟随本 fork」，实现手段是 `onboard project` 从 upstream
下载 Pack 分支、解压后改写 `$ROOT/swarm` 里的 `ARCHIVE_URL`。这造成 split ownership：
安装的 artifact 由 upstream 拥有，只有其中一行由本 fork 事后覆盖。

两个后果证明这个手段是错的。一是 fork Pack 分支的 Role backend 仍配置成 Codex，与
maintainer 期望的 Grok 默认不符，而 onboard 的 patch 管不到这一层。二是重写文件本身出了
事故（#33）：`mktemp` + `mv` 让 launcher 继承临时文件的 `0600` mode，丢掉 executable
mode，而 `STATUS=ONBOARDED` 照常返回。

决定：**fork 拥有它安装的完整 Pack artifact。** `onboard project` 从
`arlishansenn/swarm-forge` 下载 Pack 分支并**原样安装**，不在解压后改写任何内容。每个 fork
Pack 分支自带最终的 `swarmforge.conf`、Role prompts、local constitution、可执行的 Swarm
launcher，且该 launcher 的 Script snapshot 来源默认就指向 `arlishansenn/swarm-forge` 的
`main`。

ADR 0001 的**决定本身不变**——script snapshot 仍然跟随本 fork。变的只是实现手段：从「事后
patch 一行」变成「分支里本来就是对的」。

代价：本 fork 必须维护自己的 `two-pack`、`four-pack`、`six-pack` 分支，upstream 对 Pack
骨架的更新需要人工同步过来。换来的是安装动作退化成纯解压——不重写文件就不会再有 #33 那类
mode、owner、inode 事故，也不需要为「patch 有没有生效」写验证。

追踪见 issue #38。
