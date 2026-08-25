(ns swarmforge.handoff-test
  (:require [babashka.fs :as fs]
            [clojure.java.shell :as sh]
            [clojure.string :as str]
            [clojure.test :refer [deftest is run-tests testing use-fixtures]]))

(def repo-root (fs/cwd))
(def scripts-dir (fs/path repo-root "swarmforge" "scripts"))
(def temp-dirs (atom []))

(use-fixtures :once
  (fn [tests]
    (try
      (tests)
      (finally
        (doseq [dir @temp-dirs]
          (fs/delete-tree dir))))))

(defn script [name]
  (str (fs/path scripts-dir name)))

(defn tmp-dir []
  (let [dir (fs/create-temp-dir {:prefix "swarmforge-handoff-test."})]
    (swap! temp-dirs conj dir)
    dir))

(defn run
  [{:keys [dir env ok?]} & args]
  (let [result (apply sh/sh (concat args [:dir (str dir)
                                          :env (merge {"PATH" (System/getenv "PATH")
                                                       "GIT_CONFIG_NOSYSTEM" "1"}
                                                      env)]))]
    (when (and (not (false? ok?)) (not= 0 (:exit result)))
      (throw (ex-info (str "Command failed: " (str/join " " args))
                      (assoc result :args args))))
    result))

(defn write-file [path text]
  (fs/create-dirs (fs/parent path))
  (spit (str path) text))

(defn read-file [path]
  (slurp (str path)))

(defn init-repo! [root]
  (run {:dir root} "git" "init" "-q")
  (run {:dir root} "git" "config" "user.email" "test@example.com")
  (run {:dir root} "git" "config" "user.name" "Test User")
  (write-file (fs/path root "README.md") "initial\n")
  (run {:dir root} "git" "add" "README.md")
  (run {:dir root} "git" "commit" "-q" "-m" "Initial commit")
  (str/trim (:out (run {:dir root} "git" "rev-parse" "--short=10" "HEAD"))))

(defn setup-project!
  ([root] (setup-project! root {"sender" "task" "receiver" "task"}))
  ([root roles]
   (doseq [dir [".swarmforge/handoffs/outbox/tmp"
                ".swarmforge/handoffs/sent"
                ".swarmforge/handoffs/failed"
                ".swarmforge/handoffs/inbox/new"
                ".swarmforge/handoffs/inbox/in_process"
                ".swarmforge/handoffs/inbox/completed"]]
     (fs/create-dirs (fs/path root dir)))
   (write-file
    (fs/path root ".swarmforge/roles.tsv")
    (apply str
           (for [[role mode] roles]
             (format "%s\tmaster\t%s\tsession\t%s\tcodex\t%s\n"
                     role root (str/capitalize role) mode))))))

(defn handoff
  [{:keys [id from to recipient priority type task commit body
           enqueued-at dequeued-at completed-at]}]
  (str "id: " id "\n"
       "from: " from "\n"
       "to: " to "\n"
       (when recipient (str "recipient: " recipient "\n"))
       "priority: " priority "\n"
       "type: " type "\n"
       (when task (str "task: " task "\n"))
       (when commit (str "commit: " commit "\n"))
       (when enqueued-at (str "enqueued_at: " enqueued-at "\n"))
       (when dequeued-at (str "dequeued_at: " dequeued-at "\n"))
       (when completed-at (str "completed_at: " completed-at "\n"))
       "\n"
       (or body (str "payload for " id)) "\n"))

(defn handoff-path [root state filename]
  (fs/path root ".swarmforge" "handoffs" "inbox" state filename))

(defn put-handoff! [root state filename attrs]
  (let [path (handoff-path root state filename)]
    (write-file path (handoff attrs))
    path))

(defn header [path field]
  (some->> (str/split-lines (read-file path))
           (take-while seq)
           (some (fn [line]
                   (let [prefix (str field ": ")]
                     (when (str/starts-with? line prefix)
                       (subs line (count prefix))))))))

(defn head-sha [root]
  (str/trim (:out (run {:dir root} "git" "rev-parse" "--short=10" "HEAD"))))

(defn read-argv
  "Read a SWARMFORGE_TMUX_STUB file back into a vector of argv vectors."
  [path]
  (if (fs/exists? path)
    (->> (str/split-lines (read-file path))
         (remove str/blank?)
         (mapv read-string))
    []))

(defn run-handoffd-once!
  "One daemon pass with tmux replaced by an argv recorder."
  [root argv-file]
  (run {:dir root :env {"SWARMFORGE_TMUX_STUB" (str argv-file)}}
       "bb" (script "handoffd.bb") "--once" (str root)))

(defn make-queued-handoff!
  ([root filename attrs]
   (let [sha (or (:commit attrs) (head-sha root))]
     (put-handoff! root "new" filename
                   (merge {:from "sender"
                           :to "receiver"
                           :recipient "receiver"
                           :priority "50"
                           :type "git_handoff"
                           :task "task-one"
                           :commit sha
                           :body (str "merge_and_process sender " sha)}
                          attrs)))))

(deftest swarm-handoff-help-is-usage-not-a-draft
  ;; Given the handoff helper
  ;; When it is run with --help or -h
  ;; Then it prints usage and does not treat the flag as a missing draft file
  (doseq [flag ["--help" "-h"]]
    (let [result (run {:dir repo-root :ok? false}
                      (script "swarm_handoff.sh") flag)
          text (str (:err result) (:out result))]
      (is (zero? (:exit result)) flag)
      (is (str/includes? text "Usage:") flag)
      (is (not (str/includes? text "Draft file not found")) flag))))

(defn add-worktree! [root name]
  (let [wt (fs/path root ".worktrees" name)]
    (fs/create-dirs (fs/parent wt))
    (run {:dir root} "git" "worktree" "add" "-q" (str wt) "HEAD")
    wt))

(deftest swarm-handoff-queues-on-the-project-from-a-worktree
  ;; Given a sender worktree and a commit only made there
  ;; When swarm_handoff runs in that worktree
  ;; Then the queued file is on the project, and the commit is the worktree HEAD
  (let [root (tmp-dir)
        _ (init-repo! root)
        wt (add-worktree! root "sender")
        _ (setup-project! root {"sender" "task" "receiver" "task"})
        _ (write-file (fs/path root ".swarmforge" "roles.tsv")
                      (format "sender\tsender\t%s\tsession\tSender\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\ttask\n"
                              wt root))
        _ (write-file (fs/path wt "slice.md") "from the worktree\n")
        _ (run {:dir wt} "git" "add" "slice.md")
        _ (run {:dir wt} "git" "commit" "-q" "-m" "Worktree slice")
        wt-head (str/trim (:out (run {:dir wt} "git" "rev-parse" "--short=10" "HEAD")))
        master-head (str/trim (:out (run {:dir root} "git" "rev-parse" "--short=10" "HEAD")))
        draft (fs/path wt "tmp" "from-wt.handoff")]
    (is (not= wt-head master-head))
    (write-file draft (format "type: git_handoff\nto: receiver\npriority: 50\ntask: task-from-worktree\ncommit: %s\n" wt-head))
    (let [result (run {:dir wt :env {"SWARMFORGE_ROLE" "sender"}}
                      (script "swarm_handoff.sh") (str draft))
          queued (-> (:out result) str/trim (str/replace #"^HANDOFF QUEUED: " ""))
          content (read-file queued)
          outbox (str (fs/canonicalize (fs/path root ".swarmforge" "handoffs" "outbox")))]
      (is (zero? (:exit result)))
      (is (str/starts-with? (str (fs/canonicalize queued)) outbox))
      (is (not (str/includes? queued "/.worktrees/")))
      (is (str/includes? content (str "commit: " wt-head "\n")))
      (is (not (str/includes? content (str "commit: " master-head "\n")))))))

(deftest swarm-handoff-infers-role-and-fills-worktree-head
  ;; Given a sender worktree and no SWARMFORGE_ROLE
  ;; When swarm_handoff runs there with a draft that names master's SHA or omits commit
  ;; Then it infers the role and queues the worktree HEAD
  (let [root (tmp-dir)
        _ (init-repo! root)
        wt (add-worktree! root "sender")
        _ (setup-project! root {"sender" "task" "receiver" "task"})
        _ (write-file (fs/path root ".swarmforge" "roles.tsv")
                      (format "sender\tsender\t%s\tsession\tSender\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\ttask\n"
                              wt root))
        _ (write-file (fs/path wt "slice.md") "from the worktree\n")
        _ (run {:dir wt} "git" "add" "slice.md")
        _ (run {:dir wt} "git" "commit" "-q" "-m" "Worktree slice")
        wt-head (str/trim (:out (run {:dir wt} "git" "rev-parse" "--short=10" "HEAD")))
        master-head (str/trim (:out (run {:dir root} "git" "rev-parse" "--short=10" "HEAD")))]
    (is (not= wt-head master-head))
    (testing "infers role from worktree when env is missing"
      (let [draft (fs/path wt "tmp" "no-env.handoff")]
        (write-file draft (format "type: git_handoff\nto: receiver\npriority: 50\ntask: inferred-role\ncommit: %s\n" wt-head))
        (let [result (run {:dir wt :ok? false}
                          (script "swarm_handoff.sh") (str draft))
              queued (-> (:out result) str/trim (str/replace #"^HANDOFF QUEUED: " ""))
              content (when (zero? (:exit result)) (read-file queued))]
          (is (zero? (:exit result)))
          (is (str/includes? (str content) "from: sender\n"))
          (is (str/includes? (str content) (str "commit: " wt-head "\n"))))))
    (testing "fills worktree HEAD even when the draft names master's SHA"
      (let [draft (fs/path wt "tmp" "wrong-sha.handoff")]
        (write-file draft (format "type: git_handoff\nto: receiver\npriority: 50\ntask: ignore-typed-sha\ncommit: %s\n" master-head))
        (let [result (run {:dir wt :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                          (script "swarm_handoff.sh") (str draft))
              queued (-> (:out result) str/trim (str/replace #"^HANDOFF QUEUED: " ""))
              content (when (zero? (:exit result)) (read-file queued))]
          (is (zero? (:exit result)))
          (is (str/includes? (str content) (str "commit: " wt-head "\n")))
          (is (not (str/includes? (str content) (str "commit: " master-head "\n")))))))
    (testing "fills HEAD when the draft omits commit"
      (let [draft (fs/path wt "tmp" "no-commit.handoff")]
        (write-file draft "type: git_handoff\nto: receiver\npriority: 50\ntask: omit-commit\n")
        (let [result (run {:dir wt :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                          (script "swarm_handoff.sh") (str draft))
              queued (-> (:out result) str/trim (str/replace #"^HANDOFF QUEUED: " ""))
              content (when (zero? (:exit result)) (read-file queued))]
          (is (zero? (:exit result)))
          (is (str/includes? (str content) (str "commit: " wt-head "\n"))))))))

(deftest swarm-handoff-rejects-drafts-outside-worktree-tmp
  ;; Given a git_handoff draft
  ;; When it lives in /tmp or the handoff outbox tmp
  ;; Then swarm_handoff refuses it and asks for ./tmp/ in the worktree
  (let [root (tmp-dir)
        commit (init-repo! root)]
    (setup-project! root)
    (testing "rejects a draft in /tmp"
      (let [draft (fs/path "/tmp" (str "swarmforge-bad-draft-" (System/currentTimeMillis) ".handoff"))]
        (try
          (write-file draft (format "type: git_handoff\nto: receiver\npriority: 50\ntask: scratch-tmp\ncommit: %s\n" commit))
          (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                            (script "swarm_handoff.sh") (str draft))]
            (is (= 1 (:exit result)))
            (is (str/includes? (str (:err result) (:out result)) "./tmp/"))
            (is (fs/exists? draft)))
          (finally
            (fs/delete-if-exists draft)))))
    (testing "rejects a draft in the handoff outbox tmp"
      (let [draft (fs/path root ".swarmforge/handoffs/outbox/tmp/htw-console-app-coder.draft")]
        (write-file draft (format "type: git_handoff\nto: receiver\npriority: 50\ntask: outbox-scratch\ncommit: %s\n" commit))
        (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                          (script "swarm_handoff.sh") (str draft))]
          (is (= 1 (:exit result)))
          (is (str/includes? (str (:err result) (:out result)) "./tmp/"))
          (is (fs/exists? draft)))))))

(deftest swarm-handoff-validates-and-queues-git-handoffs
  (let [root (tmp-dir)
        commit (init-repo! root)]
    (setup-project! root)
    (testing "git_handoff requires a task name"
      (let [draft (fs/path root "tmp" "missing-task.handoff")]
        (write-file draft (format "type: git_handoff\nto: receiver\npriority: 50\ncommit: %s\n" commit))
        (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                          (script "swarm_handoff.sh") (str draft))]
          (is (= 2 (:exit result)))
          (is (str/includes? (:err result) "Missing required header 'task'"))
          (is (fs/exists? draft)))))
    (testing "valid git_handoff writes task, canonical commit, and generated payload"
      (let [draft (fs/path root "tmp" "valid.handoff")]
        (write-file draft (format "type: git_handoff\nto: receiver\npriority: 50\ntask: task-1-cave-setup\ncommit: %s\n" commit))
        (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"}}
                          (script "swarm_handoff.sh") (str draft))
              queued (-> (:out result) str/trim (str/replace #"^HANDOFF QUEUED: " ""))
              content (read-file queued)]
          (is (str/includes? content "task: task-1-cave-setup\n"))
          (is (str/includes? content (str "commit: " commit "\n")))
          (is (str/includes? content "artifacts: README.md\n"))
          (is (str/includes? content (str "merge_and_process.sh sender " commit)))
          (is (fs/exists? queued))
          (is (not (fs/exists? draft))))))))

(deftest ready-for-next-prints-note-task-name-and-body
  ;; Given a (New Task) note in the receiver inbox
  ;; When ready_for_next runs
  ;; Then it prints TASK_NAME and the card body
  (let [root (tmp-dir)]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (make-queued-handoff! root "50_20260615T000001Z_000001_from_New_Task_to_receiver.handoff"
                          {:id "20260615T000001Z_000001_from_New_Task"
                           :from "(New Task)"
                           :type "note"
                           :task "Holy Hand Grenade"
                           :body "The grenade is placed at setup.\n"})
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "receiver"}}
                      (script "ready_for_next.sh"))
          out (:out result)]
      (is (zero? (:exit result)))
      (is (str/includes? out "FROM: (New Task)"))
      (is (str/includes? out "TYPE: note"))
      (is (str/includes? out "TASK_NAME: Holy Hand Grenade"))
      (is (str/includes? out "The grenade is placed at setup.")))))

(deftest ready-for-next-task-accepts-and-resumes-single-tasks
  (let [root (tmp-dir)]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (testing "accepts one queued task and prints task name"
      (make-queued-handoff! root "50_20260615T000001Z_000001_from_sender_to_receiver.handoff"
                            {:id "20260615T000001Z_000001_from_sender"
                             :task "task-alpha"})
      (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "receiver"}}
                        (script "ready_for_next.sh"))
            out (:out result)
            in-process (fs/path root ".swarmforge/handoffs/inbox/in_process/50_20260615T000001Z_000001_from_sender_to_receiver.handoff")]
        (is (str/includes? out "TASK:"))
        (is (str/includes? out "TASK_NAME: task-alpha"))
        (is (fs/exists? in-process))
        (is (some? (header in-process "dequeued_at")))))
    (testing "returns existing in-process task before queued tasks"
      (make-queued-handoff! root "40_20260615T000002Z_000002_from_sender_to_receiver.handoff"
                            {:id "20260615T000002Z_000002_from_sender"
                             :priority "40"
                             :task "task-beta"})
      (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "receiver"}}
                        (script "ready_for_next.sh"))]
        (is (str/includes? (:out result) "task-alpha"))
        (is (fs/exists? (fs/path root ".swarmforge/handoffs/inbox/new/40_20260615T000002Z_000002_from_sender_to_receiver.handoff")))))))

(deftest ready-for-next-batch-groups-equal-priority-handoffs
  (let [root (tmp-dir)]
    (init-repo! root)
    (setup-project! root {"receiver" "batch"})
    (make-queued-handoff! root "10_20260615T000001Z_000001_from_sender_to_receiver.handoff"
                          {:id "20260615T000001Z_000001_from_sender" :priority "10" :task "task-a"})
    (make-queued-handoff! root "10_20260615T000002Z_000002_from_sender_to_receiver.handoff"
                          {:id "20260615T000002Z_000002_from_sender" :priority "10" :task "task-b"})
    (make-queued-handoff! root "20_20260615T000003Z_000003_from_sender_to_receiver.handoff"
                          {:id "20260615T000003Z_000003_from_sender" :priority "20" :task "task-c"})
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "receiver"}}
                      (script "ready_for_next.sh"))
          out (:out result)
          batch-dir (->> (str/split-lines out)
                         (filter #(str/starts-with? % "BATCH: "))
                         first
                         (#(subs % 7)))]
      (is (str/includes? out "COUNT: 2"))
      (is (str/includes? out "TASK_NAME: task-a"))
      (is (str/includes? out "TASK_NAME: task-b"))
      (is (not (str/includes? out "TASK_NAME: task-c")))
      (let [lines (str/split-lines out)
            batch-i (first (keep-indexed (fn [i line] (when (str/starts-with? line "BATCH:") i)) lines))
            name-i (first (keep-indexed (fn [i line] (when (str/starts-with? line "TASK_NAME:") i)) lines))
            item-i (first (keep-indexed (fn [i line] (when (str/starts-with? line "BATCH_ITEM:") i)) lines))]
        (is (< batch-i name-i item-i))
        (is (= "TASK_NAME: task-a" (nth lines name-i))))
      (is (= 2 (count (fs/glob batch-dir "*.handoff"))))
      (is (fs/exists? (fs/path root ".swarmforge/handoffs/inbox/new/20_20260615T000003Z_000003_from_sender_to_receiver.handoff"))))))

(deftest done-with-current-task-completes-without-accepting-next
  ;; Given a current task and more mail in the inbox
  ;; When done_with_current runs
  ;; Then it completes the current task, leaves the next item queued, and prints MAIL_WAITING
  (let [root (tmp-dir)]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (put-handoff! root "in_process" "50_20260615T000001Z_000001_from_sender_to_receiver.handoff"
                  {:id "20260615T000001Z_000001_from_sender"
                   :from "sender" :to "receiver" :recipient "receiver"
                   :priority "50" :type "git_handoff" :task "task-current"
                   :commit (head-sha root)})
    (make-queued-handoff! root "50_20260615T000002Z_000002_from_sender_to_receiver.handoff"
                          {:id "20260615T000002Z_000002_from_sender"
                           :task "task-next"})
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "receiver"}}
                      (script "done_with_current.sh"))
          completed (fs/path root ".swarmforge/handoffs/inbox/completed/50_20260615T000001Z_000001_from_sender_to_receiver.handoff")
          next-file (fs/path root ".swarmforge/handoffs/inbox/new/50_20260615T000002Z_000002_from_sender_to_receiver.handoff")]
      (is (str/includes? (:out result) "COMPLETED:"))
      (is (str/includes? (:out result) "MAIL_WAITING"))
      (is (not (str/includes? (:out result) "TASK_NAME: task-next")))
      (is (some? (header completed "completed_at")))
      (is (fs/exists? next-file))
      (is (nil? (header next-file "dequeued_at"))))))

(deftest done-with-current-batch-completes-without-accepting-next
  ;; Given a current batch and more mail in the inbox
  ;; When done_with_current runs
  ;; Then it completes the batch, leaves the next item queued, and prints MAIL_WAITING
  (let [root (tmp-dir)
        batch (fs/path root ".swarmforge/handoffs/inbox/in_process/batch_20260615T000001Z_000001")]
    (init-repo! root)
    (setup-project! root {"receiver" "batch"})
    (fs/create-dirs batch)
    (write-file (fs/path batch "10_20260615T000001Z_000001_from_sender_to_receiver.handoff")
                (handoff {:id "20260615T000001Z_000001_from_sender"
                          :from "sender" :to "receiver" :recipient "receiver"
                          :priority "10" :type "git_handoff" :task "task-a"
                          :commit (head-sha root)}))
    (write-file (fs/path batch "10_20260615T000002Z_000002_from_sender_to_receiver.handoff")
                (handoff {:id "20260615T000002Z_000002_from_sender"
                          :from "sender" :to "receiver" :recipient "receiver"
                          :priority "10" :type "git_handoff" :task "task-b"
                          :commit (head-sha root)}))
    (make-queued-handoff! root "20_20260615T000003Z_000003_from_sender_to_receiver.handoff"
                          {:id "20260615T000003Z_000003_from_sender"
                           :priority "20"
                           :task "task-c"})
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "receiver"}}
                      (script "done_with_current.sh"))
          completed-batch (fs/path root ".swarmforge/handoffs/inbox/completed/batch_20260615T000001Z_000001")
          next-file (fs/path root ".swarmforge/handoffs/inbox/new/20_20260615T000003Z_000003_from_sender_to_receiver.handoff")]
      (is (str/includes? (:out result) "COMPLETED_BATCH:"))
      (is (str/includes? (:out result) "MAIL_WAITING"))
      (is (not (str/includes? (:out result) "TASK_NAME: task-c")))
      (is (= 2 (count (fs/glob completed-batch "*.handoff"))))
      (is (every? #(some? (header % "completed_at"))
                  (fs/glob completed-batch "*.handoff")))
      (is (fs/exists? next-file)))))

(deftest stop-handoff-daemon-stops-running-process-and-removes-pid-file
  (let [root (tmp-dir)]
    (init-repo! root)
    (fs/create-dirs (fs/path root ".swarmforge/daemon"))
    (write-file (fs/path root ".swarmforge/roles.tsv")
                (str "coder\tmaster\t" root "\tsession\tCoder\tcodex\ttask\n"))
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (run {:dir root :ok? false}
         "sh" "-c"
         (str "bb " (script "handoffd.bb") " " root " >/dev/null 2>&1 &"))
    (Thread/sleep 1500)
    (let [pid-file (fs/path root ".swarmforge/daemon/handoffd.pid")]
      (is (fs/exists? pid-file))
      (let [pid (str/trim (read-file pid-file))
            stop (run {:dir root} (script "stop_handoff_daemon.bb") (str root))]
        (is (= 0 (:exit stop)))
        (Thread/sleep 300)
        (is (not (fs/exists? pid-file)))
        (is (not= 0 (:exit (run {:dir root :ok? false} "kill" "-0" pid))))))))

(deftest swarm-handoff-fills-artifacts-from-the-commit
  ;; Given a git_handoff of a commit that added a file
  ;; When it is queued
  ;; Then artifacts lists that file
  (let [root (tmp-dir)
        _ (init-repo! root)
        _ (setup-project! root)
        _ (write-file (fs/path root "slice.md") "work\n")
        _ (run {:dir root} "git" "add" "slice.md")
        _ (run {:dir root} "git" "commit" "-q" "-m" "Add slice")
        draft (fs/path root "tmp" "with-files.handoff")]
    (write-file draft "type: git_handoff\nto: receiver\npriority: 50\ntask: fill-artifacts\n")
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"}}
                      (script "swarm_handoff.sh") (str draft))
          queued (-> (:out result) str/trim (str/replace #"^HANDOFF QUEUED: " ""))
          content (read-file queued)]
      (is (zero? (:exit result)))
      (is (str/includes? content "artifacts: slice.md\n"))
      (is (not (str/includes? content "artifacts: none"))))))

(deftest swarm-handoff-refuses-a-merge-with-no-changed-files
  ;; Given HEAD is a merge whose first-parent diff is empty
  ;; When swarm_handoff queues a git_handoff
  ;; Then it refuses and does not write artifacts: none
  (let [root (tmp-dir)
        _ (init-repo! root)
        _ (setup-project! root)
        _ (run {:dir root} "git" "checkout" "-q" "-b" "side")
        _ (write-file (fs/path root "side.md") "side\n")
        _ (run {:dir root} "git" "add" "side.md")
        _ (run {:dir root} "git" "commit" "-q" "-m" "Side")
        _ (run {:dir root} "git" "checkout" "-q" "master")
        _ (run {:dir root} "git" "merge" "-q" "--no-ff" "-s" "ours" "-m" "Ours" "side")
        draft (fs/path root "tmp" "merge.handoff")]
    (write-file draft "type: git_handoff\nto: receiver\npriority: 50\ntask: merge-empty\n")
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                      (script "swarm_handoff.sh") (str draft))
          outbox (fs/path root ".swarmforge" "handoffs" "outbox")
          queued (when (fs/exists? outbox) (fs/glob outbox "*.handoff"))]
      (is (not (zero? (:exit result))))
      (is (str/includes? (str (:err result) (:out result)) "no changed files"))
      (is (not (str/includes? (str (:err result) (:out result)) "artifacts: none")))
      (is (empty? queued))
      (is (fs/exists? draft)))))

(deftest receive-and-complete-infer-role-from-worktree
  ;; Given a receiver worktree and no SWARMFORGE_ROLE
  ;; When ready_for_next then done_with_current run there
  ;; Then they infer the role and accept / complete the task
  (let [root (tmp-dir)
        _ (init-repo! root)
        wt (add-worktree! root "receiver")
        _ (setup-project! root {"receiver" "task"})
        _ (write-file (fs/path root ".swarmforge" "roles.tsv")
                      (format "sender\tsender\t%s\tsession\tSender\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\ttask\n"
                              root wt))]
    (doseq [dir [".swarmforge/handoffs/outbox/tmp"
                 ".swarmforge/handoffs/sent"
                 ".swarmforge/handoffs/failed"
                 ".swarmforge/handoffs/inbox/new"
                 ".swarmforge/handoffs/inbox/in_process"
                 ".swarmforge/handoffs/inbox/completed"]]
      (fs/create-dirs (fs/path wt dir)))
    (make-queued-handoff! wt "50_20260615T000001Z_000001_from_sender_to_receiver.handoff"
                          {:id "20260615T000001Z_000001_from_sender"
                           :task "task-inferred"})
    (let [lib (run {:dir wt :ok? false} (script "handoff_lib.bb") "role")
          ready (run {:dir wt :ok? false} (script "ready_for_next.sh"))
          done (run {:dir wt :ok? false} (script "done_with_current.sh"))]
      (is (zero? (:exit lib)))
      (is (= "receiver" (str/trim (:out lib))))
      (is (zero? (:exit ready)))
      (is (str/includes? (:out ready) "TASK_NAME: task-inferred"))
      (is (zero? (:exit done)))
      (is (str/includes? (:out done) "COMPLETED:"))
      (is (str/includes? (:out done) "NO_TASK")))))

(deftest merge-and-process-merges-the-inbound-commit
  ;; Given a receiver worktree behind a sender commit
  ;; When merge_and_process runs with that sender and SHA
  ;; Then the receiver HEAD contains the commit
  (let [root (tmp-dir)
        _ (init-repo! root)
        sender (add-worktree! root "sender")
        receiver (add-worktree! root "receiver")
        _ (setup-project! root)
        _ (write-file (fs/path root ".swarmforge" "roles.tsv")
                      (format "sender\tsender\t%s\tsession\tSender\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\ttask\n"
                              sender receiver))
        _ (write-file (fs/path sender "slice.md") "from sender\n")
        _ (run {:dir sender} "git" "add" "slice.md")
        _ (run {:dir sender} "git" "commit" "-q" "-m" "Sender slice")
        sha (str/trim (:out (run {:dir sender} "git" "rev-parse" "--short=10" "HEAD")))
        result (run {:dir receiver :ok? false}
                    (script "merge_and_process.sh") "sender" sha)
        merged? (run {:dir receiver :ok? false}
                     "git" "merge-base" "--is-ancestor" sha "HEAD")]
    (is (zero? (:exit result)))
    (is (str/includes? (str (:out result) (:err result)) "MERGED:"))
    (is (zero? (:exit merged?)))
    (is (fs/exists? (fs/path receiver "slice.md")))))

(deftest ready-for-next-merges-an-inbound-git-handoff
  ;; Given a receiver worktree with a queued git_handoff
  ;; When ready_for_next runs
  ;; Then it merges that commit; the agent does not run git merge
  (let [root (tmp-dir)
        _ (init-repo! root)
        sender (add-worktree! root "sender")
        receiver (add-worktree! root "receiver")
        _ (setup-project! root)
        _ (write-file (fs/path root ".swarmforge" "roles.tsv")
                      (format "sender\tsender\t%s\tsession\tSender\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\ttask\n"
                              sender receiver))
        _ (write-file (fs/path sender "slice.md") "from sender\n")
        _ (run {:dir sender} "git" "add" "slice.md")
        _ (run {:dir sender} "git" "commit" "-q" "-m" "Sender slice")
        sha (str/trim (:out (run {:dir sender} "git" "rev-parse" "--short=10" "HEAD")))]
    (doseq [dir [".swarmforge/handoffs/inbox/new"
                 ".swarmforge/handoffs/inbox/in_process"
                 ".swarmforge/handoffs/inbox/completed"]]
      (fs/create-dirs (fs/path receiver dir)))
    (make-queued-handoff! receiver "50_20260615T000001Z_000001_from_sender_to_receiver.handoff"
                          {:id "20260615T000001Z_000001_from_sender"
                           :from "sender"
                           :to "receiver"
                           :commit sha
                           :task "merge-on-receive"
                           :body (str "merge_and_process sender " sha)})
    (let [ready (run {:dir receiver :env {"SWARMFORGE_ROLE" "receiver"} :ok? false}
                     (script "ready_for_next.sh"))
          merged? (run {:dir receiver :ok? false}
                       "git" "merge-base" "--is-ancestor" sha "HEAD")]
      (is (zero? (:exit ready)))
      (is (str/includes? (:out ready) "TASK_NAME: merge-on-receive"))
      (is (zero? (:exit merged?)))
      (is (fs/exists? (fs/path receiver "slice.md"))))))

(deftest swarm-handoff-rejects-evidence-headers
  ;; Given a git draft with coverage: or a note with an extra header
  ;; When swarm_handoff validates it
  ;; Then the draft is invalid; notes stay type/to/priority/message
  (let [root (tmp-dir)
        _ (init-repo! root)
        _ (setup-project! root)]
    (testing "git_handoff with coverage: is invalid"
      (let [draft (fs/path root "tmp" "coverage.handoff")]
        (write-file draft "type: git_handoff\nto: receiver\npriority: 50\ntask: cave\ncoverage: 92\n")
        (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                          (script "swarm_handoff.sh") (str draft))]
          (is (= 2 (:exit result)))
          (is (str/includes? (:err result) "unknown header 'coverage'"))
          (is (fs/exists? draft)))))
    (testing "note extra headers are invalid"
      (let [draft (fs/path root "tmp" "note-extra.handoff")]
        (write-file draft "type: note\nto: receiver\npriority: 50\nmessage: hello\ncoverage: 92\n")
        (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                          (script "swarm_handoff.sh") (str draft))]
          (is (= 2 (:exit result)))
          (is (str/includes? (:err result) "unknown header 'coverage'"))
          (is (fs/exists? draft)))))
    (testing "note still accepts only type to priority message"
      (let [draft (fs/path root "tmp" "note-ok.handoff")]
        (write-file draft "type: note\nto: receiver\npriority: 50\nmessage: hello\n")
        (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                          (script "swarm_handoff.sh") (str draft))]
          (is (zero? (:exit result)))
          (is (str/includes? (:out result) "HANDOFF QUEUED:")))))))

(deftest swarm-handoff-fills-missing-or-invalid-priority
  ;; Given a git_handoff draft that omits priority, or writes priority: normal
  ;; When swarm_handoff queues it
  ;; Then the queued file has priority: 50
  (let [root (tmp-dir)
        _ (init-repo! root)
        _ (setup-project! root)
        _ (write-file (fs/path root "slice.md") "work\n")
        _ (run {:dir root} "git" "add" "slice.md")
        _ (run {:dir root} "git" "commit" "-q" "-m" "Add slice")]
    (testing "omitted priority becomes 50"
      (let [draft (fs/path root "tmp" "no-priority.handoff")]
        (write-file draft "type: git_handoff\nto: receiver\ntask: fill-priority\n")
        (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                          (script "swarm_handoff.sh") (str draft))
              queued (-> (:out result) str/trim (str/replace #"^HANDOFF QUEUED: " ""))
              content (when (zero? (:exit result)) (read-file queued))]
          (is (zero? (:exit result)))
          (is (str/includes? (str content) "priority: 50\n")))))
    (testing "priority: normal becomes 50"
      (let [draft (fs/path root "tmp" "word-priority.handoff")]
        (write-file draft "type: git_handoff\nto: receiver\npriority: normal\ntask: fill-priority-word\n")
        (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                          (script "swarm_handoff.sh") (str draft))
              queued (-> (:out result) str/trim (str/replace #"^HANDOFF QUEUED: " ""))
              content (when (zero? (:exit result)) (read-file queued))]
          (is (zero? (:exit result)))
          (is (str/includes? (str content) "priority: 50\n"))
          (is (not (str/includes? (str content) "priority: normal\n"))))))
    (testing "valid two-digit priority is kept"
      (let [draft (fs/path root "tmp" "keep-priority.handoff")]
        (write-file draft "type: git_handoff\nto: receiver\npriority: 00\ntask: keep-priority\n")
        (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                          (script "swarm_handoff.sh") (str draft))
              queued (-> (:out result) str/trim (str/replace #"^HANDOFF QUEUED: " ""))
              content (when (zero? (:exit result)) (read-file queued))]
          (is (zero? (:exit result)))
          (is (str/includes? (str content) "priority: 00\n")))))))

(deftest swarm-handoff-strips-extra-draft-payload
  ;; Given a git_handoff draft with prose after the headers
  ;; When swarm_handoff queues it
  ;; Then it is valid and the queued body is the helper payload, not the prose
  (let [root (tmp-dir)
        _ (init-repo! root)
        _ (setup-project! root)
        _ (write-file (fs/path root "slice.md") "work\n")
        _ (run {:dir root} "git" "add" "slice.md")
        _ (run {:dir root} "git" "commit" "-q" "-m" "Add slice")
        sha (str/trim (:out (run {:dir root} "git" "rev-parse" "--short=10" "HEAD")))
        draft (fs/path root "tmp" "with-payload.handoff")]
    (write-file draft (str "type: git_handoff\nto: receiver\npriority: 50\ntask: strip-payload\n\n"
                           "Please merge this and run the tests.\n"))
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                      (script "swarm_handoff.sh") (str draft))
          queued (-> (:out result) str/trim (str/replace #"^HANDOFF QUEUED: " ""))
          content (when (zero? (:exit result)) (read-file queued))]
      (is (zero? (:exit result)))
      (is (str/includes? (str content) (str "merge_and_process.sh sender " sha)))
      (is (not (str/includes? (str content) "Please merge this and run the tests."))))))

(deftest swarm-handoff-last-role-tags-git-handoff-non-forwarding
  ;; Given receiver is the last pack role
  ;; When it queues a git_handoff
  ;; Then the queued file has non-forwarding: true
  (let [root (tmp-dir)
        _ (init-repo! root)
        _ (setup-project! root)
        _ (write-file (fs/path root "slice.md") "work\n")
        _ (run {:dir root} "git" "add" "slice.md")
        _ (run {:dir root} "git" "commit" "-q" "-m" "Add slice")
        draft (fs/path root "tmp" "last-role.handoff")]
    (write-file draft "type: git_handoff\nto: sender\npriority: 00\ntask: HTW\n")
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "receiver"} :ok? false}
                      (script "swarm_handoff.sh") (str draft))
          queued (-> (:out result) str/trim (str/replace #"^HANDOFF QUEUED: " ""))
          content (when (zero? (:exit result)) (read-file queued))]
      (is (zero? (:exit result)))
      (is (str/includes? (str content) "non-forwarding: true\n")))))

(deftest swarm-handoff-non-last-role-does-not-tag-non-forwarding
  ;; Given sender is not the last pack role
  ;; When it queues a git_handoff
  ;; Then the queued file has no non-forwarding header
  (let [root (tmp-dir)
        _ (init-repo! root)
        _ (setup-project! root)
        _ (write-file (fs/path root "slice.md") "work\n")
        _ (run {:dir root} "git" "add" "slice.md")
        _ (run {:dir root} "git" "commit" "-q" "-m" "Add slice")
        draft (fs/path root "tmp" "mid-role.handoff")]
    (write-file draft "type: git_handoff\nto: receiver\npriority: 50\ntask: HTW\n")
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                      (script "swarm_handoff.sh") (str draft))
          queued (-> (:out result) str/trim (str/replace #"^HANDOFF QUEUED: " ""))
          content (when (zero? (:exit result)) (read-file queued))]
      (is (zero? (:exit result)))
      (is (not (str/includes? (str content) "non-forwarding:"))))))

(deftest swarm-handoff-refuses-git-handoff-when-inbound-is-non-forwarding
  ;; Given an in-process inbound git_handoff tagged non-forwarding
  ;; When swarm_handoff queues another git_handoff
  ;; Then it refuses
  (let [root (tmp-dir)
        _ (init-repo! root)
        _ (setup-project! root)
        _ (write-file (fs/path root "slice.md") "work\n")
        _ (run {:dir root} "git" "add" "slice.md")
        _ (run {:dir root} "git" "commit" "-q" "-m" "Add slice")
        inbound (fs/path root ".swarmforge/handoffs/inbox/in_process/00_from_architect.handoff")
        draft (fs/path root "tmp" "forward.handoff")]
    (write-file inbound (str "from: architect\nto: sender\npriority: 00\ntype: git_handoff\n"
                             "task: HTW\nnon-forwarding: true\n\nmerge\n"))
    (write-file draft "type: git_handoff\nto: receiver\npriority: 50\ntask: HTW\n")
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                      (script "swarm_handoff.sh") (str draft))]
      (is (not (zero? (:exit result))))
      (is (str/includes? (str (:err result) (:out result)) "non-forwarding"))
      (is (fs/exists? draft)))))

(deftest swarm-handoff-keeps-draft-task-that-names-a-lane-card
  ;; Given Command syntax and Holy Hand Grenade cards in the sender lane
  ;; When swarm_handoff queues a git_handoff with task: Holy Hand Grenade
  ;; Then the queued file keeps that task name
  (let [root (tmp-dir)
        _ (init-repo! root)
        _ (setup-project! root)
        _ (write-file (fs/path root ".swarmforge" "board" "tasks.tsv")
                      (str "Command syntax\tsender\t2026-06-15T00:00:00Z\t2026-06-15T00:00:00Z\n"
                           "Holy Hand Grenade\tsender\t2026-06-15T00:00:01Z\t2026-06-15T00:00:01Z\n"))
        _ (write-file (fs/path root "slice.md") "work\n")
        _ (run {:dir root} "git" "add" "slice.md")
        _ (run {:dir root} "git" "commit" "-q" "-m" "Add slice")
        draft (fs/path root "tmp" "hhg.handoff")]
    (write-file draft "type: git_handoff\nto: receiver\npriority: 50\ntask: Holy Hand Grenade\n")
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                      (script "swarm_handoff.sh") (str draft))
          queued (-> (:out result) str/trim (str/replace #"^HANDOFF QUEUED: " ""))
          content (when (zero? (:exit result)) (read-file queued))]
      (is (zero? (:exit result)))
      (is (str/includes? (str content) "task: Holy Hand Grenade\n"))
      (is (not (str/includes? (str content) "task: Command syntax\n"))))))

(deftest swarm-handoff-from-worktree-uses-master-outbox-when-roles-copied
  ;; Given a sender worktree with a copied roles.tsv
  ;; When swarm_handoff queues a git_handoff there
  ;; Then the file is on the master project outbox
  (let [root (tmp-dir)
        _ (init-repo! root)
        wt (add-worktree! root "sender")
        _ (setup-project! root {"sender" "task" "receiver" "task"})
        roles (format "sender\tsender\t%s\tsession\tSender\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\ttask\n"
                      wt root)
        _ (write-file (fs/path root ".swarmforge" "roles.tsv") roles)
        _ (write-file (fs/path wt ".swarmforge" "roles.tsv") roles)
        _ (write-file (fs/path wt "slice.md") "from the worktree\n")
        _ (run {:dir wt} "git" "add" "slice.md")
        _ (run {:dir wt} "git" "commit" "-q" "-m" "Worktree slice")
        draft (fs/path wt "tmp" "copied-roles.handoff")]
    (write-file draft "type: git_handoff\nto: receiver\npriority: 50\ntask: copied-roles\n")
    (let [result (run {:dir wt :env {"SWARMFORGE_ROLE" "sender"}}
                      (script "swarm_handoff.sh") (str draft))
          queued (-> (:out result) str/trim (str/replace #"^HANDOFF QUEUED: " ""))]
      (is (zero? (:exit result)))
      (is (str/starts-with? (str (fs/canonicalize queued))
                           (str (fs/canonicalize (fs/path root ".swarmforge" "handoffs" "outbox")))))
      (is (not (str/includes? queued "/.worktrees/"))))))

(deftest swarm-handoff-queues-a-merge-with-first-parent-files
  ;; Given HEAD is a merge that added a file versus the first parent
  ;; When swarm_handoff queues a git_handoff
  ;; Then it succeeds and artifacts lists that file
  (let [root (tmp-dir)
        _ (init-repo! root)
        _ (setup-project! root)
        _ (run {:dir root} "git" "checkout" "-q" "-b" "side")
        _ (write-file (fs/path root "side.md") "side\n")
        _ (run {:dir root} "git" "add" "side.md")
        _ (run {:dir root} "git" "commit" "-q" "-m" "Side")
        _ (run {:dir root} "git" "checkout" "-q" "master")
        _ (write-file (fs/path root "main.md") "main\n")
        _ (run {:dir root} "git" "add" "main.md")
        _ (run {:dir root} "git" "commit" "-q" "-m" "Main")
        _ (run {:dir root} "git" "merge" "-q" "--no-edit" "side")
        draft (fs/path root "tmp" "merge-files.handoff")]
    (write-file draft "type: git_handoff\nto: receiver\npriority: 50\ntask: merge-files\n")
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                      (script "swarm_handoff.sh") (str draft))
          queued (-> (:out result) str/trim (str/replace #"^HANDOFF QUEUED: " ""))
          content (when (zero? (:exit result)) (read-file queued))]
      (is (zero? (:exit result)))
      (is (str/includes? (str content) "artifacts:"))
      (is (str/includes? (str content) "side.md")))))

(deftest done-with-current-archives-the-completing-role-pane
  ;; Given a current task and a pane stub
  ;; When done_with_current runs
  ;; Then the completing role's session pane is archived
  (let [root (tmp-dir)]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (put-handoff! root "in_process" "50_20260615T000001Z_000001_from_sender_to_receiver.handoff"
                  {:id "20260615T000001Z_000001_from_sender"
                   :from "sender" :to "receiver" :recipient "receiver"
                   :priority "50" :type "git_handoff" :task "task-current"
                   :commit (head-sha root)})
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "receiver"
                                       "SWARMFORGE_PANE_STUB" "receiver pane\n"}}
                      (script "done_with_current.sh"))
          pane (fs/path root ".swarmforge/sessions/receiver/pane.txt")]
      (is (zero? (:exit result)))
      (is (fs/exists? pane))
      (is (= "receiver pane\n" (read-file pane))))))

(deftest swarm-handoff-uses-top-in-process-batch-task-name
  ;; Given an in-process batch whose first item is Command syntax, and HTW still in the sender lane
  ;; When swarm_handoff queues a git_handoff drafted as HTW
  ;; Then the queued file uses Command syntax
  (let [root (tmp-dir)
        _ (init-repo! root)
        _ (setup-project! root {"sender" "batch" "receiver" "task"})
        batch (fs/path root ".swarmforge/handoffs/inbox/in_process/batch_20260824T182225Z_000001")
        _ (fs/create-dirs batch)
        _ (write-file (fs/path batch "50_20260824T181141Z_000002_from_coder_to_sender.handoff")
                      (handoff {:id "20260824T181141Z_000002_from_coder"
                                :from "coder" :to "sender" :recipient "sender"
                                :priority "50" :type "git_handoff" :task "Command syntax"
                                :commit (head-sha root)}))
        _ (write-file (fs/path batch "50_20260824T181302Z_000003_from_coder_to_sender.handoff")
                      (handoff {:id "20260824T181302Z_000003_from_coder"
                                :from "coder" :to "sender" :recipient "sender"
                                :priority "50" :type "git_handoff" :task "validate"
                                :commit (head-sha root)}))
        _ (write-file (fs/path root ".swarmforge" "board" "tasks.tsv")
                      (str "HTW\tsender\t2026-08-24T18:05:33Z\t2026-08-24T18:05:33Z\n"
                           "Command syntax\tsender\t2026-08-24T18:06:05Z\t2026-08-24T18:06:05Z\n"
                           "validate\tsender\t2026-08-24T18:06:45Z\t2026-08-24T18:06:45Z\n"))
        _ (write-file (fs/path root "slice.md") "work\n")
        _ (run {:dir root} "git" "add" "slice.md")
        _ (run {:dir root} "git" "commit" "-q" "-m" "Add slice")
        draft (fs/path root "tmp" "htw.handoff")]
    (write-file draft "type: git_handoff\nto: receiver\npriority: 00\ntask: HTW\n")
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                      (script "swarm_handoff.sh") (str draft))
          queued (-> (:out result) str/trim (str/replace #"^HANDOFF QUEUED: " ""))
          content (when (zero? (:exit result)) (read-file queued))]
      (is (zero? (:exit result)))
      (is (str/includes? (str content) "task: Command syntax\n"))
      (is (not (str/includes? (str content) "task: HTW\n"))))))

(deftest helpers-refuse-wrong-current-work-shape
  (let [root (tmp-dir)
        batch (fs/path root ".swarmforge/handoffs/inbox/in_process/batch_20260615T000001Z_000001")]
    (init-repo! root)
    (setup-project! root {"receiver" "batch"})
    (fs/create-dirs batch)
    (write-file (fs/path batch "10_20260615T000001Z_000001_from_sender_to_receiver.handoff")
                (handoff {:id "20260615T000001Z_000001_from_sender"
                          :from "sender" :to "receiver" :recipient "receiver"
                          :priority "10" :type "git_handoff" :task "task-a"
                          :commit (head-sha root)}))
    (testing "task helpers refuse an in-process batch"
      (let [ready (run {:dir root :env {"SWARMFORGE_ROLE" "receiver"} :ok? false}
                       (script "ready_for_next_task.sh"))
            done (run {:dir root :env {"SWARMFORGE_ROLE" "receiver"} :ok? false}
                      (script "done_with_current_task.sh"))]
        (is (= 2 (:exit ready)))
        (is (str/includes? (:err ready) "TASK_IN_PROCESS_IS_BATCH"))
        (is (= 2 (:exit done)))
        (is (str/includes? (:err done) "CURRENT_WORK_IS_BATCH"))))))

(deftest handoffd-routes-every-tmux-call-through-the-argv-stub
  ;; Given a queued outbox handoff and SWARMFORGE_TMUX_STUB set
  ;; When the daemon runs one pass
  ;; Then no real tmux runs: the wake text lands in the stub file instead
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"sender" "task" "receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (write-file (fs/path root ".swarmforge/handoffs/outbox/50_20260101T000000Z_000001_from_sender_to_receiver.handoff")
                (handoff {:id "20260101T000000Z_000001_from_sender"
                          :from "sender" :to "receiver"
                          :priority "50" :type "message" :task "stub-seam"}))
    (run-handoffd-once! root argv-file)
    (let [argv (read-argv argv-file)]
      (is (= ["tmux" "-S" "/tmp/fake.sock" "send-keys" "-t" "session" "-l"
              "You have new handoff mail. If idle, run ready_for_next.sh."]
             (first argv))
          "the wake text send must be recorded, not executed"))))

(deftest handoffd-submits-a-codex-wake-with-a-raw-carriage-return
  ;; Given a codex role receiving a handoff
  ;; When the daemon delivers it
  ;; Then Enter goes out as the raw byte 0d, not as the symbolic C-m/C-j that
  ;; tmux re-encodes for a TUI that negotiated extended keys
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"sender" "task" "receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (write-file (fs/path root ".swarmforge/handoffs/outbox/50_20260101T000000Z_000002_from_sender_to_receiver.handoff")
                (handoff {:id "20260101T000000Z_000002_from_sender"
                          :from "sender" :to "receiver"
                          :priority "50" :type "message" :task "codex-enter"}))
    (run-handoffd-once! root argv-file)
    (let [argv (read-argv argv-file)]
      (is (= ["tmux" "-S" "/tmp/fake.sock" "send-keys" "-t" "session" "-H" "0d"]
             (second argv)))
      (is (= 2 (count argv)) "raw CR replaces the C-m + C-j pair, so one submit call"))))

(deftest handoffd-submits-a-claude-wake-with-csi-u-enter
  ;; Given a claude role receiving a handoff
  ;; When the daemon delivers it
  ;; Then Enter stays CSI-u: claude negotiates the kitty keyboard protocol and
  ;; ignores a bare CR
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"sender" "task" "receiver" "task"})
    (write-file (fs/path root ".swarmforge/roles.tsv")
                (str "sender\tmaster\t" root "\tsession\tSender\tclaude\ttask\n"
                     "receiver\tmaster\t" root "\tsession\tReceiver\tclaude\ttask\n"))
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (write-file (fs/path root ".swarmforge/handoffs/outbox/50_20260101T000000Z_000003_from_sender_to_receiver.handoff")
                (handoff {:id "20260101T000000Z_000003_from_sender"
                          :from "sender" :to "receiver"
                          :priority "50" :type "message" :task "claude-enter"}))
    (run-handoffd-once! root argv-file)
    (is (= ["tmux" "-S" "/tmp/fake.sock" "send-keys" "-t" "session" "-H" "1b" "5b" "31" "33" "75"]
           (second (read-argv argv-file))))))

(defn entry-count
  "Entries in dir, or 0 when the dir was never created. fs/glob on a missing
  directory is not portable across babashka.fs versions."
  [dir]
  (if (fs/exists? dir) (count (fs/list-dir dir)) 0))

(defn stalled-handoff!
  "A handoff that has sat unclaimed in a recipient's inbox/new since 2026-01-01,
  i.e. far past every retry delay."
  [root filename id]
  (put-handoff! root "new" filename
                {:id id :from "sender" :to "receiver" :recipient "receiver"
                 :priority "50" :type "message" :task "stalled"
                 :enqueued-at "2026-01-01T00:00:00Z"}))

(deftest handoffd-rewakes-a-handoff-left-unclaimed-in-inbox-new
  ;; Given a handoff that has sat in inbox/new past the first retry delay
  ;; When the daemon runs one pass
  ;; Then it re-sends the same wake hint, because the file is the level: a
  ;; keystroke the TUI swallowed leaves no other trace
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (stalled-handoff! root "50_20260101T000000Z_000010_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000010_from_sender")
    (run-handoffd-once! root argv-file)
    (let [argv (read-argv argv-file)]
      (is (= ["tmux" "-S" "/tmp/fake.sock" "send-keys" "-t" "session" "-l"
              "You have new handoff mail. If idle, run ready_for_next.sh."]
             (first argv)))
      (is (= ["tmux" "-S" "/tmp/fake.sock" "send-keys" "-t" "session" "-H" "0d"]
             (second argv))))))

(deftest handoffd-does-not-rewake-a-handoff-already-claimed
  ;; Given the same old handoff, but already moved to in_process by ready_for_next
  ;; When the daemon runs one pass
  ;; Then no wake is sent: the move is the authoritative claim acknowledgement
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (put-handoff! root "in_process" "50_20260101T000000Z_000011_from_sender_to_receiver.handoff"
                  {:id "20260101T000000Z_000011_from_sender"
                   :from "sender" :to "receiver" :recipient "receiver"
                   :priority "50" :type "message" :task "claimed"
                   :enqueued-at "2026-01-01T00:00:00Z"})
    (run-handoffd-once! root argv-file)
    (is (= [] (read-argv argv-file)))))

(deftest handoffd-leaves-the-original-file-as-the-only-payload
  ;; Given an unclaimed handoff woken twice
  ;; When two daemon passes run
  ;; Then inbox/new still holds exactly that one file: a retry re-notifies, it
  ;; never re-queues, and notification failure must never look like new work
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")
        new-dir (fs/path root ".swarmforge/handoffs/inbox/new")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (stalled-handoff! root "50_20260101T000000Z_000012_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000012_from_sender")
    (run-handoffd-once! root argv-file)
    (run-handoffd-once! root argv-file)
    (is (= 1 (count (fs/glob new-dir "*.handoff"))))
    (is (= 0 (entry-count (fs/path root ".swarmforge/handoffs/inbox/failed"))))))

(deftest handoffd-skips-wake-retries-for-a-busy-role
  ;; Given a role already working one handoff and queuing a second
  ;; When the daemon runs one pass
  ;; Then no wake is sent: the queued file waits by design, and wake text
  ;; injected into a working agent corrupts its input line
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (put-handoff! root "in_process" "50_20260101T000000Z_000020_from_sender_to_receiver.handoff"
                  {:id "20260101T000000Z_000020_from_sender"
                   :from "sender" :to "receiver" :recipient "receiver"
                   :priority "50" :type "message" :task "working"
                   :enqueued-at "2026-01-01T00:00:00Z"})
    (stalled-handoff! root "50_20260101T000000Z_000021_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000021_from_sender")
    (run-handoffd-once! root argv-file)
    (is (= [] (read-argv argv-file)))))

(deftest handoffd-caps-wake-notifications-per-pass
  ;; Given three idle roles each holding one stalled handoff
  ;; When the daemon runs one pass
  ;; Then at most two are woken: poll-once! is single threaded, so an unbounded
  ;; retry backlog would push outbox->inbox delivery behind it
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"alpha" "task" "beta" "task" "gamma" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (doseq [[n role] [["30" "alpha"] ["31" "beta"] ["32" "gamma"]]]
      (put-handoff! root "new"
                    (str "50_20260101T000000Z_0000" n "_from_sender_to_" role ".handoff")
                    {:id (str "20260101T000000Z_0000" n "_from_sender")
                     :from "sender" :to role :recipient role
                     :priority "50" :type "message" :task "stalled"
                     :enqueued-at "2026-01-01T00:00:00Z"}))
    (run-handoffd-once! root argv-file)
    ;; two wakes, each recorded as one text send plus one submit key
    (is (= 4 (count (read-argv argv-file))))))

(deftest handoffd-keeps-unclaimed-work-in-inbox-new-when-the-wake-fails
  ;; Given a stalled handoff and a tmux socket with no server behind it, so the
  ;; real tmux call fails
  ;; When the daemon runs one pass with no stub
  ;; Then the file stays in inbox/new and nothing lands in failed/: a lost
  ;; notification is not invalid work
  (let [root (tmp-dir)
        new-dir (fs/path root ".swarmforge/handoffs/inbox/new")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket")
                (str (fs/path root "no-such.sock") "\n"))
    (stalled-handoff! root "50_20260101T000000Z_000040_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000040_from_sender")
    (run {:dir root} "bb" (script "handoffd.bb") "--once" (str root))
    (is (= 1 (count (fs/glob new-dir "*.handoff"))))
    (is (= 0 (entry-count (fs/path root ".swarmforge/handoffs/inbox/failed"))))
    (is (= 0 (entry-count (fs/path root ".swarmforge/handoffs/failed"))))
    (is (str/includes? (read-file (fs/path root ".swarmforge/daemon/handoffd.log"))
                       "wake-retry-failed"))))

(deftest handoffd-stops-waking-after-the-attempt-cap
  ;; Given a one-attempt cap and a 200ms retry interval
  ;; When the daemon runs long enough for several passes
  ;; Then it wakes once, logs wake-exhausted once, and leaves the file in place
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")
        log-file (fs/path root ".swarmforge/daemon/handoffd.log")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (stalled-handoff! root "50_20260101T000000Z_000041_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000041_from_sender")
    (run {:dir root :ok? false}
         "sh" "-c"
         (str "SWARMFORGE_TMUX_STUB=" argv-file
              " SWARMFORGE_WAKE_ATTEMPT_CAP=1 SWARMFORGE_WAKE_RETRY_MS=200"
              " bb " (script "handoffd.bb") " " root " >/dev/null 2>&1 &"))
    (Thread/sleep 3000)
    (run {:dir root} (script "stop_handoff_daemon.bb") (str root))
    (Thread/sleep 300)
    (let [log (read-file log-file)]
      (is (= 1 (count (re-seq #"wake-retry " log))))
      (is (= 1 (count (re-seq #"wake-exhausted " log))))
      (is (= 1 (count (fs/glob (fs/path root ".swarmforge/handoffs/inbox/new") "*.handoff")))))))

(deftest handoffd-keeps-retrying-an-old-handoff-past-the-first-wake
  ;; Given an old unclaimed handoff and the DEFAULT attempt cap (no
  ;; SWARMFORGE_WAKE_ATTEMPT_CAP override)
  ;; When the daemon runs long enough for several poll passes
  ;; Then it wakes more than once and never exhausts: a resume floor, not raw
  ;; elapsed age, sets the ladder position a restart or a busy-role delay
  ;; resumes at
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")
        log-file (fs/path root ".swarmforge/daemon/handoffd.log")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (stalled-handoff! root "50_20260101T000000Z_000042_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000042_from_sender")
    (run {:dir root :ok? false}
         "sh" "-c"
         (str "SWARMFORGE_TMUX_STUB=" argv-file
              " SWARMFORGE_WAKE_RETRY_MS=200"
              " bb " (script "handoffd.bb") " " root " >/dev/null 2>&1 &"))
    (Thread/sleep 3500)
    (run {:dir root} (script "stop_handoff_daemon.bb") (str root))
    (Thread/sleep 300)
    (let [log (read-file log-file)]
      (is (>= (count (re-seq #"wake-retry " log)) 2))
      (is (= 0 (count (re-seq #"wake-exhausted " log))))
      (is (= 1 (count (fs/glob (fs/path root ".swarmforge/handoffs/inbox/new") "*.handoff")))))))

(deftest handoffd-runs-the-alert-command-once-when-the-cap-is-spent
  ;; Given SWARMFORGE_ALERT_CMD, a one-attempt cap and a 200ms retry interval
  ;; When the daemon runs long enough for several passes past exhaustion
  ;; Then the command runs exactly once: the daemon log is audit, the alert is
  ;; delivery, and repeating it for the same handoff is noise a human learns to
  ;; ignore
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")
        alert-file (fs/path root "alert.log")
        log-file (fs/path root ".swarmforge/daemon/handoffd.log")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (stalled-handoff! root "50_20260101T000000Z_000050_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000050_from_sender")
    (run {:dir root :ok? false}
         "sh" "-c"
         (str "SWARMFORGE_TMUX_STUB=" argv-file
              " SWARMFORGE_WAKE_ATTEMPT_CAP=1 SWARMFORGE_WAKE_RETRY_MS=200"
              " SWARMFORGE_ALERT_CMD='echo \"$SWARMFORGE_ALERT_HANDOFF"
              " $SWARMFORGE_ALERT_ATTEMPTS\" >> " alert-file "'"
              " bb " (script "handoffd.bb") " " root " >/dev/null 2>&1 &"))
    (Thread/sleep 3000)
    (run {:dir root} (script "stop_handoff_daemon.bb") (str root))
    (Thread/sleep 300)
    (let [lines (if (fs/exists? alert-file)
                  (remove str/blank? (str/split-lines (read-file alert-file)))
                  [])]
      (is (= 1 (count lines)) "the alert fires once, not once per poll pass")
      (is (= "20260101T000000Z_000050_from_sender 1" (first lines))
          "the command sees the handoff id and attempt count"))
    (is (str/includes? (read-file log-file) "alert ")
        "the alert attempt is auditable in the daemon log")))

(deftest handoffd-survives-a-failing-alert-command
  ;; Given an alert command that exits non-zero
  ;; When the cap is spent
  ;; Then the daemon logs the failure and keeps running: a broken alert channel
  ;; must never stop delivery, and the work must not be quarantined
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")
        log-file (fs/path root ".swarmforge/daemon/handoffd.log")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (stalled-handoff! root "50_20260101T000000Z_000051_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000051_from_sender")
    (run {:dir root :ok? false}
         "sh" "-c"
         (str "SWARMFORGE_TMUX_STUB=" argv-file
              " SWARMFORGE_WAKE_ATTEMPT_CAP=1 SWARMFORGE_WAKE_RETRY_MS=200"
              " SWARMFORGE_ALERT_CMD='exit 7'"
              " bb " (script "handoffd.bb") " " root " >/dev/null 2>&1 &"))
    (Thread/sleep 3000)
    (run {:dir root} (script "stop_handoff_daemon.bb") (str root))
    (Thread/sleep 300)
    (let [log (read-file log-file)]
      (is (str/includes? log "alert ") "the failed attempt is still audited")
      (is (str/includes? log "exit=7") "the command's exit code is recorded")
      (is (= 1 (count (fs/glob (fs/path root ".swarmforge/handoffs/inbox/new") "*.handoff")))
          "unclaimed work stays in inbox/new")
      (is (= 0 (entry-count (fs/path root ".swarmforge/handoffs/inbox/failed")))
          "a failed alert never quarantines work"))))

(deftest ready-for-next-finds-the-role-inbox-from-any-directory
  ;; Given a receiver whose worktree is not the project root
  ;; When ready_for_next runs from the project root instead of that worktree
  ;; Then it still claims that role's work: the inbox belongs to the role, not to
  ;; whatever directory the agent happens to be standing in. A live swarm lost a
  ;; day to this - handoffd delivers by the worktree in roles.tsv while the agent
  ;; side resolved the inbox from its own cwd, so neither side reported anything
  ;; wrong and the chain simply stopped.
  (let [root (tmp-dir)
        _ (init-repo! root)
        wt (add-worktree! root "receiver")
        _ (setup-project! root {"receiver" "task"})
        _ (write-file (fs/path root ".swarmforge" "roles.tsv")
                      (format "sender\tsender\t%s\tsession\tSender\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\ttask\n"
                              root wt))]
    (doseq [dir [".swarmforge/handoffs/inbox/new"
                 ".swarmforge/handoffs/inbox/in_process"
                 ".swarmforge/handoffs/inbox/completed"]]
      (fs/create-dirs (fs/path wt dir)))
    (make-queued-handoff! wt "50_20260615T000009Z_000009_from_sender_to_receiver.handoff"
                          {:id "20260615T000009Z_000009_from_sender"
                           :task "task-from-elsewhere"})
    (let [ready (run {:dir root :env {"SWARMFORGE_ROLE" "receiver"} :ok? false}
                     (script "ready_for_next.sh"))]
      (is (zero? (:exit ready)))
      (is (str/includes? (:out ready) "TASK_NAME: task-from-elsewhere"))
      (is (= 0 (count (fs/glob (fs/path wt ".swarmforge/handoffs/inbox/new") "*.handoff")))
          "the role's queued file is claimed, not left sitting where the daemon put it")
      (is (= 1 (count (fs/glob (fs/path wt ".swarmforge/handoffs/inbox/in_process") "*.handoff")))))))

(deftest swarm-handoff-reads-the-non-forwarding-gate-from-the-role-worktree
  ;; Given a sender whose worktree is not the project root, holding a
  ;; non-forwarding inbound handoff there
  ;; When swarm_handoff runs from the project root and queues a git_handoff
  ;; Then the outbound gate still refuses: the inbox belongs to the role in
  ;; roles.tsv, not to the directory the process happens to start in. Resolving
  ;; it from the process cwd is the same two-sources-of-truth bug that stopped a
  ;; live swarm for a day, and it lets a terminal handoff be forwarded onward.
  (let [root (tmp-dir)
        _ (init-repo! root)
        wt (add-worktree! root "sender")
        _ (setup-project! root)
        _ (write-file (fs/path root ".swarmforge" "roles.tsv")
                      (format "sender\tsender\t%s\tsession\tSender\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\ttask\n"
                              wt root))
        _ (write-file (fs/path wt "slice.md") "work\n")
        _ (run {:dir wt} "git" "add" "slice.md")
        _ (run {:dir wt} "git" "commit" "-q" "-m" "Add slice")
        inbound (fs/path wt ".swarmforge/handoffs/inbox/in_process/00_from_architect.handoff")
        draft (fs/path wt "tmp" "forward.handoff")]
    (write-file inbound (str "from: architect\nto: sender\npriority: 00\ntype: git_handoff\n"
                             "task: HTW\nnon-forwarding: true\n\nmerge\n"))
    (write-file draft "type: git_handoff\nto: receiver\npriority: 50\ntask: HTW\n")
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                      (script "swarm_handoff.sh") (str draft))]
      (is (not (zero? (:exit result)))
          "the gate must see the inbound handoff in the role's worktree, not in cwd")
      (is (str/includes? (str (:err result) (:out result)) "non-forwarding")))))

(defn -main [& _]
  (let [{:keys [fail error]} (run-tests 'swarmforge.handoff-test)]
    (System/exit (+ fail error))))
