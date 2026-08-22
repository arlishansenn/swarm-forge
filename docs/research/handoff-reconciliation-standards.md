# Handoff reconciliation standards

## Decision

Treat `inbox/new` as durable unclaimed work and its move to `inbox/in_process` as the authoritative claim acknowledgement. Keep initial tmux notification as a low-latency fast path, then periodically scan `inbox/new` and re-notify entries that remain unclaimed. Do not copy, move, quarantine, or delete an unclaimed handoff during notification retry.

`tmux capture-pane` is diagnostic evidence only. Rendered terminal text does not prove that the TUI submitted a turn or that the agent claimed the handoff.

## Candidate matrix

| Candidate | Internal standard and evidence | External best practice and problem solved | Cost to adopt | Verdict |
| --- | --- | --- | --- | --- |
| Periodic `inbox/new` reconciliation | `handoffd.bb:275` already runs `poll-once!` every second; `handoff-protocol.md:495-497` explicitly calls tmux wake-ups lossy; `enqueued_at` already records delivery time. | Kubernetes Controllers continuously reconcile current state toward desired state. This replaces a lossy edge-trigger with a level-triggered correctness path. <https://kubernetes.io/docs/concepts/architecture/controller/> | One bounded scan in the existing daemon, plus per-work retry scheduling. O(number of queued files) per scan. No dependency. | **adapt** — make this the correctness path. |
| Durable claim acknowledgement | `ready_for_next_task.bb:102-132` atomically moves `new` to `in_process` and writes `dequeued_at`; batch mode has the same lifecycle. | RabbitMQ manual consumer acknowledgements and SQS receive/delete semantics distinguish transport success from application acceptance. <https://www.rabbitmq.com/docs/confirms> <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html> | Almost none for unclaimed work: file location is already the acknowledgement. The daemon only needs to stop retrying when the original file leaves `new`. | **adopt** — existing state transition is authoritative. |
| Initial backend-specific Enter | Local fork `handoffd.bb:134-143` already selects submit keys by backend; commit `7903d03` added Claude CSI-u. The observed Codex failure leaves wake text in the composer. | No general queue standard specifies Codex key encoding; this is a TUI contract detail. Queue standards still require reconciliation because a correct key can be lost for other reasons. | Tiny code and regression-test change. Requires the isolated Codex TUI repro to prove raw `0d` is necessary and sufficient. | **adapt** — useful fast-path fix, insufficient as reliability guarantee. |
| Re-notify the same durable entry | Wake text is generic and idempotent; helpers consult durable file state. `done_with_current_task.bb:65-93` checks for the next item after completion. | SQS standard queues and RabbitMQ acknowledgements provide at-least-once delivery and require idempotent consumers. <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/standard-queues-at-least-once-delivery.html> <https://www.rabbitmq.com/docs/reliability> | Duplicate wake messages are expected. Preserve one stable handoff ID and never create a second inbox file for a notification retry. | **adopt** — retry the hint, not the payload. |
| Capped backoff and escalation | `swarm-window-watchdog.bb:8,123-143` already uses strike thresholds; `handoffd.bb:41` has append-only timestamped logging. | AWS Well-Architected requires bounded retries and backoff to avoid retry amplification; jitter prevents synchronized spikes. <https://docs.aws.amazon.com/wellarchitected/latest/framework/rel_mitigate_interaction_failure_limit_retries.html> | Keep a small in-memory retry map keyed by stable handoff ID; daemon restart may cause one harmless extra wake. A single daemon does not need a new scheduler or broker. | **adapt** — capped schedule; small or no jitter is sufficient on one host. Escalate after the cap but keep work pending. |
| `capture-pane` submission verification | Local fork `handoffd.bb:105-120` waits until wake text is visible; `pack_web.bb:431-448` captures panes for display. | tmux only guarantees capture of rendered pane contents; alternate screen, history, wrapping, mode and escape handling change what is captured. <https://github.com/tmux/tmux/blob/master/tmux.1> | Text parsing is coupled to TUI rendering and locale, with false positives and false negatives. | **ruled out as acknowledgement**; **adapt for diagnostics only**. It may delay another key injection or improve logs, never stop reconciliation or mark work claimed. |
| Quarantine/DLQ for unclaimed work | Existing `failed/` and collision-aware moves handle malformed outbound handoffs, but there is no evidence that an unclaimed valid handoff is poison work. | SQS DLQ and RabbitMQ dead-lettering isolate repeatedly processed failures, not messages that never received a consumer acknowledgement. <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html> <https://www.rabbitmq.com/docs/dlx> | Quarantining unclaimed work can silently remove valid work from the active queue. | **ruled out for notification failure**. Alert and reduce retry frequency, but retain pending state. Use quarantine only for explicit non-retryable processing failure. |
| Lease recovery for claimed work | `in_process` persists across restart and `ready_for_next_task` resumes it, but no lease or heartbeat exists. | SQS visibility timeout and heartbeat extension recover work after a consumer claims it and then crashes. <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html> | Requires owner, lease deadline, heartbeat, duplicate side-effect protection and policy. This is a separate failure mode from a stuck `new` entry. | **ruled out for the current ticket**; open separately if claimed-task crash recovery is required. |
| New retry dependency or message broker | Existing Babashka poll loop, files and timestamps cover the required mechanism. | SQS/RabbitMQ solve distributed durability and multi-consumer coordination, but add service operation, network and semantic migration costs. | Large dependency and infrastructure surface for a single-host queue. | **ruled out**. |

## Recommended minimal state flow

```text
deliver
  write one durable inbox/new/<handoff-id>
  send backend-specific wake hint                 # fast path

reconcile (existing daemon loop)
  for each inbox/new entry
    if retry is due
      send the same wake hint again               # never duplicate payload
      record attempt in memory + append-only log

agent accepts
  ready_for_next moves the original file
    inbox/new -> inbox/in_process
  writes dequeued_at                               # authoritative claim ack

reconcile
  original file no longer in inbox/new
  stop wake retries
```

Suggested single-host retry policy is a measured capped schedule, for example 5s, 15s, 60s, then every 5 minutes with an operator alert after a fixed number of attempts. These values are examples, not standards: choose them from observed TUI startup and agent-turn latency. A daemon restart can reset the in-memory schedule because one extra idempotent wake is safe.

## Important corrections to tempting designs

1. Do not move a stale unclaimed entry to quarantine before it is claimed. Notification failure is not evidence that work is invalid.
2. Do not copy the payload back into `inbox/new`; that creates duplicate work. Re-send only the wake hint for the original stable handoff ID.
3. Do not treat `tmux send-keys` exit zero, visible wake text, or disappearing text as a consumer acknowledgement.
4. Do not add lease recovery to the unclaimed-work ticket. `new` reconciliation and `in_process` crash recovery are separate state machines.
5. Do not add SQS, RabbitMQ, a second daemon, or a retry library. The existing poll loop and filesystem states are sufficient.

## Regression seam

Use the existing temporary repository fixtures in `test/swarmforge/handoff_test.clj` and `handoffd --once`. The deterministic test should create an old entry in a recipient's `inbox/new`, run one reconciliation pass with notifier calls recorded, and assert:

- the original file remains the only payload file;
- a wake is attempted when due;
- no wake is attempted after the file moves to `inbox/in_process`;
- retries follow the configured cap/schedule;
- `capture-pane` results do not change durable queue state.

A separate isolated real-Codex tmux harness is still required to prove whether raw `0d` fixes the backend-specific submit event. That experiment should not be confused with the reconciliation regression test.

## Recommendation and reversal fact

**Recommended default:** adapt the existing daemon into an at-least-once, level-triggered notifier. Use file movement to `inbox/in_process` as the only claim acknowledgement; use `capture-pane` only for diagnostics.

**One fact that would change the default:** a supported Claude/Codex machine-readable protocol that durably reports `claimed(handoff-id)` directly to handoffd. If that exists, use it for immediate acknowledgement and keep periodic filesystem reconciliation only as a safety net.

## Sources

### Internal

- `swarmforge/scripts/handoffd.bb`: `notify!`, `poll-once!`, `run-daemon!`, logging and local fork echo polling.
- `swarmforge/scripts/ready_for_next_task.bb`: durable `new` to `in_process` claim transition.
- `swarmforge/scripts/done_with_current_task.bb`: completion and next-item check.
- `swarmforge/handoff-protocol.md`: queue lifecycle and intentionally lossy wake semantics.
- `swarmforge/scripts/swarm-window-watchdog.bb`: threshold-based recovery pattern.
- `swarmforge/scripts/pack_web.bb`: pane capture used for observability.
- `test/swarmforge/handoff_test.clj`: temporary fixtures and `--once` daemon seam.
- Official issue: <https://github.com/unclebob/swarm-forge/issues/34>.

### External primary sources

- Kubernetes Controllers: <https://kubernetes.io/docs/concepts/architecture/controller/>
- Amazon SQS at-least-once delivery: <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/standard-queues-at-least-once-delivery.html>
- Amazon SQS visibility timeout: <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html>
- Amazon SQS dead-letter queues: <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html>
- AWS Well-Architected retry control: <https://docs.aws.amazon.com/wellarchitected/latest/framework/rel_mitigate_interaction_failure_limit_retries.html>
- RabbitMQ Reliability Guide: <https://www.rabbitmq.com/docs/reliability>
- RabbitMQ Consumer Acknowledgements: <https://www.rabbitmq.com/docs/confirms>
- RabbitMQ Dead Letter Exchanges: <https://www.rabbitmq.com/docs/dlx>
- Stripe idempotent requests: <https://docs.stripe.com/api/idempotent_requests>
- tmux upstream manual: <https://github.com/tmux/tmux/blob/master/tmux.1>
