# 最小 swarm 原型（wayfinder #189）

**一次性代码，看完结论就扔。** 不进主线，不写测试，不加抽象。

要回答的是一句话：**底座 C（pi SDK 当外壳）真的立得住吗？** 到 #189 为止，这个底座全是读文档
读出来的。这个原型不求真项目、不求 PR，只求**两个 role 之间那一次 git handoff 真的发生**。

## 跑

```sh
bash scratch.sh                  # 建一次性 repo + coder/cleaner 两棵长期 worktree
node swarm.mjs                   # 默认 hang 模式
node swarm.mjs --turn            # 对照组：handoff 工具立刻返回，一张卡一轮
node swarm.mjs --resume          # 杀掉进程之后重开，看两个 session 记不记得
```

有用的 flag：

| flag | 作用 |
|---|---|
| `--auto-answer "文本"` | 自动回答 `ask_operator`，无人值守跑完整条链路 |
| `--provider` / `--model` | 默认 `litellm/cd-sonnet-4.6`（本机 `pi-claude` 一个模型都没有） |

`ask_operator` 的人工回答走文件队列，跟 [#186](https://github.com/arlishansenn/swarm-forge/issues/186)
定的形状一致：

```sh
cat ~/.swarm-189-scratch/pending/*.json        # 谁在问什么
echo "你的回答" > ~/.swarm-189-scratch/pending/<那个 id>.answer
```

## 形状

```text
一个 Node 进程
├── session(coder)    cwd=~/.swarm-189-scratch/worktrees/coder    分支 coder
├── session(cleaner)  cwd=~/.swarm-189-scratch/worktrees/cleaner  分支 cleaner
└── 信箱 inbox/waiting —— 外壳全部的调度状态，两个对象而已

role prompt 落在每棵 worktree 的 AGENTS.md（故意不提交，否则两条分支互相 merge 时会
平白多一个冲突）。#182 查实 system prompt 是每次 createAgentSession 按当前磁盘内容重新
生成的，所以这就是新仓库里 role prompt 的真实落点。
```

跑的这条链路故意踩满了要验的点：

1. 先让 `cleaner` 在 `notes.md` **同一行**上落一个 commit，然后挂起等卡。
2. 投卡给 `coder`：改同一行、提交、`handoff` 给 `cleaner`。
3. `cleaner` 被那次 handoff 唤醒 → `git merge` → **必然冲突**，它得自己解。
4. 合并之后的活故意写得含糊（「风格按我们约定的来」）→ 逼它调 `ask_operator`。
5. 人回答 → 它接着干完 → 调 `handoff` 但不填 `to`（末端，non-forwarding）。

## 要证伪的六条 —— 结论

**六条全成，底座 C 立得住。** 下面每条都是这个原型真跑出来的，不是读文档读出来的。

### 1. cwd 隔离：成

`cwd` 作用在**工具执行**的工作目录上，不是 `process.chdir()`。两个 session 在一个 Node 进程里
并行跑 bash，各自只动自己那棵 worktree，没有任何串台。各自 `git log` 干净分叉。

### 2. handoff 动词可以是异步的、挂着等下一张卡：成

`ToolDefinition.execute()` 是 `Promise<AgentToolResult>`，**挂多久都行，SDK 不掐**
（#182 查实源码没有内置超时包装）。所以「交出去然后等下一张卡」可以直接表达成：
工具把载荷交给外壳，然后 `await` 一个 Promise，下一张卡**从这个工具的返回值回来**。

代价说清楚：这样一来 **role 的一生只有一轮**，`prompt()` 永远不返回。见发现 #3。

对照组 `--turn`（工具立刻返回、外壳再 `prompt()` 一次）也通，代价是每张卡一轮、上下文按轮切。

### 3. 唤醒：成，两条路都通

- **handoff 唤醒**：coder 调 `handoff` 的那一瞬间，挂了几分钟的 cleaner 当场醒过来，
  **接着同一轮往下走**，不是重开。
- **外部投卡**：往 `$ROOT/cards/<role>.txt` 写一句话就能叫醒一个空转的 role。
  这就是 [#186](https://github.com/arlishansenn/swarm-forge/issues/186) 定的 Dashboard「投任务」
  那条路的最小形状。不用轮询、不用 tmux、不用 `send-keys`。

### 4. 澄清：成

role 调 `ask_operator` → 外壳写 `pending/<id>.json` → 人写 `<id>.answer` → 答案从工具返回值回去，
**role 还在原来那一轮里**，接着把活干完。完全不需要 `uiContext`。

一条阴性结果，同样要记：第一版把歧义写成「风格按我们约定的来」，cleaner **自己拍板了，根本没问**。
把歧义改成真的猜不出来的（代号只有 operator 知道）之后才问。
**「遇到歧义问 operator」这条协议靠 prompt 钉不住**，跟 `docs/fork-deltas.md` 的教训同一类。

### 5. receiver merge：成

故意让两个 role 改 `notes.md` 同一处，handoff 过去必然冲突。cleaner **自己 `git merge`、自己解、
自己提交**，没退回来问，也没发明别的合并办法。协议的「冲突归接收方」在 SDK 下原样成立。
末端的 non-forwarding 语义也守住了：cleaner 每次都调 `handoff` 但不填 `to`。

### 6. 杀进程重启：成

两个 session 的 `.jsonl` 在进程被 `kill` 之后完整留在盘上。新进程用 `SessionManager.open(<同一个文件>)`
重开，cleaner 准确说出它上一步合并的是哪个 commit、任务名是什么——跟被杀前严丝合缝。

## 三个坑（都是跑的时候真撞上的）

**→ 1. `tools` 白名单会连 custom tool 一起挡掉。** `createAgentSession({ tools: [...] })` 一旦给了
allowlist，**custom tool 也必须列进去**。文档那句「Extension/custom tools remain enabled unless
`noTools` changes that default」只在**省略** `tools` 时成立。漏列不报错，role 就是看不见工具——
它会退而去 PATH 里找同名命令，cleaner 当场 `find /Users/admin` 扫整个家目录扫到卡死。

**→ 2. role prompt 放 worktree 的 `AGENTS.md`，光「不 git add」挡不住。** role 自己会跑
`git add -A` 顺手提交它，然后两条分支互相 merge 时凭空多一个 `AGENTS.md` 冲突。
得写进 `.git/info/exclude`。

**→ 3. hang 模式下没有「一轮结束」这个时机。** `prompt()` 永远不返回，所以外壳**不能**把落盘
挂在它后面。得自己找钩子（建 session 时存一次 + 每次 deliver 之后存调度状态）。
`turn_end` 事件也不行——它是「一次 LLM 回复 + 那批工具」结束，一张卡里会来好几次。

## 顺带纠正两条前置研究的说法

- **`uiContext` 不是 `createAgentSession` 的 option**（0.86.1）。它在更底层的 `AgentSessionOptions`
  上（`dist/core/agent-session.d.ts:144`），外加 `runner.setUIContext()`。
  但这条对新仓库不重要：**澄清用一个会挂起的 custom tool 就够了，根本不碰 `uiContext`。**
- **`session.jsonl` 在第一条 assistant 回复之前确实不落盘**——`sessionFile` 立刻就有值，
  磁盘上的目录也建好了，但文件本身还不存在。#182 的说法成立。
