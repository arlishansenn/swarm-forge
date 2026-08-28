#!/usr/bin/env bb

(ns handoffd
  (:require [babashka.fs :as fs]
            [clojure.java.io :as io]
            [clojure.java.shell :refer [sh]]
            [clojure.string :as str]))

(def poll-ms 1000)
(def wake-message
  "You have new handoff mail. If idle, run ready_for_next.sh.")
;; A short slice of wake-message. The input box wraps long text, so matching the
;; whole line against the pane is unreliable.
(def wake-probe "new handoff mail")
(def wake-echo-timeout-ms 5000)
(def wake-echo-interval-ms 100)

(defn env-long [name default]
  (or (some-> (System/getenv name) parse-long) default))

;; Retry ladder for handoffs still sitting unclaimed in a recipient's inbox/new.
;; Overridable constants, not standards: a swallowed keystroke must be re-sent,
;; but an agent that is simply slow must not be spammed every second.
;; SWARMFORGE_WAKE_RETRY_MS collapses the ladder to one interval; tests use it to
;; observe several passes without waiting out the real schedule.
(def retry-delays-ms
  (if-let [flat (env-long "SWARMFORGE_WAKE_RETRY_MS" nil)]
    [flat]
    [5000 15000 60000]))
(def retry-interval-ms (env-long "SWARMFORGE_WAKE_RETRY_MS" 300000))
(def retry-attempt-cap (env-long "SWARMFORGE_WAKE_ATTEMPT_CAP" 12))
;; Ladder position a file resumes at when the daemon has no memory of it - after a
;; restart, or after a busy role finally frees up. Without this floor, elapsed
;; wall-clock time alone is charged as attempts: a file older than the whole ladder
;; resumes at the cap and is exhausted by its very first wake, which is precisely
;; the 8-hour-idle case this reconciliation exists to fix. The floor keeps the
;; restart from replaying the fast 5s/15s rungs while leaving most of the cap unspent.
(def retry-resume-floor (env-long "SWARMFORGE_WAKE_RESUME_FLOOR" 3))
;; Wake retries per poll pass. poll-once! is single threaded, so an unbounded
;; retry backlog would push outbox->inbox delivery behind it.
(def retry-notify-budget (env-long "SWARMFORGE_WAKE_BUDGET" 2))

;; handoff id -> {:attempts n :last-ms t}. In memory only: a daemon restart costs
;; at most one extra idempotent wake, which is cheaper than a persistence surface
;; to maintain. Keyed by the id header, not the filename, because
;; move-with-collision renames files on delivery collisions.
(def retry-state (atom {}))

(defn usage []
  (binding [*out* *err*]
    (println "Usage: handoffd.bb [--once] <project-root>"))
  (System/exit 1))

(def once? (some #(= "--once" %) *command-line-args*))
(def project-root
  (or (first (remove #(= "--once" %) *command-line-args*)) (usage)))
(def script-dir (fs/parent *file*))

(def state-dir (fs/path project-root ".swarmforge"))
(def daemon-dir (fs/path state-dir "daemon"))
(def roles-file (fs/path state-dir "roles.tsv"))
(def socket-file (fs/path state-dir "tmux-socket"))
(def pid-file (fs/path daemon-dir "handoffd.pid"))
(def stop-file (fs/path daemon-dir "stop"))
(def log-file (fs/path daemon-dir "handoffd.log"))
(def stopping-flag (atom false))

(defn now []
  (.format (java.time.format.DateTimeFormatter/ISO_INSTANT)
           (java.time.Instant/now)))

(defn log! [& parts]
  (fs/create-dirs daemon-dir)
  (spit (str log-file)
        (str (now) " " (str/join " " parts) "\n")
        :append true))

(defn read-lines [path]
  (when (fs/exists? path)
    (str/split-lines (slurp (str path)))))

(defn load-roles []
  (into {}
        (for [line (read-lines roles-file)
              :when (not (str/blank? line))
              :let [[role worktree-name worktree-path session display agent receive-mode]
                    (str/split line #"\t")]]
          [role {:role role
                 :worktree-name worktree-name
                 :worktree-path worktree-path
                 :session session
                 :display display
                 :agent agent
                 :receive-mode (or receive-mode "task")}])))

(defn parse-message [path]
  (let [content (slurp (str path))
        [header body] (str/split content #"\n\n" 2)
        headers (into {}
                      (for [line (str/split-lines header)
                            :let [[k v] (str/split line #": " 2)]
                            :when (and k v)]
                        [k v]))]
    {:headers headers
     :body (or body "")
     :content content}))

(defn render-message [headers body]
  (let [preferred ["id" "from" "to" "recipient" "priority" "type" "role" "task_id" "task" "commit"
                   "artifacts" "task_base_commit" "message" "created_at" "enqueued_at" "dequeued_at" "completed_at"]
        remaining (->> (keys headers)
                       (remove (set preferred))
                       sort)
        ordered (concat preferred remaining)]
    (str (str/join "\n"
                   (for [k ordered
                         :let [v (get headers k)]
                         :when v]
                     (str k ": " v)))
         "\n\n"
         body)))

(defn add-delivery-headers [message recipient]
  (-> message
      (assoc-in [:headers "recipient"] recipient)
      (assoc-in [:headers "enqueued_at"] (now))))

(defn target-path [role-info filename]
  (fs/path (:worktree-path role-info)
           ".swarmforge" "handoffs" "inbox" "new" filename))

(defn tmux-stub []
  (System/getenv "SWARMFORGE_TMUX_STUB"))

(defn record-argv! [file argv]
  (when-let [dir (fs/parent file)]
    (fs/create-dirs dir))
  (spit (str file) (str (pr-str (vec argv)) "\n") :append true))

(defn tmux!
  "Every tmux call goes through here so tests can record argv instead of driving
  a real TUI. The stub answers exit 0: a recorder has nothing to fail at."
  [& argv]
  (let [full (into ["tmux"] argv)]
    (if-let [stub (tmux-stub)]
      (do (record-argv! stub full) {:exit 0 :out "" :err ""})
      (apply sh full))))

(defn pane-text [socket session]
  (let [result (tmux! "-S" socket "capture-pane" "-p" "-t" session)]
    (if (zero? (:exit result)) (:out result) "")))

(defn await-wake-echo!
  "Block until the wake text shows up in the pane, or the timeout expires.

  An agent TUI batches an incoming paste, and a submit key that races that paste
  gets swallowed: the wake-up then sits typed but unsent and the role looks idle
  while work waits in its inbox. A fixed delay cannot cover this because the wait
  depends on TUI startup, load, and paste size, so poll for the echo instead.
  Returns false on timeout; the caller still submits, because a missed echo is
  less bad than no submit at all."
  [socket session]
  (let [deadline (+ (System/currentTimeMillis) wake-echo-timeout-ms)]
    (loop []
      (cond
        (str/includes? (pane-text socket session) wake-probe) true
        (>= (System/currentTimeMillis) deadline) false
        :else (do (Thread/sleep wake-echo-interval-ms) (recur))))))

(defn submit-keys
  "tmux send-keys arguments that make this agent's TUI submit its input line.

  Both branches send raw bytes on purpose. A symbolic key name goes through
  tmux's key-encoding layer, which re-encodes it for a TUI that negotiated
  extended keys, so `C-m` does not reliably arrive as a literal Enter. Claude
  Code negotiates the kitty keyboard protocol and only submits on CSI u
  (ESC [ 13 u); every other backend wants the plain carriage return 0x0d, and
  sending CSI u to a TUI that did not negotiate would insert those bytes as
  literal text."
  [agent]
  (if (= agent "claude")
    [["-H" "1b" "5b" "31" "33" "75"]]
    [["-H" "0d"]]))

(defn notify!
  ([socket session agent] (notify! socket session agent true))
  ([socket session agent await?]
   (let [send-text (tmux! "-S" socket "send-keys" "-t" session "-l" wake-message)]
     (when-not (zero? (:exit send-text))
       (throw (ex-info "tmux send text failed" send-text)))
     ;; The echo wait covers the first-delivery race where a submit key lands
     ;; mid-paste. A retry must not wait: it can block up to
     ;; wake-echo-timeout-ms, and poll-once! is single threaded.
     (when (and await? (not (tmux-stub)))
       (await-wake-echo! socket session))
     (doseq [keys (submit-keys agent)]
       (let [result (apply tmux! (concat ["-S" socket "send-keys" "-t" session] keys))]
         (when-not (zero? (:exit result))
           (throw (ex-info "tmux send submit key failed" result)))
         (when-not (tmux-stub)
           (Thread/sleep 50)))))))

(defn move-with-collision [source target-dir]
  (fs/create-dirs target-dir)
  (let [base (fs/file-name source)
        target (fs/path target-dir base)]
    (if (fs/exists? target)
      (fs/move source
               (fs/path target-dir (str (now) "_" base))
               {:replace-existing false})
      (fs/move source target {:replace-existing false}))))

(defn fail! [path reason]
  (let [failed-dir (fs/path (fs/parent (fs/parent path)) "failed")]
    (log! "failed" (str path) reason)
    (spit (str path ".error") (str reason "\n"))
    (move-with-collision path failed-dir)))

(defn recipient-list [headers]
  (some->> (get headers "to")
           (#(str/split % #","))
           (map str/trim)
           (remove str/blank?)
           seq))

(defn board-file []
  (fs/path project-root ".swarmforge" "board" "tasks.tsv"))

(defn pack-board! [& args]
  (let [script (str (fs/path script-dir "pack_board.sh"))
        result (apply sh (concat [script] args ["--root" (str project-root)]))]
    (when-not (zero? (:exit result))
      (log! "pack-board-failed" args (:err result) (:out result))
      (throw (ex-info (str/trim (str (:err result) "\n" (:out result))) result)))))

(defn archive-sender! [headers]
  (let [from (get headers "from")]
    (when (and (not (str/blank? from))
               (not (re-matches #"\(.+\)" from)))
      (pack-board! "archive" "--role" from))))

(defn master-role-name [roles]
  (some (fn [[role info]]
          (when (= "master" (:worktree-name info))
            role))
        roles))

(defn specifier-pack? [roles]
  (contains? roles "specifier"))

(defn from-master? [roles headers]
  (= (get headers "from") (master-role-name roles)))

(defn non-forwarding? [headers]
  (= "true" (get headers "non-forwarding")))

(defn pack-role-names []
  (->> (read-lines roles-file)
       (remove str/blank?)
       (mapv #(first (str/split % #"\t")))))

(defn last-pack-role? [role]
  (= role (last (pack-role-names))))

(defn terminal-handoff? [_roles headers]
  (last-pack-role? (get headers "from")))

(defn listed-handoffs [dir]
  (if (fs/directory? dir)
    (->> (fs/list-dir dir)
         (filter #(and (fs/regular-file? %)
                       (str/ends-with? (fs/file-name %) ".handoff")))
         vec)
    []))

(defn listed-batches [dir]
  (if (fs/directory? dir)
    (->> (fs/list-dir dir)
         (filter #(and (fs/directory? %)
                       (str/starts-with? (fs/file-name %) "batch_")))
         vec)
    []))

(defn inbox-handoffs [role-info state]
  (let [dir (fs/path (:worktree-path role-info)
                     ".swarmforge" "handoffs" "inbox" state)]
    (into (listed-handoffs dir)
          (mapcat listed-handoffs (listed-batches dir)))))

(defn role-has-inbox-state? [role-info state]
  (boolean (seq (inbox-handoffs role-info state))))

(defn task-key [headers]
  (or (not-empty (get headers "task_id"))
      (get headers "task")))

(defn finished-task-keys [role-info]
  (if-not role-info
    #{}
    (->> (concat (inbox-handoffs role-info "completed")
                 (inbox-handoffs role-info "in_process"))
         (map #(task-key (:headers (parse-message %))))
         (remove str/blank?)
         set)))

(defn board-row-key [line]
  (let [[name _lane _created _updated task-id] (str/split line #"\t" -1)]
    (or (not-empty task-id) name)))

(defn board-row-name [line]
  (first (str/split line #"\t" -1)))

(defn keys-in-lane [lane]
  (->> (read-lines (board-file))
       (remove str/blank?)
       (map #(str/split % #"\t" -1))
       (filter #(= lane (second %)))
       (mapcat (fn [cols]
                 (let [line (str/join "\t" cols)
                       name (first cols)
                       key (board-row-key line)]
                   (distinct [key name]))))))

(defn terminal-task-keys [roles headers]
  (let [from (get headers "from")
        named (task-key headers)
        finished (finished-task-keys (get roles from))
        in-lane (set (keys-in-lane from))]
    (->> (cons named (filter finished in-lane))
         (remove str/blank?)
         distinct
         vec)))

(defn board-name-for-key [task-key]
  (some (fn [line]
          (let [name (board-row-name line)]
            (when (or (= task-key (board-row-key line))
                      (= task-key name))
              name)))
        (read-lines (board-file))))

(defn update-board! [roles headers]
  (when (and (fs/exists? (board-file))
             (= "git_handoff" (get headers "type"))
             (seq (recipient-list headers)))
    (cond
      (terminal-handoff? roles headers)
      (doseq [key (terminal-task-keys roles headers)
              :let [name (or (board-name-for-key key) (get headers "task"))]]
        (when-not (str/blank? name)
          (pack-board! "done" "--name" name)))

      (non-forwarding? headers)
      nil

      :else
      (let [key (task-key headers)
            task (or (board-name-for-key key) (get headers "task"))]
        (when-not (str/blank? task)
          (pack-board! "move" "--name" task "--lane" (first (recipient-list headers))))))))

(defn single-recipient? [headers]
  (let [recipients (recipient-list headers)]
    (boolean (and recipients (nil? (next recipients))))))

(defn already-approved? [headers]
  (not (str/blank? (get headers "approved"))))

(defn should-hold? [roles headers]
  (and (= "git_handoff" (get headers "type"))
       (specifier-pack? roles)
       (from-master? roles headers)
       (single-recipient? headers)
       (not (already-approved? headers))))

(defn pending-dir []
  (fs/path state-dir "handoffs" "pending_approval"))

(defn hold! [path]
  (move-with-collision path (pending-dir))
  (log! "held" (str path)))

(defn phantom-sender? [from]
  (boolean (re-matches #"\(.+\)" (or from ""))))

(defn sent-dir [roles sender-role]
  (if (phantom-sender? sender-role)
    (fs/path project-root ".swarmforge" "handoffs" "sent")
    (fs/path (get-in roles [sender-role :worktree-path])
             ".swarmforge" "handoffs" "sent")))

(declare outbox-files)

(defn approved-git-handoff? [headers]
  (and (= "git_handoff" (get headers "type"))
       (not (str/blank? (get headers "approved")))))

(defn outbound-git-from-role? [role file]
  (let [headers (:headers (parse-message file))]
    (and (= "git_handoff" (get headers "type"))
         (= role (get headers "from")))))

(defn active-outbound-git-files [roles sender-role]
  (if (str/blank? sender-role)
    []
    (let [pending (listed-handoffs (pending-dir))
          outbox (->> (concat (mapcat #(or (outbox-files %) []) (vals roles))
                              (or (outbox-files {:worktree-path project-root}) []))
                      distinct)]
      (->> (concat pending outbox)
           (filter #(outbound-git-from-role? sender-role %))
           vec))))

(defn sender-ready-work? [roles sender-role]
  (when-let [role-info (get roles sender-role)]
    (and (role-has-inbox-state? role-info "new")
         (not (role-has-inbox-state? role-info "in_process"))
         (empty? (active-outbound-git-files roles sender-role)))))

(defn maybe-notify-unblocked-sender! [roles socket headers sender-role]
  (when (and (approved-git-handoff? headers)
             (sender-ready-work? roles sender-role)
             (not (contains? (set (recipient-list headers)) sender-role)))
    ;; D-3 (docs/fork-deltas.md): notify! is [socket session agent], because
    ;; the submit-key encoding differs per backend. upstream's new call site
    ;; here passes two arguments; the arity error is caught by deliver!'s
    ;; handler and the sender is simply never woken.
    (notify! socket
             (get-in roles [sender-role :session])
             (get-in roles [sender-role :agent]))
    (log! "notified-unblocked-sender" sender-role)))

(defn deliver! [roles socket sender-role path]
  (let [filename (fs/file-name path)
        message (parse-message path)
        headers (:headers message)
        recipients (recipient-list headers)]
    (if-not recipients
      (fail! path "missing to header")
      (do
        (update-board! roles headers)
        (doseq [recipient recipients]
          (let [role-info (get roles recipient)]
            (when-not role-info
              (throw (ex-info (str "unknown recipient " recipient) {:recipient recipient})))
            (let [target (target-path role-info filename)
                  delivered (add-delivery-headers message recipient)]
              (fs/create-dirs (fs/parent target))
              (when-not (fs/exists? target)
                (spit (str target) (render-message (:headers delivered) (:body delivered))))
              (notify! socket (:session role-info) (:agent role-info)))))
        (move-with-collision path (sent-dir roles sender-role))
        (archive-sender! headers)
        (maybe-notify-unblocked-sender! roles socket headers sender-role)
        (log! "delivered" (str path))))))

(defn distinct-by [f coll]
  (:out (reduce (fn [{:keys [seen out]} x]
                  (let [k (f x)]
                    (if (contains? seen k)
                      {:seen seen :out out}
                      {:seen (conj seen k) :out (conj out x)})))
                {:seen #{} :out []}
                coll)))

(defn parse-instant-ms [s]
  (try
    (.toEpochMilli (java.time.Instant/parse s))
    (catch Exception _ nil)))

(defn retry-delay-ms [attempts]
  (get retry-delays-ms attempts retry-interval-ms))

(defn attempts-from-age
  "Ladder position implied by how long a file has waited. Used when the daemon has
  no in-memory record, so a restart resumes the ladder instead of replaying
  5s/15s/60s from the top."
  [age-ms]
  (loop [n 0 spent 0]
    (let [d (retry-delay-ms n)]
      (if (or (>= n retry-attempt-cap) (< age-ms (+ spent d)))
        n
        (recur (inc n) (+ spent d))))))

(defn due-attempt
  "Attempt number to make now for an unclaimed handoff, or nil if it is not due
  yet or the cap is spent.

  With no in-memory record the clock starts at the file's own enqueued_at rather
  than at daemon start: after a restart the ladder resumes where it was. That
  resume position is clamped to retry-resume-floor, not just to (dec cap): age
  alone would otherwise charge a long-idle file the full ladder as attempts and
  exhaust it on its very first wake, which is exactly the silent-strand case
  this reconciliation exists to fix."
  [now-ms id enqueued-ms]
  (if-let [{:keys [attempts last-ms]} (get @retry-state id)]
    (when (and (< attempts retry-attempt-cap)
               (>= (- now-ms last-ms) (retry-delay-ms attempts)))
      attempts)
    (let [age (- now-ms enqueued-ms)]
      (when (>= age (retry-delay-ms 0))
        (min (attempts-from-age age) (dec retry-attempt-cap) retry-resume-floor)))))

(defn inbox-dir [role-info state]
  (fs/path (:worktree-path role-info) ".swarmforge" "handoffs" "inbox" state))

(defn handoff-files [dir]
  (if (fs/exists? dir)
    (->> (fs/list-dir dir)
         (filter #(and (fs/regular-file? %)
                       (str/ends-with? (fs/file-name %) ".handoff")))
         (sort-by #(fs/file-name %)))
    []))

(defn busy?
  "True when this role is already working something. Its inbox/in_process holds
  both single handoffs and batch directories, so any entry counts."
  [role-info]
  (let [dir (inbox-dir role-info "in_process")]
    (and (fs/exists? dir) (boolean (seq (fs/list-dir dir))))))

(defn wake-candidates
  "Unclaimed handoffs due for a wake retry, oldest filename first."
  [roles now-ms]
  (->> (vals roles)
       (remove busy?)
       (mapcat (fn [role-info]
                 (for [path (handoff-files (inbox-dir role-info "new"))
                       :let [headers (:headers (parse-message path))
                             id (get headers "id")
                             enqueued (parse-instant-ms (get headers "enqueued_at"))
                             attempt (when (and id enqueued)
                                       (due-attempt now-ms id enqueued))]
                       :when attempt]
                   {:role-info role-info :path path :id id :attempt attempt})))
       (sort-by #(fs/file-name (:path %)))))

(def alerted (atom #{}))

(defn alert!
  "Hand a cap-exhausted handoff to whatever channel the operator configured.

  The daemon log is audit, not delivery: a chain once stalled eight hours with
  the evidence sitting in this very log and nobody reading it. So the channel is
  an env hook the deployment fills in - hermes, ntfy, mail, anything that reaches
  a human - and this code stays ignorant of which. The command sees the handoff
  id and attempt count as env vars so it can name what is stuck.

  A broken alert channel must never stop the daemon, so a failing or missing
  command is logged and swallowed."
  [id attempts]
  (when-let [cmd (System/getenv "SWARMFORGE_ALERT_CMD")]
    (let [env (merge (into {} (System/getenv))
                     {"SWARMFORGE_ALERT_HANDOFF" id
                      "SWARMFORGE_ALERT_ATTEMPTS" (str attempts)})
          result (try
                   (sh "sh" "-c" cmd :env env)
                   (catch Exception e {:exit -1 :out "" :err (.getMessage e)}))]
      (log! "alert" id (str "exit=" (:exit result))
            (str/trim (str (:out result) " " (:err result)))))))

(defn wake-exhausted!
  "Record that nobody claimed this handoff after the cap, and alert the operator
  once. The work stays in inbox/new forever on purpose: quarantine is for
  malformed outbound handoffs, never for work whose notification failed.

  The de-bounce is the point of the alerted set - reconcile reaches this cap
  check on every later pass, and an alert that repeats every second is noise a
  human learns to ignore."
  [id attempts]
  (when-not (contains? @alerted id)
    (swap! alerted conj id)
    (log! "wake-exhausted" id (str "attempts=" attempts))
    (alert! id attempts)))

(defn reconcile-once!
  "Re-send the wake hint for handoffs still sitting in a recipient's inbox/new.

  The wake hint is lossy: every agent TUI encodes Enter differently and a
  keystroke that lands mid-paste gets swallowed, which strands the chain with no
  log anomaly. The file in inbox/new is the level - it stays until
  ready_for_next moves it to in_process - so re-sending until it moves makes
  wake-up at-least-once instead of fire-and-forget. Never moves, copies, or
  deletes anything: a lost notification must never be mistaken for invalid work."
  [roles socket]
  (let [now-ms (System/currentTimeMillis)]
    (doseq [{:keys [role-info id attempt]}
            (->> (wake-candidates roles now-ms)
                 (distinct-by :id)
                 (take retry-notify-budget))]
      (try
        (notify! socket (:session role-info) (:agent role-info) false)
        (log! "wake-retry" id (str "attempt=" attempt))
        (catch Exception e
          ;; Log and count, then come back next tick. Routing this through fail!
          ;; would quarantine legitimate unclaimed work.
          (log! "wake-retry-failed" id (.getMessage e))))
      (let [attempts (inc attempt)]
        (swap! retry-state assoc id {:attempts attempts :last-ms now-ms})
        (when (>= attempts retry-attempt-cap)
          (wake-exhausted! id attempts))))))

(defn outbox-files [role-info]
  (let [outbox (fs/path (:worktree-path role-info) ".swarmforge" "handoffs" "outbox")]
    (when (fs/exists? outbox)
      (->> (fs/list-dir outbox)
           (filter #(and (fs/regular-file? %)
                         (str/ends-with? (fs/file-name %) ".handoff")))
           (sort-by #(fs/file-name %))))))

(defn should-stop? []
  (or @stopping-flag (fs/exists? stop-file)))

(defn sleep-poll! [ms]
  (loop [remaining ms]
    (when (and (pos? remaining) (not (should-stop?)))
      (let [step (min remaining 100)]
        (Thread/sleep step)
        (recur (- remaining step))))))

(defn process-outbox-file! [roles socket path]
  (let [headers (:headers (parse-message path))
        from (get headers "from")]
    (if (should-hold? roles headers)
      (hold! (fs/path path))
      (deliver! roles socket (or from "") (fs/path path)))))

(defn poll-once! []
  (when-not (should-stop?)
    (let [roles (load-roles)
          socket (str/trim (slurp (str socket-file)))
          paths (->> (concat (mapcat #(or (outbox-files %) []) (vals roles))
                             (or (outbox-files {:worktree-path project-root}) []))
                     (map str)
                     distinct)]
      (doseq [path paths
              :while (not (should-stop?))]
        (try
          (process-outbox-file! roles socket path)
          (catch Exception e
            (log! "error" path (.getMessage e))
            (try
              (fail! (fs/path path) (.getMessage e))
              (catch Exception nested
                (log! "failed-to-archive" path (.getMessage nested)))))))
      ;; Guarded separately: a reconcile bug must never take delivery down with it.
      (try
        (reconcile-once! roles socket)
        (catch Exception e
          (log! "reconcile-error" (.getMessage e)))))))

(defn shutdown! []
  (reset! stopping-flag true)
  (try
    (fs/delete-if-exists pid-file)
    (log! "stopped")
    (catch Exception _ nil)))

(defn run-daemon! []
  (fs/create-dirs daemon-dir)
  (fs/delete-if-exists stop-file)
  (spit (str pid-file) (str (.pid (java.lang.ProcessHandle/current)) "\n"))
  (.addShutdownHook (Runtime/getRuntime) (Thread. shutdown!))
  (log! "started")
  (try
    (while (not (should-stop?))
      (poll-once!)
      (sleep-poll! poll-ms))
    (finally
      (fs/delete-if-exists pid-file)
      (log! "stopped"))))

(defn -main []
  (if once?
    (poll-once!)
    (run-daemon!)))

(-main)
