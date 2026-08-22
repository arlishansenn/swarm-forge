# Research: 单机 background daemon 的 operator alerting 业界实践（SwarmForge retry-cap 场景）

---
**一句话**：业界对「单机 daemon 在 retry cap 耗尽时叫人」的最小共识是两条线叠加：进程内直接 push 一个跨机器通道（ntfy.sh 一个 `curl` 即可达手机），加一个 dead man's switch（healthchecks.io heartbeat）兜底「进程静默死亡」；Prometheus/Alertmanager、log-watcher、apprise 对单 daemon 单告警点都是过度工程，osascript/terminal-notifier 只覆盖 operator 就在这台机器前的场景，与需求相反。

---

## Summary

SwarmForge 的 reconcile-cap alert 属于 **progress alert**（进程活着但不推进），不是 liveness alert（进程死了）。这两类业界分开处理：progress alert 由应用自己在判定点直接推送（ntfy.sh / SMTP / webhook，成本约 5 行 Babashka）；liveness 由外部监督者兜底（healthchecks.io dead man's switch，或 monit/launchd）。监督框架（launchd/supervisord/monit）只能检测进程死亡和挂起症状，检测不到「agent handoff 无人认领」这类应用语义，所以 cap 耗尽的通知必须来自 daemon 自己，监督者只做兜底。

## Findings

以下每条含：practice、artifact、解决的问题、对「个人 mac mini 上的单个 Babashka daemon」的采用成本（**LOW** = 现在就值得做；**MEDIUM** = 多一个常驻小进程或账号；**HIGH** = 新增长期运行基础设施）。

**1 → Dead man's switch / heartbeat（healthchecks.io）— 成本 LOW（hosted），HIGH（self-host）**
daemon 周期性 ping 一个 URL，服务在 grace period 内没等到 ping 就把你配置的通道（email/webhook/SMS/Slack/PagerDuty）全部叫醒，状态机 New→Up→Late→Down，ping URL 支持 `/fail` 后缀主动上报失败。它解决的问题是 **静默死亡**：daemon 崩了以后没人替你喊，这正是「进程内 alert」的结构性盲区（进程死了就发不出 alert）。托管服务零部署、单 check 一个 `curl` 即集成；开源版（BSD-3，Django+DB+SMTP 三个后台进程）只为单机自托管不值得。curl 即 SDK，Babashka 无任何依赖。Artifacts: [healthchecks.io docs](https://healthchecks.io/docs/)（ping URL、grace、状态机、integrations 均出自此页）；[github.com/healthchecks/healthchecks](https://github.com/healthchecks/healthchecks)（self-host 栈）。

**2 → Prometheus + Alertmanager — 成本 HIGH，本场景判定为 overkill**
pull 模型：官方 overview 明确 "time series collection happens via a pull model over HTTP"，即 daemon 要先暴露 metrics endpoint，再由 Prometheus server scrape，告警规则在 Prometheus 里触发后发给独立部署的 Alertmanager 做分组/去重/路由（email、on-call、chat）。解决的问题是多服务的指标聚合、silencing、inhibition 与路由策略。对单个 daemon 意味着：改 daemon 暴露 `/metrics` + 常驻跑两个 Go 服务 + 维护两份配置。它解决的是 fleet 问题，你只有一个进程、一个告警条件。Artifacts: [Alertmanager overview](https://prometheus.io/docs/alerting/latest/overview/)；[Prometheus overview](https://prometheus.io/docs/introduction/overview/)（pull model 原文）。

**3 → Log-based alerting（fail2ban 的 filter/action 模式、swatch 系）— 成本 MEDIUM**
模式是「不改应用代码，另起一个 watcher 进程 tail 日志文件，正则匹配命中就执行动作」；fail2ban 的仓库结构就是这个模式的教学样本：`config/filter.d/`（匹配哪些行）与 `config/action.d/`（命中后干什么，含 mail 动作）严格分离，README 原文 "easily configured to read any log file of your choosing, for any error you wish"。解决的问题：给**已经存在且不可改**的日志加告警。SwarmForge 的情形相反——告警点是你自己代码里的一个 `if`，从那里直接 curl 通知通道比「写日志 + 起第二个常驻 watcher」少一个进程、少一层间接。另外 journald 在 macOS 不存在。Artifact: [github.com/fail2ban/fail2ban](https://github.com/fail2ban/fail2ban)。

**4 → apprise（多通道扇出库）— 成本 MEDIUM，通道数 ≥3 才值得**
README 自述 "One notification library to rule them all"：一份 URL 列表同时扇出到 Telegram/Discord/Slack/Gotify/SNS/邮件等上百种服务，自带 CLI（`apprise -t title -b body <urls>`），可作独立子进程调用，不污染 Babashka 运行时。解决的问题是**通道多样性**：一处配置、全家桶送达。代价是拖进 Python 工具链（pip 安装）。你只有一两个通道（Hermes CLI、SMTP、也许加个 ntfy）时，一个裸 `curl` 比引入 apprise 更小；将来要同时推 5 个渠道时再换。Artifact: [github.com/caronc/apprise](https://github.com/caronc/apprise)。

**5 → 「CLI 发通知」原语对比 — 关键判据是 operator 在哪**
SwarmForge 的 operator 在另一台机器上 SSH 过来，这直接筛掉本地通知原语：

- **osascript**（`osascript -e 'display notification ...'`，macOS 内建，零依赖）：投递到**本机** Notification Center，operator 不在 mac mini 的 GUI session 前就永远看不到。零成本但零送达，不解决本场景（此为平台常识，未做 web 验证）。
- **terminal-notifier**（[github.com/julienXX/terminal-notifier](https://github.com/julienXX/terminal-notifier)，`brew install`，macOS 10.10+）：同样只进本机 Notification Center，README 明示 2.0.0 起 action buttons/sticky 已移除（要交互得换 alerter）。与 osascript 同一问题域：operator-at-machine only。
- **ntfy.sh**（[docs.ntfy.sh](https://docs.ntfy.sh/)）— **本场景最佳匹配**，成本 LOW：发送端就是 `curl -d "cap exhausted: handoff X" ntfy.sh/<topic>`，topic 不需注册，手机装 iOS/Android app 订阅同一 topic 即收 push，官方文档自己举的用例就是 "notify themselves when scripts fail, or long-running commands complete"（即 operator 不在跑脚本的机器上）。免费。注意两点：topic 名即权限，要选不可猜的；self-host 版是单个静态二进制（Linux/Docker，K8s 示例限 128Mi 内存，非常轻）但**server 不支持 macOS**——想自托管就跑在别的 Linux 上，个人场景直接用 ntfy.sh 即可。
- **gotify**（[github.com/gotify/server](https://github.com/gotify/server)）：自托管 push server，REST 发送 + WebSocket 接收，Android app（Play/F-Droid），**无 iOS 客户端**。解决的问题与 ntfy 相同但要求你自己运维一个 server；ntfy.sh 免费托管存在的情况下属于重复建设，仅在「必须完全自托管且只用 Android」时选它。

**6 → 无 systemd 的进程监督：launchd / monit / supervisord — 核心区分 DEATH vs STUCK**
- **launchd**（[launchd.plist(5) man page](https://www.manpagez.com/man/5/launchd.plist/)）：`KeepAlive` 支持 dict 形式（`SuccessfulExit`、`NetworkState`、`PathState`、`OtherJobEnabled`，多个条件 OR），`ThrottleInterval` 默认 10s 限制重启频率。只做 **restart，没有任何通知机制**（man page 无一处 alert 相关 key）。mac mini 上用 LaunchAgent 的 `KeepAlive=true` 替代 nohup 是零成本改进：崩溃自动拉起。注意 `SuccessfulExit` 语义是「以 exit 0 重启」，与直觉相反，别用它表达「异常退出才重启」以外的含义。
- **monit**（[官方文档](https://mmonit.com/monit/documentation/monit.html)）：`check process <name> with pidfile|matching <regex>`，未定义时隐式 non-exist→restart；动作可选 `ALERT / RESTART / START / STOP / EXEC / UNMONITOR`，其中 `EXEC "program"` 可执行任意脚本并同时 alert（文档示例即 `sms.sh`）。邮件经 SMTP，alert 有落盘 event queue 防邮件服务器不可用。**唯一同时覆盖 DEATH（non-exist）与 STUCK 信号（`if failed port 80 for 2 cycles then restart`、cpu/mem/children 阈值、`CHECK PROGRAM` 自定义 exit-code 检查）的小型监督器**，C 写成、brew 可装、常驻开销极小。
- **supervisord**（[events 文档](https://supervisord.org/events.html)）：`[eventlistener:x]` 订阅 `PROCESS_STATE_EXITED`（payload 含 `expected:0/1`）或 `PROCESS_STATE_FATAL`（重试 `startretries` 次后放弃），listener 收到事件后自己发邮件/HTTP——官方给 Superlance 包做现成 listener。但 macOS 上 supervisord 是 pip 装的 Python 进程，比 launchd/monit 重。
- **关键结论**：所有监督器天然检测 DEATH；STUCK（进程活着不干活）需要应用把状态外化成监督器可探测的信号——monit 的 connection test / `CHECK PROGRAM`，或下一条的 progress file。监督器**永远看不到「handoff 文件无人认领」这种应用语义**，cap 耗尽必须 daemon 自己报告。

**7 → Kubernetes liveness probe 类比 — progress 与 liveness 的教科书分界**
[k8s 探针文档](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)：liveness 失败 → kubelet **kill + restart**；readiness 失败 → 摘除流量；startup 失败 → 超时 kill。文档原话，liveness 的动机是 "transition to broken states, and cannot recover except by being restarted"。经典 exec 探针 `cat /tmp/healthy`（应用周期性写该文件）就是 **progress-file 模式**：进程活着但不再推进 → 文件过期 → 探针失败。但 k8s 页面**没有任何 progress-based alerting**，只有 restart 与摘流量；真正叫人靠的是 Prometheus 监控 RESTARTS 计数，即 k8s 自己也是「restart 由探针管，alert 由监控管」两层分开。轻量的 progress-alert 等价物：healthchecks.io 的 heartbeat（每次 ping 本身就是一次 progress 信号，grace 内没有 ping 即 Down 告警）或 monit `CHECK PROGRAM` 跑一个「检查 handoff 文件 mtime 新鲜度」的脚本。**没有专门的「progress-based alert」轻量工具品类，它是 heartbeat / check-program 两个成熟模式的应用。**SwarmForge 的 cap 耗尽 alert 语义上等价于应用内置的 liveness→alert，唯一正确位置是 daemon 自己的判定点。

## 给 SwarmForge 的落地排序（按任务优先级：单机适用、最小依赖、operator 异地）

**1 → 首选（LOW）：** cap 耗尽处直接 `curl -d "swarmforge: handoff <id> unclaimed after N attempts" ntfy.sh/<un-guessable-topic>`，~5 行 bb；已有 Hermes CLI 与 SMTP 作第二/第三通道并行发（复用既有工具，零新增）。
**2 → 兜底（LOW）：** 每 reconcile cycle ping 一次 healthchecks.io check（grace 设 10–15min），进程静默死亡也会告警；同一 check 的 `/fail` 端点可在 cap 耗尽时顺带上报失败事件，一套集成两个语义。
**3 → 可选加固（MEDIUM）：** mac mini 上用 launchd `KeepAlive=true` 替代 nohup/caffeinate 拿到崩溃自拉起；若想要 death+stuck+alert 一体的外部监督，`brew install monit`（pidfile + `if not exist then alert` + `CHECK PROGRAM` 查 handoff 文件新鲜度）。
**4 → 明确不做：** Prometheus+Alertmanager（两服务为一声通知）、单通道场景的 apprise、自托管 gotify（ntfy.sh 免费且 iOS 缺位）、log-watcher（比直接 curl 多一个常驻进程）、osascript/terminal-notifier（operator 不在机器前，送达为零）。

## Sources

- Kept: healthchecks.io docs（https://healthchecks.io/docs/）— dead man's switch 状态机、ping URL、/fail、integrations 的一手定义
- Kept: healthchecks GitHub（https://github.com/healthchecks/healthchecks）— self-host 栈成本证据（Django/DB/SMTP/后台进程）
- Kept: ntfy docs（https://docs.ntfy.sh/ 与 https://docs.ntfy.sh/install/）— curl 发布、手机 app、自托管形态与 macOS server 不支持的事实
- Kept: gotify（https://gotify.net/ 与 https://github.com/gotify/server）— 自托管 push server 的形态与客户端覆盖（无 iOS）
- Kept: apprise（https://github.com/caronc/apprise）— 多通道扇出工具的定位与 CLI 形态
- Kept: monit docs（https://mmonit.com/monit/documentation/monit.html）— process check、alert 动作、EXEC、hung 检测、CHECK PROGRAM 原文
- Kept: supervisord events docs（https://supervisord.org/events.html）— eventlistener 协议与 PROCESS_STATE 事件类型
- Kept: launchd.plist(5)（https://www.manpagez.com/man/5/launchd.plist/）— KeepAlive/SuccessfulExit/ThrottleInterval 语义，及无 alert 机制的确认
- Kept: Kubernetes probes docs（https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/）— liveness/readiness/startup 分界与「只 restart 不 alert」的确认
- Kept: Prometheus overview + Alertmanager overview（https://prometheus.io/docs/introduction/overview/ 与 https://prometheus.io/docs/alerting/latest/overview/）— pull model 原文与两组件告警管线
- Kept: fail2ban（https://github.com/fail2ban/fail2ban）— filter.d/action.d 分离的 log-watch 模式证据
- Dropped: terminal-notifier GitHub 仓库页 — 只返回了文件列表，改抓 raw README（保留后者）；osascript 用法 — 平台常识未抓取，报告中已标注未验证；cron-job.org — healthchecks.io 已完整覆盖同一模式，未再抓

## Gaps

- 本次 web_search 全程无结果（两次多 query + 单 query 均空），全部改用直接 fetch 官方文档完成，覆盖不受影响，但未能交叉比对第三方评测。
- healthchecks.io 免费档具体额度（check 数）未从 pricing 页验证；apprise 精确插件总数因 README 表格截断未验证（不影响结论）。
- ntfy iOS 客户端在 self-host 场景下的即时推送限制（iOS 无后台常连，需经 ntfy.sh 中转）未在本次抓取中确认；若走托管 ntfy.sh 则不受影响。
- 建议的下一步（如需要）：验证 SwarmForge 侧现有 Hermes CLI 的失败路径语义，决定 ntfy/Hermes/SMTP 三通道的优先级与去抖（同一 handoff 只报一次）。