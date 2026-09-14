#!/usr/bin/env bb

(ns handoffd
  (:require [babashka.fs :as fs]
            [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.java.shell :refer [sh]]
            [clojure.string :as str]))

(def poll-ms 1000)
(def wake-message
  "You have new handoff mail. If idle, run ready_for_next.sh.")
(def wake-echo-timeout-ms 5000)
(def wake-echo-interval-ms 100)

(defn env-long [name default]
  (or (some-> (System/getenv name) parse-long) default))

;; Retry ladder for handoffs still sitting unclaimed in a recipient's inbox/new.
;; Deliberately not named retry-*: retry-delay-ms below paces outbox delivery,
;; an exponential backoff on an operation that threw. This ladder paces a level
;; check on work nobody picked up. Two different questions, two different
;; schedules, and one name for both is how a later edit silently repoints one at
;; the other.
;;
;; Overridable constants, not standards: a swallowed keystroke must be re-sent,
;; but an agent that is simply slow must not be spammed every second.
;; SWARMFORGE_WAKE_RETRY_MS collapses the ladder to one interval; tests use it to
;; observe several passes without waiting out the real schedule.
(def wake-delays-ms
  (if-let [flat (env-long "SWARMFORGE_WAKE_RETRY_MS" nil)]
    [flat]
    [5000 15000 60000]))
(def wake-interval-ms (env-long "SWARMFORGE_WAKE_RETRY_MS" 300000))
(def wake-attempt-cap (env-long "SWARMFORGE_WAKE_ATTEMPT_CAP" 12))
;; Ladder position a file resumes at when the daemon has no memory of it - after a
;; restart, or after a busy role finally frees up. Without this floor, elapsed
;; wall-clock time alone is charged as attempts: a file older than the whole ladder
;; resumes at the cap and is exhausted by its very first wake, which is precisely
;; the 8-hour-idle case this reconciliation exists to fix. The floor keeps the
;; restart from replaying the fast 5s/15s rungs while leaving most of the cap unspent.
(def wake-resume-floor (env-long "SWARMFORGE_WAKE_RESUME_FLOOR" 3))
;; Wake notifications per poll pass, shared by the queue and reconciliation.
;; poll-once! is single threaded, so an unbounded retry backlog would push
;; outbox->inbox delivery behind it.
(def wake-notify-budget (env-long "SWARMFORGE_WAKE_BUDGET" 2))

;; handoff id -> {:attempts n :last-ms t}. In memory only: a daemon restart costs
;; at most one extra idempotent wake, which is cheaper than a persistence surface
;; to maintain. Keyed by the id header, not the filename, because
;; move-with-collision renames files on delivery collisions.
(def wake-state (atom {}))
(def alerted (atom #{}))

(defn usage []
  (binding [*out* *err*]
    (println "Usage: handoffd.bb [--once] <project-root>"))
  (System/exit 1))

(def once? false)
(def project-root nil)
(def script-dir (fs/parent *file*))
(try
  (require 'card-type)
  (catch Exception _
    (load-file (str (fs/path script-dir "card_type.bb")))))
(try
  (require 'safe-paths)
  (catch Exception _
    (load-file (str (fs/path script-dir "safe_paths.bb")))))
(try
  (require '[handoff-state :as handoff-state])
  (catch Exception _
    (load-file (str (fs/path script-dir "handoff_state.bb")))
    (require '[handoff-state :as handoff-state])))
(def state-dir nil)
(def daemon-dir nil)
(def roles-file nil)
(def socket-file nil)
(def pid-file nil)
(def stop-file nil)
(def log-file nil)
(def stopping-flag (atom false))

(defn configure!
  ([] (configure! *command-line-args*))
  ([args]
   (let [once-flag (boolean (some #(= "--once" %) args))
         root (first (remove #(= "--once" %) args))]
     (when-not root
       (usage))
     (let [state (fs/path root ".swarmforge")
           daemon (fs/path state "daemon")]
       (alter-var-root #'once? (constantly once-flag))
       (alter-var-root #'project-root (constantly root))
       (alter-var-root #'state-dir (constantly state))
       (alter-var-root #'daemon-dir (constantly daemon))
       (alter-var-root #'roles-file (constantly (fs/path state "roles.tsv")))
       (alter-var-root #'socket-file (constantly (fs/path state "tmux-socket")))
       (alter-var-root #'pid-file (constantly (fs/path daemon "handoffd.pid")))
       (alter-var-root #'stop-file (constantly (fs/path daemon "stop")))
       (alter-var-root #'log-file (constantly (fs/path daemon "handoffd.log")))))))

(defn now []
  (.format (java.time.format.DateTimeFormatter/ISO_INSTANT)
           (java.time.Instant/now)))

(defn log! [& parts]
  (fs/create-dirs daemon-dir)
  (spit (str log-file)
        (str (now) " " (str/join " " parts) "\n")
        :append true))

(defn safe-log! [& parts]
  (try
    (apply log! parts)
    (catch Exception _ nil)))

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
                   "artifacts" "batch_id" "batch_task_ids" "card_type" "delivery_kind"
                   "task_base_commit" "message" "created_at" "enqueued_at" "dequeued_at" "completed_at"]
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

(defn wake-probe
  "A short prefix of the text just sent. The input box wraps long text, so
  matching the whole line against the pane is unreliable; a prefix stays
  contiguous on the first visual row."
  [text]
  (subs text 0 (min 16 (count text))))

(defn await-wake-echo!
  "Block until the sent text shows up in the pane, or the timeout expires.

  An agent TUI batches an incoming paste, and a submit key that races that paste
  gets swallowed: the wake-up then sits typed but unsent and the role looks idle
  while work waits in its inbox. A fixed delay cannot cover this because the wait
  depends on TUI startup, load, and paste size, so poll for the echo instead.
  Returns false on timeout; the caller still submits, because a missed echo is
  less bad than no submit at all."
  [socket session text]
  (let [probe (wake-probe text)
        deadline (+ (System/currentTimeMillis) wake-echo-timeout-ms)]
    (loop []
      (cond
        (str/includes? (pane-text socket session) probe) true
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
  ([socket session agent] (notify! socket session agent nil true))
  ([socket session agent message] (notify! socket session agent message true))
  ([socket session agent message await?]
   (let [text (or message wake-message)
         send-text (tmux! "-S" socket "send-keys" "-t" session "-l" text)]
     (when-not (zero? (:exit send-text))
       (throw (ex-info "tmux send text failed" send-text)))
     ;; The echo wait covers the first-delivery race where a submit key lands
     ;; mid-paste. A retry must not wait: it can block up to
     ;; wake-echo-timeout-ms, and poll-once! is single threaded.
     (when (and await? (not (tmux-stub)))
       (await-wake-echo! socket session text))
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

(declare clear-retry-state!)

(defn fail! [path reason]
  (let [headers (:headers (parse-message path))
        failed-dir (fs/path (fs/parent (fs/parent path)) "failed")]
    (log! "failed" (str path) reason)
    (clear-retry-state! headers path)
    (let [moved (move-with-collision path failed-dir)]
      (spit (str (fs/path failed-dir (str (fs/file-name moved) ".error")))
            (str reason "\n")))))

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
        result (apply sh (concat [script] args ["--caller" "handoffd" "--root" (str project-root)]))]
    (when-not (zero? (:exit result))
      (log! "pack-board-failed" args (:err result) (:out result))
      (throw (ex-info (str/trim (str (:err result) "\n" (:out result))) result)))))

(defn archive-sender! [headers]
  (let [from (get headers "from")]
    (when (and (not (str/blank? from))
               (not (re-matches #"\(.+\)" from)))
      (pack-board! "archive" "--archive" from))))

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
  (boolean
   (or (= "true" (get headers "non-forwarding"))
       (#{"reverse" "terminal"} (get headers "delivery_kind")))))

(defn reverse-git-mail? [headers]
  (and (= "git_handoff" (get headers "type"))
       (or (= "reverse" (get headers "delivery_kind"))
           (= "terminal" (get headers "delivery_kind"))
           (non-forwarding? headers)
           (= "00" (get headers "priority")))))

(defn pack-role-names []
  (->> (read-lines roles-file)
       (remove str/blank?)
       (mapv #(first (str/split % #"\t")))))

(defn last-pack-role? [role]
  (= role (last (pack-role-names))))

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

(defn parsed-batch-task-ids [headers]
  (let [value (get headers "batch_task_ids")]
    (if (str/blank? value)
      []
      (try
        (let [parsed (edn/read-string value)]
          (when (and (vector? parsed)
                     (every? #(and (string? %) (not (str/blank? %))) parsed))
            parsed))
        (catch Exception _ nil)))))

(defn valid-batch-task-ids? [headers]
  (let [value (get headers "batch_task_ids")
        parsed (parsed-batch-task-ids headers)]
    (or (str/blank? value)
        (and (seq parsed)
             (= parsed (vec (distinct parsed)))
             (= (task-key headers) (first parsed))))))

(defn valid-batch-id? [headers]
  (let [batch-id (get headers "batch_id")]
    (or (str/blank? batch-id)
        (and (safe-paths/state-key? batch-id)
             (seq (parsed-batch-task-ids headers))))))

(defn batch-task-keys [headers]
  (let [parsed (parsed-batch-task-ids headers)]
    (if (seq parsed) parsed [(task-key headers)])))

(defn board-row-for-key [key]
  (some (fn [line]
          (let [row (card-type/parse-row project-root line)]
            (when (or (= key (:id row))
                      (= (str/lower-case (or key ""))
                         (str/lower-case (or (:name row) ""))))
              row)))
        (or (read-lines (board-file)) [])))

(defn board-row-for-headers [headers]
  (board-row-for-key (task-key headers)))

(def delivery-kinds #{"forward" "reverse" "terminal"})

(defn expected-terminal-recipients [headers]
  (let [from (get headers "from")
        row (board-row-for-headers headers)]
    (cond
      (and row (card-type/last-on-card? project-root (:type row) from))
      (card-type/terminal-upstream project-root (pack-role-names) (:type row))

      (and (nil? row) (last-pack-role? from))
      (vec (butlast (pack-role-names)))

      :else nil)))

(defn exact-recipient-set? [actual expected]
  (and (some? expected)
       (= (count actual) (count expected))
       (= (set actual) (set expected))))

(defn exact-terminal-recipients? [headers]
  (exact-recipient-set? (vec (recipient-list headers))
                        (expected-terminal-recipients headers)))

(defn effective-delivery-kind [headers]
  (or (get headers "delivery_kind")
      (cond
        (exact-terminal-recipients? headers) "terminal"
        (or (= "true" (get headers "non-forwarding"))
            (= "00" (get headers "priority"))) "reverse"
        :else "forward")))

(defn terminal-handoff? [_roles headers]
  (and (= "git_handoff" (get headers "type"))
       (= "terminal" (effective-delivery-kind headers))
       (exact-terminal-recipients? headers)))

(defn board-row-key [line]
  (let [[name _lane _created _updated task-id] (str/split line #"\t" -1)]
    (or (not-empty task-id) name)))

(defn board-row-name [line]
  (first (str/split line #"\t" -1)))

(defn board-name-for-key [task-key]
  (some (fn [line]
          (let [name (board-row-name line)]
            (when (or (= task-key (board-row-key line))
                      (= task-key name))
              name)))
        (read-lines (board-file))))

(defn forge-root []
  (let [parent (fs/parent project-root)
        grand (when parent (fs/parent parent))]
    (when (and parent grand
               (= "projects" (fs/file-name parent))
               (fs/directory? (fs/path grand "projects")))
      (str grand))))

(defn lieutenant-agent
  "Backend of the forge-level lieutenant session, from column 6 of the forge's
  own roles.tsv. notify! needs it to pick the submit key, and the project roles
  this daemon loaded say nothing about the forge. Defaults to codex, which is
  also what every backend but Claude wants from submit-keys."
  [forge]
  (or (some (fn [line]
              (let [cols (str/split line #"\t")]
                (when (= "lieutenant" (first cols))
                  (not-empty (nth cols 5 nil)))))
            (read-lines (fs/path forge ".swarmforge" "roles.tsv")))
      "codex"))

(defn notify-event [headers]
  (if (terminal-handoff? nil headers)
    "card-done"
    (str (or (not-empty (get headers "from")) "unknown") "-handoff")))

(defn notify-lieutenant! [headers]
  (when-let [forge (forge-root)]
    (let [event (notify-event headers)
          dir (fs/path forge ".swarmforge" "notify")
          stamp (str/replace (now) #"[^0-9A-Za-z]" "")
          file (fs/path dir (str stamp "-" event ".notify"))
          socket-path (fs/path forge ".swarmforge" "tmux-socket")
          socket (when (fs/exists? socket-path)
                   (not-empty (str/trim (slurp (str socket-path)))))]
      (fs/create-dirs dir)
      (spit (str file)
            (str "project: " (fs/file-name project-root) "\n"
                 "event: " event "\n"
                 "from: " (get headers "from") "\n"
                 "task: " (or (get headers "task") "") "\n"))
      (when socket
        (try
          (notify! socket "swarmforge-lieutenant" (lieutenant-agent forge)
                   (str "Notify: " event))
          (catch Exception e
            (log! "lieutenant-notify-failed" (.getMessage e))))))))

(defn update-board! [roles headers]
  (when (and (fs/exists? (board-file))
             (= "git_handoff" (get headers "type"))
             (seq (recipient-list headers)))
    (cond
      (terminal-handoff? roles headers)
      (let [keys (batch-task-keys headers)]
        (if (next keys)
          (pack-board! "transition-batch" "--task-ids" (pr-str keys) "--lane" "done")
          (let [name (or (board-name-for-key (first keys)) (get headers "task"))]
            (when-not (str/blank? name)
              (pack-board! "done" "--name" name)))))

      (non-forwarding? headers)
      nil

      :else
      (let [keys (batch-task-keys headers)
            lane (first (recipient-list headers))]
        (if (next keys)
          (pack-board! "transition-batch" "--task-ids" (pr-str keys) "--lane" lane)
          (let [task (or (board-name-for-key (first keys)) (get headers "task"))]
            (when-not (str/blank? task)
              (pack-board! "move" "--name" task "--lane" lane))))))))

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

(declare outbox-files queue-wakeup!)

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
    (try
      (notify! socket
               (get-in roles [sender-role :session])
               (get-in roles [sender-role :agent]))
      (safe-log! "notified-unblocked-sender" sender-role)
      (catch Exception e
        (try
          (queue-wakeup! headers sender-role (.getMessage e))
          (catch Exception queue-error
            (safe-log! "sender-wake-queue-failed" sender-role
                       (.getMessage queue-error))))
        (safe-log! "sender-wake-failed" sender-role (.getMessage e))))))

(defn retry-file [path]
  (fs/path (str path ".retry.edn")))

(defn read-edn-file [path]
  (when (fs/regular-file? path)
    (try (edn/read-string (slurp (str path)))
         (catch Exception _ nil))))

(defn epoch-ms []
  (.toEpochMilli (java.time.Instant/now)))

(defn retry-delay-ms [attempt]
  (min 60000 (* 1000 (long (Math/pow 2 (min 6 (max 0 (dec attempt))))))))

(defn write-edn-atomic! [path value]
  (fs/create-dirs (fs/parent path))
  (let [tmp (fs/create-temp-file {:dir (fs/parent path) :prefix ".state."})]
    (spit (str tmp) (str (pr-str value) "\n"))
    (fs/move tmp path {:replace-existing true :atomic-move true})))

(defn attention-dir []
  (fs/path state-dir "handoffs" "delivery_attention"))

(defn safe-stem [value]
  (str/replace (or value "handoff") #"[^A-Za-z0-9._-]+" "_"))

(defn reverse-cycle-file []
  (fs/path daemon-dir "reverse-cycle.edn"))

(defn new-reverse-cycle []
  {:id (str (safe-stem (now)) "-" (java.util.UUID/randomUUID))
   :started-at (now)})

(defn reverse-cleared-event-file [forge cycle]
  (fs/path forge ".swarmforge" "notify"
           (str (safe-stem (:id cycle)) "-reverse-cleared.notify")))

(defn write-reverse-cleared-event! [forge cycle]
  (let [file (reverse-cleared-event-file forge cycle)]
    (if (fs/exists? file)
      false
      (let [dir (fs/parent file)
            tmp (do
                  (fs/create-dirs dir)
                  (fs/create-temp-file {:dir dir :prefix ".reverse-cleared."}))]
        (try
          (spit (str tmp)
                (str "project: " (fs/file-name project-root) "\n"
                     "event: reverse-cleared\n"
                     "cycle: " (:id cycle) "\n"))
          (try
            (fs/move tmp file {:replace-existing false :atomic-move true})
            true
            (catch java.nio.file.FileAlreadyExistsException _
              false))
          (finally
            (fs/delete-if-exists tmp)))))))

(defn notify-reverse-cleared! [cycle]
  (when-let [forge (forge-root)]
    (when (write-reverse-cleared-event! forge cycle)
      (let [socket-path (fs/path forge ".swarmforge" "tmux-socket")
            socket (when (fs/regular-file? socket-path)
                     (not-empty (str/trim (slurp (str socket-path)))))]
        (when socket
          (try
            (notify! socket "swarmforge-lieutenant" (lieutenant-agent forge)
                     "Notify: reverse-cleared")
            (catch Exception e
              (safe-log! "lieutenant-notify-failed" (.getMessage e)))))))))

(defn read-reverse-cycle []
  (let [file (reverse-cycle-file)]
    (when (fs/regular-file? file)
      (or (read-edn-file file)
          {:id (safe-stem (str/trim (slurp (str file))))}))))

(defn reconcile-reverse-cycle! []
  (let [file (reverse-cycle-file)
        active? (handoff-state/synchronization-active? project-root)
        cycle (read-reverse-cycle)]
    (cond
      (and active? (nil? cycle))
      (write-edn-atomic! file (new-reverse-cycle))

      (and (not active?) cycle)
      (do
        (notify-reverse-cleared! cycle)
        (fs/delete-if-exists file)))))

(defn attention-file [headers path]
  (fs/path (attention-dir)
           (str (safe-stem (or (get headers "id") (fs/file-name path))) ".edn")))

(defn clear-retry-state! [headers path]
  (fs/delete-if-exists (retry-file path))
  (fs/delete-if-exists (attention-file headers path)))

(defn record-retry! [path error]
  (let [file (retry-file path)
        prior (or (read-edn-file file) {})
        attempt (inc (long (or (:attempt prior) 0)))
        state {:attempt attempt
               :error error
               :updated-at (now)
               :next-at (+ (epoch-ms) (retry-delay-ms attempt))}
        headers (:headers (parse-message path))]
    (write-edn-atomic! file state)
    (when (>= attempt 3)
      (write-edn-atomic! (attention-file headers path)
                         (assoc state
                                :id (get headers "id")
                                :task (get headers "task")
                                :from (get headers "from"))))
    (log! "retry" (str path) (str "attempt=" attempt) error)))

(defn retry-due? [path]
  (let [state (read-edn-file (retry-file path))]
    (or (nil? state) (<= (long (or (:next-at state) 0)) (epoch-ms)))))

(defn permanent-error [message]
  (ex-info message {:permanent true}))

(defn raw-recipients [headers]
  (mapv str/trim (str/split (or (get headers "to") "") #"," -1)))

(defn validate-delivery-kind! [headers recipients]
  (let [type (get headers "type")
        declared (get headers "delivery_kind")
        kind (effective-delivery-kind headers)
        expected-terminal (expected-terminal-recipients headers)]
    (when (and declared (not (delivery-kinds declared)))
      (throw (permanent-error "invalid delivery_kind header")))
    (when (and declared (not= "git_handoff" type))
      (throw (permanent-error "delivery_kind is only valid for git_handoff")))
    (when (= "git_handoff" type)
      (case kind
        "terminal"
        (do
          (when (and declared (not= "true" (get headers "non-forwarding")))
            (throw (permanent-error "terminal delivery must be non-forwarding")))
          (when-not (exact-recipient-set? recipients expected-terminal)
            (throw (permanent-error
                    (str "terminal recipient set must be exactly "
                         (str/join "," (or expected-terminal [])))))))

        "reverse"
        (when (and declared (not= "true" (get headers "non-forwarding")))
          (throw (permanent-error "reverse delivery must be non-forwarding")))

        "forward"
        (when expected-terminal
          (throw (permanent-error
                  (str "last role must send one terminal handoff to "
                       (str/join "," expected-terminal)))))

        (throw (permanent-error "invalid delivery_kind header"))))))

(defn same-delivery? [source-headers target recipient]
  (let [target-headers (:headers (parse-message target))]
    (and (= (get source-headers "id") (get target-headers "id"))
         (= recipient (get target-headers "recipient")))))

(defn preflight! [roles sender-role path message]
  (let [headers (:headers message)
        recipients (raw-recipients headers)
        filename (fs/file-name path)]
    (when (str/blank? (get headers "id"))
      (throw (permanent-error "missing id header")))
    (try
      (safe-paths/require-internal-id! (get headers "id"))
      (catch Exception _
        (throw (permanent-error "invalid id header"))))
    (when (str/blank? sender-role)
      (throw (permanent-error "missing from header")))
    (when-not (#{"git_handoff" "note"} (get headers "type"))
      (throw (permanent-error "missing or invalid type header")))
    (when-not (re-matches #"[0-9][0-9]" (or (get headers "priority") ""))
      (throw (permanent-error "missing or invalid priority header")))
    (when (and (= "git_handoff" (get headers "type"))
               (str/blank? (task-key headers)))
      (throw (permanent-error "missing task header")))
    (when (and (= "git_handoff" (get headers "type"))
               (not (valid-batch-task-ids? headers)))
      (throw (permanent-error "invalid batch_task_ids header")))
    (when (and (= "git_handoff" (get headers "type"))
               (not (valid-batch-id? headers)))
      (throw (permanent-error "invalid batch_id header")))
    (when (and (= "git_handoff" (get headers "type"))
               (fs/regular-file? (board-file)))
      (doseq [key (batch-task-keys headers)]
        (when-not (safe-paths/state-key? key)
          (throw (permanent-error "invalid board task key")))
        (when-not (board-row-for-key key)
          (throw (permanent-error (str "unknown board task " key))))))
    (when (or (empty? recipients) (some str/blank? recipients))
      (throw (permanent-error "missing or empty recipient")))
    (when-not (= (count recipients) (count (distinct recipients)))
      (throw (permanent-error "duplicate recipient")))
    (validate-delivery-kind! headers recipients)
    (when (and (not (phantom-sender? sender-role)) (nil? (get roles sender-role)))
      (throw (permanent-error (str "unknown sender " sender-role))))
    (doseq [recipient recipients]
      (let [role-info (get roles recipient)]
        (when-not role-info
          (throw (permanent-error (str "unknown recipient " recipient))))
        (when-not (fs/directory? (:worktree-path role-info))
          (throw (ex-info (str "recipient worktree unavailable: " recipient) {})))
        (let [target (target-path role-info filename)]
          (when (and (fs/exists? target)
                     (not (same-delivery? headers target recipient)))
            (throw (permanent-error (str "conflicting recipient file " target)))))))
    recipients))

(defn store-recipient! [message role-info recipient filename]
  (let [target (target-path role-info filename)]
    (when-not (fs/exists? target)
      (let [delivered (add-delivery-headers message recipient)
            dir (fs/parent target)
            tmp (do (fs/create-dirs dir)
                    (fs/create-temp-file {:dir dir :prefix ".delivery."}))]
        (try
          (spit (str tmp) (render-message (:headers delivered) (:body delivered)))
          (fs/move tmp target {:replace-existing false :atomic-move true})
          (finally
            (fs/delete-if-exists tmp)))))))

;; D-5 (docs/fork-deltas.md): level reconciliation for unclaimed handoffs.
;;
;; The wakeup queue below is edge-triggered - an entry exists only because
;; notify! threw, and a tmux exit 0 deletes it. That leaves three silent holes:
;; a TUI that swallows the submit key (tmux still exits 0), a queue write that
;; itself fails, and a crash between committing the delivery to sent/ and
;; queueing. In all three the work sits in inbox/new and nothing ever wakes
;; anyone again. The file in inbox/new is the level - it stays until
;; ready_for_next moves it to in_process - so scanning for it makes wake-up
;; at-least-once instead of fire-and-forget.

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

(defn wake-delay-ms [attempts]
  (get wake-delays-ms attempts wake-interval-ms))

(defn attempts-from-age
  "Ladder position implied by how long a file has waited. Used when the daemon has
  no in-memory record, so a restart resumes the ladder instead of replaying
  5s/15s/60s from the top."
  [age-ms]
  (loop [n 0 spent 0]
    (let [d (wake-delay-ms n)]
      (if (or (>= n wake-attempt-cap) (< age-ms (+ spent d)))
        n
        (recur (inc n) (+ spent d))))))

(defn due-attempt
  "Attempt number to make now for an unclaimed handoff, or nil if it is not due
  yet or the cap is spent.

  With no in-memory record the clock starts at the file's own enqueued_at rather
  than at daemon start: after a restart the ladder resumes where it was. That
  resume position is clamped to wake-resume-floor, not just to (dec cap): age
  alone would otherwise charge a long-idle file the full ladder as attempts and
  exhaust it on its very first wake, which is exactly the silent-strand case
  this reconciliation exists to fix."
  [now-ms id enqueued-ms]
  (if-let [{:keys [attempts last-ms]} (get @wake-state id)]
    (when (and (< attempts wake-attempt-cap)
               (>= (- now-ms last-ms) (wake-delay-ms attempts)))
      attempts)
    (let [age (- now-ms enqueued-ms)]
      (when (>= age (wake-delay-ms 0))
        (min (attempts-from-age age) (dec wake-attempt-cap) wake-resume-floor)))))

(defn busy?
  "True when this role is already working something. inbox-handoffs descends
  into batch_ directories, so a batch in progress counts just like a single
  handoff does."
  [role-info]
  (role-has-inbox-state? role-info "in_process"))

(defn wake-candidates
  "Unclaimed handoffs due for a wake retry, oldest filename first."
  [roles now-ms]
  (->> (vals roles)
       (remove busy?)
       (mapcat (fn [role-info]
                 (for [path (sort-by fs/file-name (inbox-handoffs role-info "new"))
                       :let [headers (:headers (parse-message path))
                             id (get headers "id")
                             enqueued (parse-instant-ms (get headers "enqueued_at"))
                             attempt (when (and id enqueued)
                                       (due-attempt now-ms id enqueued))]
                       :when attempt]
                   {:role-info role-info :path path :id id :attempt attempt})))
       (sort-by #(fs/file-name (:path %)))))

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
      (safe-log! "alert" id (str "exit=" (:exit result))
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
    (safe-log! "wake-exhausted" id (str "attempts=" attempts))
    (alert! id attempts)))

(defn reconcile-once!
  "Re-send the wake hint for handoffs still sitting in a recipient's inbox/new.

  Never moves, copies, or deletes anything: a lost notification must never be
  mistaken for invalid work. `skip` is the set of roles the wakeup queue already
  woke this pass, and `budget` is what it left over - one budget across both, or
  a retry backlog starves outbox delivery."
  [roles socket skip budget]
  (when (pos? budget)
    (let [now-ms (System/currentTimeMillis)]
      (doseq [{:keys [role-info id attempt]}
              (->> (wake-candidates roles now-ms)
                   (remove #(contains? skip (:role (:role-info %))))
                   (distinct-by :id)
                   (take budget))]
        (try
          ;; No echo wait: a retry can block up to wake-echo-timeout-ms and
          ;; poll-once! is single threaded.
          (notify! socket (:session role-info) (:agent role-info) nil false)
          (safe-log! "wake-retry" id (str "attempt=" attempt))
          (catch Exception e
            ;; Log and count, then come back next tick. Routing this through fail!
            ;; would quarantine legitimate unclaimed work.
            (safe-log! "wake-retry-failed" id (.getMessage e))))
        (let [attempts (inc attempt)]
          (swap! wake-state assoc id {:attempts attempts :last-ms now-ms})
          (when (>= attempts wake-attempt-cap)
            (wake-exhausted! id attempts)))))))

(defn wakeup-dir []
  (fs/path daemon-dir "wakeups"))

(defn wakeup-file [handoff-id recipient]
  (fs/path (wakeup-dir) (str (safe-stem handoff-id) "--" (safe-stem recipient) ".edn")))

(defn queue-wakeup! [headers recipient error]
  (write-edn-atomic! (wakeup-file (get headers "id") recipient)
                     {:id (get headers "id")
                      :recipient recipient
                      :attempt 1
                      :next-at (+ (epoch-ms) 1000)
                      :error error}))

(defn notify-or-queue! [roles socket headers recipient]
  (try
    (notify! socket
             (get-in roles [recipient :session])
             (get-in roles [recipient :agent]))
    (catch Exception e
      (try
        (queue-wakeup! headers recipient (.getMessage e))
        (safe-log! "wake-queued" recipient (.getMessage e))
        (catch Exception queue-error
          (safe-log! "wake-queue-failed" recipient
                     (.getMessage queue-error)))))))

(defn process-wakeups!
  "Retry queued wakes whose notify! threw. Returns {:woke #{role} :spent n} so
  reconcile-once! neither wakes the same role twice in one pass nor spends a
  budget this already spent."
  [roles socket budget]
  (let [woke (atom #{})
        spent (atom 0)]
    (when (fs/directory? (wakeup-dir))
      (doseq [file (fs/list-dir (wakeup-dir))
              :while (< @spent budget)
              :when (fs/regular-file? file)
              :let [state (read-edn-file file)]
              :when (and state (<= (long (or (:next-at state) 0)) (epoch-ms)))]
        (let [recipient (:recipient state)
              info (get roles recipient)]
          (cond
            (nil? info) (fs/delete-if-exists file)
            ;; A role already working must not be interrupted. The entry stays
            ;; queued and comes back once the role is free, and it costs no
            ;; budget, because nothing was sent.
            (busy? info) nil
            :else
            (do
              (swap! spent inc)
              (swap! woke conj recipient)
              (try
                ;; A retry must not wait for the pane echo: it can block up to
                ;; wake-echo-timeout-ms and poll-once! is single threaded.
                (notify! socket (:session info) (:agent info) nil false)
                (fs/delete-if-exists file)
                (catch Exception e
                  (let [attempt (inc (long (or (:attempt state) 0)))]
                    (write-edn-atomic! file (assoc state
                                                   :attempt attempt
                                                   :next-at (+ (epoch-ms) (retry-delay-ms attempt))
                                                   :error (.getMessage e)))))))))))
    {:woke @woke :spent @spent}))

(defn deliver! [roles socket sender-role path]
  (let [filename (fs/file-name path)
        message (parse-message path)
        headers (:headers message)
        recipients (preflight! roles sender-role path message)]
    (doseq [recipient recipients]
      (store-recipient! message (get roles recipient) recipient filename))
    (update-board! roles headers)
    (archive-sender! headers)
    (move-with-collision path (sent-dir roles sender-role))
    ;; Delivery is committed once the source reaches sent/. Nothing after this
    ;; point is allowed to turn it back into a delivery failure.
    (try
      (clear-retry-state! headers path)
      (catch Exception e
        (safe-log! "retry-cleanup-failed" (str path) (.getMessage e))))
    (doseq [recipient recipients]
      (notify-or-queue! roles socket headers recipient))
    (try
      (maybe-notify-unblocked-sender! roles socket headers sender-role)
      (catch Exception e
        (safe-log! "sender-wake-processing-failed" sender-role (.getMessage e))))
    (try
      (notify-lieutenant! headers)
      (catch Exception e
        (safe-log! "lieutenant-event-failed" (.getMessage e))))
    (safe-log! "delivered" (str path))))

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
      (do
        (hold! (fs/path path))
        (try (notify-lieutenant! headers)
             (catch Exception e (log! "lieutenant-event-failed" (.getMessage e)))))
      (deliver! roles socket (or from "") (fs/path path)))))

(defn poll-once! []
  (when-not (should-stop?)
    (let [roles (load-roles)
          socket (str/trim (slurp (str socket-file)))
          paths (->> (concat (mapcat #(or (outbox-files %) []) (vals roles))
                             (or (outbox-files {:worktree-path project-root}) []))
                     (map str)
                     distinct
                     vec)]
      (doseq [path paths
              :while (not (should-stop?))
              :when (retry-due? path)]
        (try
          (process-outbox-file! roles socket path)
          (catch Exception e
            (log! "error" path (.getMessage e))
            (if (:permanent (ex-data e))
              (try
                (fail! (fs/path path) (.getMessage e))
                (catch Exception nested
                  (log! "failed-to-archive" path (.getMessage nested))))
              (try
                (record-retry! (fs/path path) (.getMessage e))
                (catch Exception nested
                  (log! "failed-to-record-retry" path (.getMessage nested))))))))
      (let [{:keys [woke spent]} (try
                                   (process-wakeups! roles socket wake-notify-budget)
                                   (catch Exception e
                                     (safe-log! "wakeups-failed" (.getMessage e))
                                     {:woke #{} :spent 0}))]
        (try
          (reconcile-once! roles socket woke (- wake-notify-budget spent))
          (catch Exception e
            (safe-log! "reconcile-failed" (.getMessage e)))))
      (try
        (reconcile-reverse-cycle!)
        (catch Exception e
          (safe-log! "reverse-cycle-failed" (.getMessage e)))))))

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

(defn -main [& args]
  (configure! (if (seq args) args *command-line-args*))
  (if once?
    (poll-once!)
    (run-daemon!)))

(when (= (str *file*) (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))
