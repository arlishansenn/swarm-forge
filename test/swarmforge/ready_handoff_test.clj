(ns swarmforge.ready-handoff-test
  (:require [babashka.fs :as fs]
            [clojure.edn :as edn]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing use-fixtures]]
            [swarmforge.handoff-test-support :refer :all]))

(use-fixtures :once once-fixture)

(deftest pack-board-project-root-from-worktree-matches-handoff-lib
  (let [root (tmp-dir)
        _ (init-repo! root)
        wt (add-worktree! root "coder")
        _ (setup-project! root {"coder" "task"})
        _ (write-file (fs/path root ".swarmforge" "roles.tsv")
                      (format "coder\tmaster\t%s\tsession\tCoder\tcodex\ttask\n" wt))]
    (run {:dir root} (script "pack_board.sh") "create" "--name" "HTW" "--type" "utility" "--root" (str root))
    (let [from-lib (run {:dir wt} (script "handoff_lib.bb") "project-root")
          listed (run {:dir wt} (script "pack_board.sh") "list")]
      (is (= (str (fs/canonicalize root))
             (str (fs/canonicalize (str/trim (:out from-lib))))))
      (is (str/includes? (:out listed) "HTW")))))
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
(deftest ready-for-next-commits-operator-task-document-in-role-worktree
  (let [root (tmp-dir)
        _ (init-repo! root)
        receiver (add-worktree! root "receiver")
        document "# Utility task\n\nType: utility\n\nBuild the shim.\n"]
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/roles.tsv")
                (format "receiver\treceiver\t%s\tsession\tReceiver\tcodex\ttask\n"
                        receiver))
    (write-file (fs/path root "tasks/Utility task.md") document)
    (put-handoff! receiver "new" "50_utility.handoff"
                  {:id "utility"
                   :from "(New Task)"
                   :to "receiver"
                   :recipient "receiver"
                   :priority "50"
                   :type "note"
                   :task-id "utility-id"
                   :task "Utility task"
                   :body "Build the shim."})
    (let [result (run {:dir receiver :env {"SWARMFORGE_ROLE" "receiver"}}
                      (script "ready_for_next.sh"))
          committed (run {:dir receiver}
                         "git" "show" "HEAD:tasks/Utility task.md")]
      (is (zero? (:exit result)))
      (is (= document (read-file (fs/path receiver "tasks/Utility task.md"))))
      (is (= document (:out committed))))))
(deftest ready-for-next-batch-commits-each-operator-task-document
  (let [root (tmp-dir)
        _ (init-repo! root)
        receiver (add-worktree! root "receiver")]
    (setup-project! root {"receiver" "batch"})
    (write-file (fs/path root ".swarmforge/roles.tsv")
                (format "receiver\treceiver\t%s\tsession\tReceiver\tcodex\tbatch\n"
                        receiver))
    (doseq [[priority task] [["40" "First"] ["40" "Second"]]]
      (write-file (fs/path root "tasks" (str task ".md"))
                  (str "# " task "\n\nType: utility\n\nDo " task ".\n"))
      (put-handoff! receiver "new" (str priority "_" task ".handoff")
                    {:id task
                     :from "(New Task)"
                     :to "receiver"
                     :recipient "receiver"
                     :priority priority
                     :type "note"
                     :task-id (str task "-id")
                     :task task
                     :body (str "Do " task ".")}))
    (let [result (run {:dir receiver :env {"SWARMFORGE_ROLE" "receiver"}}
                      (script "ready_for_next.sh"))]
      (is (zero? (:exit result)))
      (is (str/includes? (:out result) "COUNT: 2"))
      (doseq [task ["First" "Second"]]
        (is (zero? (:exit (run {:dir receiver}
                               "git" "cat-file" "-e"
                               (str "HEAD:tasks/" task ".md")))))))))
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
(deftest ready-for-next-waits-while-outbound-approval-is-active
  ;; Given sender has an outbound git_handoff pending approval
  ;; When sender asks for another task
  ;; Then no new task is dequeued from the inbox
  (let [root (tmp-dir)]
    (init-repo! root)
    (setup-project! root)
    (write-file (fs/path root ".swarmforge/roles.tsv")
                (format "sender\tmaster\t%s\tsession\tSender\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\ttask\n"
                        root (fs/path root ".worktrees/receiver")))
    (write-file (fs/path root ".swarmforge/handoffs/pending_approval/50_pending.handoff")
                "from: sender\nto: receiver\npriority: 50\ntype: git_handoff\ntask_id: task-one\ntask: task-one\ncommit: 1234567890\n\npayload\n")
    (put-handoff! root "new" "50_next.handoff"
                  {:id "next"
                   :from "(New Task)"
                   :to "sender"
                   :recipient "sender"
                   :priority "50"
                   :type "note"
                   :task-id "task-two"
                   :task "task-two"
                   :body "next task"})
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                      (script "ready_for_next.sh"))]
      (is (= 2 (:exit result)))
      (is (str/includes? (:err result) "WAITING_FOR_APPROVAL"))
      (is (fs/exists? (fs/path root ".swarmforge/handoffs/inbox/new/50_next.handoff")))
      (is (empty? (fs/glob (fs/path root ".swarmforge/handoffs/inbox/in_process") "*.handoff"))))))
(deftest ready-for-next-waits-while-outbound-handoff-is-in-outbox
  ;; Given sender has queued a git_handoff that handoffd has not processed yet
  ;; When sender asks for another task
  ;; Then sender is still treated as busy
  (let [root (tmp-dir)]
    (init-repo! root)
    (setup-project! root)
    (write-file (fs/path root ".swarmforge/roles.tsv")
                (format "sender\tmaster\t%s\tsession\tSender\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\ttask\n"
                        root (fs/path root ".worktrees/receiver")))
    (write-file (fs/path root ".swarmforge/handoffs/outbox/50_outbound.handoff")
                "id: outbound\nfrom: sender\nto: receiver\npriority: 50\ntype: git_handoff\ntask_id: task-one\ntask: task-one\ncommit: 1234567890\n\npayload\n")
    (put-handoff! root "new" "50_next.handoff"
                  {:id "next"
                   :from "(New Task)"
                   :to "sender"
                   :recipient "sender"
                   :priority "50"
                   :type "note"
                   :task-id "task-two"
                   :task "task-two"
                   :body "next task"})
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                      (script "ready_for_next.sh"))]
      (is (= 2 (:exit result)))
      (is (str/includes? (:err result) "WAITING_FOR_APPROVAL"))
      (is (fs/exists? (fs/path root ".swarmforge/handoffs/inbox/new/50_next.handoff")))
      (is (empty? (fs/glob (fs/path root ".swarmforge/handoffs/inbox/in_process") "*.handoff"))))))
(deftest ready-for-next-starts-next-task-after-outbound-approval-delivered
  ;; Given sender's prior git_handoff is already approved and in receiver's process
  ;; When sender asks for another task
  ;; Then the next queued task starts
  (let [root (tmp-dir)
        receiver (fs/path root ".worktrees/receiver")]
    (init-repo! root)
    (fs/create-dirs receiver)
    (setup-project! root)
    (write-file (fs/path root ".swarmforge/roles.tsv")
                (format "sender\tmaster\t%s\tsession\tSender\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\ttask\n"
                        root receiver))
    (write-file (fs/path receiver ".swarmforge/handoffs/inbox/in_process/50_prior.handoff")
                "from: sender\nto: receiver\nrecipient: receiver\npriority: 50\ntype: git_handoff\ntask_id: task-one\ntask: task-one\ncommit: 1234567890\napproved: true\n\npayload\n")
    (put-handoff! root "new" "50_next.handoff"
                  {:id "next"
                   :from "(New Task)"
                   :to "sender"
                   :recipient "sender"
                   :priority "50"
                   :type "note"
                   :task-id "task-two"
                   :task "task-two"
                   :body "next task"})
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"}}
                      (script "ready_for_next.sh"))
          in-process (fs/path root ".swarmforge/handoffs/inbox/in_process/50_next.handoff")]
      (is (zero? (:exit result)))
      (is (str/includes? (:out result) "TASK_NAME: task-two"))
      (is (fs/exists? in-process))
      (is (not (fs/exists? (fs/path root ".swarmforge/handoffs/inbox/new/50_next.handoff")))))))
(deftest handoffd-wakes-sender-after-approved-handoff-unblocks-queued-work
  ;; Given an approved sender handoff is ready to deliver and sender has queued mail
  ;; When handoffd delivers the approved handoff to the receiver
  ;; Then the receiver and the now-unblocked sender are notified
  (let [root (tmp-dir)
        bin (fs/path root "bin")
        fake-tmux (fs/path bin "tmux")
        tmux-log (fs/path root "tmux.log")
        receiver (fs/path root ".worktrees/receiver")]
    (init-repo! root)
    (setup-project! root)
    (fs/create-dirs bin)
    (write-file fake-tmux
                (str "#!/usr/bin/env bb\n"
                     "(when-let [log (System/getenv \"TMUX_LOG\")]\n"
                     "  (spit log (str (pr-str *command-line-args*) \"\\n\") :append true))\n"))
    (run {:dir root} "chmod" "+x" (str fake-tmux))
    (write-file (fs/path root ".swarmforge/roles.tsv")
                (format "sender\tmaster\t%s\tsender-session\tSender\tcodex\ttask\nreceiver\treceiver\t%s\treceiver-session\tReceiver\tcodex\ttask\n"
                        root receiver))
    (fs/create-dirs receiver)
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (write-file (fs/path root ".swarmforge/handoffs/outbox/50_approved.handoff")
                "id: approved\nfrom: sender\nto: receiver\npriority: 50\ntype: git_handoff\ntask_id: task-one\ntask: task-one\ncommit: 1234567890\napproved: true\n\npayload\n")
    (put-handoff! root "new" "50_next.handoff"
                  {:id "next"
                   :from "(New Task)"
                   :to "sender"
                   :recipient "sender"
                   :priority "50"
                   :type "note"
                   :task-id "task-two"
                   :task "task-two"
                   :body "next task"})
    (let [result (run {:dir root
                       :env {"PATH" (str bin ":" (System/getenv "PATH"))
                             "TMUX_LOG" (str tmux-log)}}
                      "bb" (script "handoffd.bb") "--once" (str root))]
      (is (zero? (:exit result)))
      (is (fs/exists? (fs/path receiver ".swarmforge/handoffs/inbox/new/50_approved.handoff")))
      (is (fs/exists? (fs/path root ".swarmforge/handoffs/inbox/new/50_next.handoff")))
      (is (seq (submitted-texts (read-argv tmux-log) "receiver-session")))
      (is (seq (submitted-texts (read-argv tmux-log) "sender-session")))
      (is (str/includes? (read-file (fs/path root ".swarmforge/daemon/handoffd.log"))
                         "notified-unblocked-sender sender")))))
(deftest ready-for-next-batch-waits-while-outbound-approval-is-active
  ;; Given a batch-mode sender has an outbound git_handoff pending approval
  ;; When sender asks for the next batch
  ;; Then no batch is created from queued inbox work
  (let [root (tmp-dir)]
    (init-repo! root)
    (setup-project! root {"sender" "batch" "receiver" "task"})
    (write-file (fs/path root ".swarmforge/roles.tsv")
                (format "sender\tmaster\t%s\tsession\tSender\tcodex\tbatch\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\ttask\n"
                        root (fs/path root ".worktrees/receiver")))
    (write-file (fs/path root ".swarmforge/handoffs/pending_approval/50_pending.handoff")
                "from: sender\nto: receiver\npriority: 50\ntype: git_handoff\ntask_id: task-one\ntask: task-one\ncommit: 1234567890\n\npayload\n")
    (put-handoff! root "new" "50_next.handoff"
                  {:id "next"
                   :from "(New Task)"
                   :to "sender"
                   :recipient "sender"
                   :priority "50"
                   :type "note"
                   :task-id "task-two"
                   :task "task-two"
                   :body "next task"})
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"} :ok? false}
                      (script "ready_for_next.sh"))]
      (is (= 2 (:exit result)))
      (is (str/includes? (:err result) "WAITING_FOR_APPROVAL"))
      (is (fs/exists? (fs/path root ".swarmforge/handoffs/inbox/new/50_next.handoff")))
      (is (empty? (fs/glob (fs/path root ".swarmforge/handoffs/inbox/in_process") "batch_*"))))))
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

(deftest ready-for-next-batch-merges-only-the-ancestry-complete-commit
  (let [root (tmp-dir)
        _ (init-repo! root)
        sender (add-worktree! root "sender")
        receiver (add-worktree! root "receiver")
        _ (setup-project! root {"sender" "task" "receiver" "batch"})
        _ (write-file (fs/path root ".swarmforge/roles.tsv")
                      (format "sender\tsender\t%s\tsession\tSender\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\tbatch\n"
                              sender receiver))
        _ (write-file (fs/path sender "adaptive.md") "adaptive\n")
        _ (run {:dir sender} "git" "add" "adaptive.md")
        _ (run {:dir sender} "git" "commit" "-q" "-m" "Adaptive polling")
        adaptive (str/trim (:out (run {:dir sender} "git" "rev-parse" "HEAD")))
        _ (write-file (fs/path sender "tactical.md") "tactical\n")
        _ (run {:dir sender} "git" "add" "tactical.md")
        _ (run {:dir sender} "git" "commit" "-q" "-m" "Tactical persistence")
        tactical (str/trim (:out (run {:dir sender} "git" "rev-parse" "HEAD")))]
    (doseq [dir ["new" "in_process" "completed"]]
      (fs/create-dirs (fs/path receiver ".swarmforge/handoffs/inbox" dir)))
    (make-queued-handoff! receiver "50_adaptive.handoff"
                          {:id "adaptive" :from "sender" :to "receiver"
                           :recipient "receiver" :task-id "adaptive-id"
                           :task "adaptive-polling" :commit adaptive})
    (make-queued-handoff! receiver "50_tactical.handoff"
                          {:id "tactical" :from "sender" :to "receiver"
                           :recipient "receiver" :task-id "tactical-id"
                           :task "tactical-persistence" :commit tactical})
    (let [result (run {:dir receiver :env {"SWARMFORGE_ROLE" "receiver"}}
                      (script "ready_for_next.sh"))
          batch-dir (->> (str/split-lines (:out result))
                         (some #(when (str/starts-with? % "BATCH: ")
                                  (subs % (count "BATCH: ")))))
          manifest (edn/read-string
                    (read-file (fs/path batch-dir "batch_manifest.edn")))
          reflog (str/split-lines
                  (:out (run {:dir receiver} "git" "reflog" "--format=%gs")))]
      (is (= tactical (:selected-commit manifest)))
      (is (= [adaptive tactical] (mapv :commit (:members manifest))))
      (is (= tactical (str/trim (:out (run {:dir receiver} "git" "rev-parse" "HEAD")))))
      (is (= 1 (count (filter #(str/starts-with? % "merge ") reflog)))))))

(deftest ready-for-next-batch-rejects-non-linear-commits-before-dequeue
  (let [root (tmp-dir)
        base (init-repo! root)
        sender-a (add-worktree! root "sender-a")
        sender-b (add-worktree! root "sender-b")
        receiver (add-worktree! root "receiver")
        _ (setup-project! root {"sender-a" "task" "sender-b" "task" "receiver" "batch"})
        _ (write-file (fs/path root ".swarmforge/roles.tsv")
                      (format "sender-a\tsender-a\t%s\tsession\tA\tcodex\ttask\nsender-b\tsender-b\t%s\tsession\tB\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\tbatch\n"
                              sender-a sender-b receiver))
        _ (write-file (fs/path sender-a "a.md") "a\n")
        _ (run {:dir sender-a} "git" "add" "a.md")
        _ (run {:dir sender-a} "git" "commit" "-q" "-m" "A")
        a (head-sha sender-a)
        _ (write-file (fs/path sender-b "b.md") "b\n")
        _ (run {:dir sender-b} "git" "add" "b.md")
        _ (run {:dir sender-b} "git" "commit" "-q" "-m" "B")
        b (head-sha sender-b)]
    (doseq [dir ["new" "in_process" "completed"]]
      (fs/create-dirs (fs/path receiver ".swarmforge/handoffs/inbox" dir)))
    (make-queued-handoff! receiver "50_a.handoff"
                          {:id "a" :from "sender-a" :to "receiver" :recipient "receiver"
                           :task-id "a-id" :task "a" :commit a})
    (make-queued-handoff! receiver "50_b.handoff"
                          {:id "b" :from "sender-b" :to "receiver" :recipient "receiver"
                           :task-id "b-id" :task "b" :commit b})
    (let [result (run {:dir receiver :env {"SWARMFORGE_ROLE" "receiver"} :ok? false}
                      (script "ready_for_next.sh"))]
      (is (= 2 (:exit result)))
      (is (str/includes? (:err result) "NON_LINEAR_BATCH"))
      (is (= base (head-sha receiver)))
      (is (= 2 (count (fs/glob (fs/path receiver ".swarmforge/handoffs/inbox/new")
                               "*.handoff"))))
      (is (empty? (fs/glob (fs/path receiver ".swarmforge/handoffs/inbox/in_process")
                           "batch_*"))))))

(deftest ready-for-next-batch-declares-and-retains-complete-commit-on-conflict
  (let [root (tmp-dir)
        _ (init-repo! root)
        _ (write-file (fs/path root "shared.txt") "base\n")
        _ (run {:dir root} "git" "add" "shared.txt")
        _ (run {:dir root} "git" "commit" "-q" "-m" "Shared base")
        sender (add-worktree! root "sender")
        receiver (add-worktree! root "receiver")
        _ (setup-project! root {"sender" "task" "receiver" "batch"})
        _ (write-file (fs/path root ".swarmforge/roles.tsv")
                      (format "sender\tsender\t%s\tsession\tSender\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\tbatch\n"
                              sender receiver))
        _ (write-file (fs/path sender "shared.txt") "adaptive\n")
        _ (run {:dir sender} "git" "add" "shared.txt")
        _ (run {:dir sender} "git" "commit" "-q" "-m" "Adaptive polling")
        adaptive (head-sha sender)
        _ (write-file (fs/path sender "shared.txt") "adaptive and tactical\n")
        _ (run {:dir sender} "git" "add" "shared.txt")
        _ (run {:dir sender} "git" "commit" "-q" "-m" "Tactical persistence")
        tactical (str/trim (:out (run {:dir sender} "git" "rev-parse" "HEAD")))
        _ (write-file (fs/path receiver "shared.txt") "receiver structure\n")
        _ (run {:dir receiver} "git" "add" "shared.txt")
        _ (run {:dir receiver} "git" "commit" "-q" "-m" "Receiver structure")]
    (doseq [dir ["new" "in_process" "completed"]]
      (fs/create-dirs (fs/path receiver ".swarmforge/handoffs/inbox" dir)))
    (make-queued-handoff! receiver "50_adaptive.handoff"
                          {:id "adaptive" :from "sender" :to "receiver" :recipient "receiver"
                           :task-id "adaptive-id" :task "adaptive-polling" :commit adaptive})
    (make-queued-handoff! receiver "50_tactical.handoff"
                          {:id "tactical" :from "sender" :to "receiver" :recipient "receiver"
                           :task-id "tactical-id" :task "tactical-persistence" :commit tactical})
    (let [first-result (run {:dir receiver :env {"SWARMFORGE_ROLE" "receiver"} :ok? false}
                            (script "ready_for_next.sh"))
          batch-dir (->> (str/split-lines (:out first-result))
                         (some #(when (str/starts-with? % "BATCH: ")
                                  (subs % (count "BATCH: ")))))
          manifest (edn/read-string
                    (read-file (fs/path batch-dir "batch_manifest.edn")))
          merge-head (str/trim (:out (run {:dir receiver} "git" "rev-parse" "MERGE_HEAD")))
          resumed (run {:dir receiver :env {"SWARMFORGE_ROLE" "receiver"} :ok? false}
                       (script "ready_for_next.sh"))]
      (is (= 1 (:exit first-result)))
      (is (some? batch-dir))
      (is (str/includes? (:out first-result)
                         (str "SELECTED_COMMIT: " (subs tactical 0 10))))
      (is (= 2 (count (filter #(str/starts-with? % "BATCH_MEMBER: ")
                              (str/split-lines (:out first-result))))))
      (is (= tactical (:selected-commit manifest)))
      (is (= tactical merge-head))
      (is (str/includes? (:out resumed) (str "BATCH_ID: " (:batch-id manifest))))
      (is (fs/regular-file? (fs/path batch-dir "batch_manifest.edn"))))))
(deftest ready-for-next-batch-keeps-same-priority-of-one-card-type
  (let [root (tmp-dir)]
    (init-repo! root)
    (setup-project! root {"receiver" "batch"})
    (make-queued-handoff! root "50_20260615T000001Z_000001_from_sender_to_receiver.handoff"
                          {:id "20260615T000001Z_000001_from_sender"
                           :priority "50" :task "jump" :card-type "component"})
    (make-queued-handoff! root "50_20260615T000002Z_000002_from_sender_to_receiver.handoff"
                          {:id "20260615T000002Z_000002_from_sender"
                           :priority "50" :task "input" :card-type "QA"})
    (make-queued-handoff! root "50_20260615T000003Z_000003_from_sender_to_receiver.handoff"
                          {:id "20260615T000003Z_000003_from_sender"
                           :priority "50" :task "hhg" :card-type "component"})
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "receiver"}}
                      (script "ready_for_next.sh"))
          out (:out result)
          batch-dir (->> (str/split-lines out)
                         (filter #(str/starts-with? % "BATCH: "))
                         first
                         (#(subs % 7)))]
      (is (str/includes? out "COUNT: 2"))
      (is (str/includes? out "TASK_NAME: jump"))
      (is (str/includes? out "TASK_NAME: hhg"))
      (is (not (str/includes? out "TASK_NAME: input")))
      (is (= 2 (count (fs/glob batch-dir "*.handoff"))))
      (is (fs/exists? (fs/path root ".swarmforge/handoffs/inbox/new/50_20260615T000002Z_000002_from_sender_to_receiver.handoff"))))))
(deftest ready-for-next-batch-does-not-mix-reverse-with-forward
  (let [root (tmp-dir)]
    (init-repo! root)
    (setup-project! root {"receiver" "batch"})
    (make-queued-handoff! root "50_20260615T000001Z_000001_from_sender_to_receiver.handoff"
                          {:id "20260615T000001Z_000001_from_sender"
                           :priority "50" :task "domain" :card-type "component"
                           :non-forwarding true})
    (make-queued-handoff! root "50_20260615T000002Z_000002_from_sender_to_receiver.handoff"
                          {:id "20260615T000002Z_000002_from_sender"
                           :priority "50" :task "jump" :card-type "component"})
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "receiver"}}
                      (script "ready_for_next.sh"))
          out (:out result)
          batch-dir (->> (str/split-lines out)
                         (filter #(str/starts-with? % "BATCH: "))
                         first
                         (#(subs % 7)))]
      (is (str/includes? out "COUNT: 1"))
      (is (str/includes? out "TASK_NAME: domain"))
      (is (not (str/includes? out "TASK_NAME: jump")))
      (is (= 1 (count (fs/glob batch-dir "*.handoff"))))
      (is (fs/exists? (fs/path root ".swarmforge/handoffs/inbox/new/50_20260615T000002Z_000002_from_sender_to_receiver.handoff"))))))
(deftest ready-for-next-task-prints-card-type-and-this-card
  (let [root (tmp-dir)]
    (init-repo! root)
    (setup-project! root [["specifier" "task" "forward-only"]
                          ["coder" "task" "forward-only"]
                          ["cleaner" "task" "back-one"]
                          ["architect" "batch" "back-all"]
                          ["hardender" "batch" "forward-only"]
                          ["QA" "batch" "back-all"]])
    (pack-board root true "create" "--root" (str root)
                "--name" "jump" "--type" "component")
    (make-queued-handoff! root "50_20260615T000001Z_000001_from_New_Task_to_specifier.handoff"
                          {:id "20260615T000001Z_000001_from_New_Task"
                           :from "(New Task)"
                           :to "specifier"
                           :recipient "specifier"
                           :priority "50"
                           :type "note"
                           :task "jump"
                           :card-type "component"
                           :body "Specify jump.\n"})
    (let [out (:out (run {:dir root :env {"SWARMFORGE_ROLE" "specifier"}}
                         (script "ready_for_next.sh")))]
      (is (str/includes? out "CARD_TYPE: component"))
      (is (str/includes? out "THIS_CARD: next coder")))))
(deftest ready-for-next-batch-prints-card-type-and-this-card
  (let [root (tmp-dir)]
    (init-repo! root)
    (setup-project! root [["specifier" "task" "forward-only"]
                          ["coder" "task" "forward-only"]
                          ["cleaner" "batch" "back-one"]
                          ["architect" "batch" "back-all"]
                          ["hardender" "batch" "forward-only"]
                          ["QA" "batch" "back-all"]])
    (pack-board root true "create" "--root" (str root)
                "--name" "util" "--type" "utility")
    (make-queued-handoff! root "50_20260615T000001Z_000001_from_coder_to_cleaner.handoff"
                          {:id "20260615T000001Z_000001_from_coder"
                           :from "coder"
                           :to "cleaner"
                           :recipient "cleaner"
                           :priority "50"
                           :type "note"
                           :task "util"
                           :card-type "utility"
                           :body "cleanup util\n"})
    (let [out (:out (run {:dir root :env {"SWARMFORGE_ROLE" "cleaner"}}
                         (script "ready_for_next.sh")))]
      (is (str/includes? out "CARD_TYPE: utility"))
      (is (str/includes? out "THIS_CARD: last; terminal to: specifier,coder")))
    (pack-board root true "create" "--root" (str root)
                "--name" "jump" "--type" "component")
    (make-queued-handoff! root "50_20260615T000002Z_000002_from_coder_to_cleaner.handoff"
                          {:id "20260615T000002Z_000002_from_coder"
                           :from "coder"
                           :to "cleaner"
                           :recipient "cleaner"
                           :priority "50"
                           :type "note"
                           :task "jump"
                           :card-type "component"
                           :body "cleanup jump\n"})
    (run {:dir root :env {"SWARMFORGE_ROLE" "cleaner"}} (script "done_with_current.sh"))
    (let [out (:out (run {:dir root :env {"SWARMFORGE_ROLE" "cleaner"}}
                         (script "ready_for_next.sh")))]
      (is (str/includes? out "CARD_TYPE: component"))
      (is (str/includes? out "THIS_CARD: next architect")))))
(deftest done-with-current-replaces-an-existing-completed-file
  (let [root (tmp-dir)
        name "50_retry_htw.handoff"]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (put-handoff! root "in_process" name
                  {:id "retry"
                   :from "(Retry)" :to "receiver" :recipient "receiver"
                   :priority "50" :type "note" :task "htw"})
    (put-handoff! root "completed" name
                  {:id "retry-old"
                   :from "(Retry)" :to "receiver" :recipient "receiver"
                   :priority "50" :type "note" :task "htw"
                   :completed-at "2026-08-26T22:45:36.178441Z"})
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "receiver"}}
                      (script "done_with_current.sh"))
          completed (fs/path root ".swarmforge/handoffs/inbox/completed" name)
          in-process (fs/path root ".swarmforge/handoffs/inbox/in_process" name)]
      (is (zero? (:exit result)))
      (is (str/includes? (:out result) "COMPLETED:"))
      (is (not (fs/exists? in-process)))
      (is (fs/exists? completed))
      (is (not= "2026-08-26T22:45:36.178441Z" (header completed "completed_at"))))))
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
    (write-file (fs/path batch "batch_manifest.edn")
                (str (pr-str {:version 1 :batch-id (fs/file-name batch)}) "\n"))
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
      (is (fs/regular-file? (fs/path completed-batch "batch_manifest.edn")))
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
(deftest merge-and-process-takes-inbound-task-docs
  (let [root (tmp-dir)
        _ (init-repo! root)
        sender (add-worktree! root "sender")
        receiver (add-worktree! root "receiver")
        _ (setup-project! root)
        _ (write-file (fs/path root ".swarmforge/roles.tsv")
                      (format "sender\tsender\t%s\tsession\tSender\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\ttask\n"
                              sender receiver))
        _ (write-file (fs/path sender "tasks/UiShim.md") "from sender\n")
        _ (run {:dir sender} "git" "add" "tasks/UiShim.md")
        _ (run {:dir sender} "git" "commit" "-q" "-m" "Sender task doc")
        sha (str/trim (:out (run {:dir sender} "git" "rev-parse" "--short=10" "HEAD")))
        _ (write-file (fs/path receiver "tasks/UiShim.md") "untracked local\n")
        result (run {:dir receiver :ok? false}
                    (script "merge_and_process.sh") "sender" sha)]
    (is (zero? (:exit result)))
    (is (str/includes? (str (:out result) (:err result)) "MERGED:"))
    (is (= "from sender\n" (slurp (str (fs/path receiver "tasks/UiShim.md")))))))
(deftest ready-for-next-leaves-handback-while-in-process
  (let [root (tmp-dir)
        _ (init-repo! root)
        sender (add-worktree! root "sender")
        receiver (add-worktree! root "receiver")
        _ (setup-project! root)
        _ (write-file (fs/path root ".swarmforge/roles.tsv")
                      (format "sender\tsender\t%s\tsession\tSender\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\ttask\n"
                              sender receiver))]
    (doseq [dir [".swarmforge/handoffs/inbox/new"
                 ".swarmforge/handoffs/inbox/in_process"
                 ".swarmforge/handoffs/inbox/completed"]]
      (fs/create-dirs (fs/path receiver dir)))
    (write-file (fs/path sender "slice.md") "from sender\n")
    (run {:dir sender} "git" "add" "slice.md")
    (run {:dir sender} "git" "commit" "-q" "-m" "Sender slice")
    (let [sha (str/trim (:out (run {:dir sender} "git" "rev-parse" "--short=10" "HEAD")))]
      (write-file
       (fs/path receiver ".swarmforge/handoffs/inbox/in_process/50_ui.handoff")
       (str "from: (New Task)\nto: receiver\npriority: 50\ntype: note\n"
            "task: Ui\ntask_id: ui-1\n\nBuild Ui\n"))
      (write-file
       (fs/path receiver ".swarmforge/handoffs/inbox/new/00_from_sender_to_receiver.handoff")
       (str "from: sender\nto: receiver\npriority: 00\ntype: git_handoff\n"
            "non-forwarding: true\ncommit: " sha "\ntask: UiShim\n\nmerge\n"))
      (let [ready (run {:dir receiver :env {"SWARMFORGE_ROLE" "receiver"} :ok? false}
                       (script "ready_for_next.sh"))]
        (is (zero? (:exit ready)))
        (is (str/includes? (:out ready) "TASK_NAME: Ui"))
        (is (not (str/includes? (:out ready) "TASK_NAME: UiShim")))
        (is (fs/exists? (fs/path receiver ".swarmforge/handoffs/inbox/new/00_from_sender_to_receiver.handoff")))
        (is (not (fs/exists? (fs/path receiver "slice.md"))))
        (is (fs/exists? (fs/path receiver ".swarmforge/handoffs/inbox/in_process/50_ui.handoff"))))
      (run {:dir receiver :env {"SWARMFORGE_ROLE" "receiver"}}
           (script "done_with_current.sh"))
      (let [ready (run {:dir receiver :env {"SWARMFORGE_ROLE" "receiver"} :ok? false}
                       (script "ready_for_next.sh"))]
        (is (zero? (:exit ready)))
        (is (str/includes? (:out ready) "TASK_NAME: UiShim"))
        (is (fs/exists? (fs/path receiver "slice.md")))
        (is (not (fs/exists? (fs/path receiver ".swarmforge/handoffs/inbox/new/00_from_sender_to_receiver.handoff"))))))))
(deftest ready-for-next-merges-from-named-role-head
  (let [root (tmp-dir)
        _ (init-repo! root)
        sender (add-worktree! root "sender")
        receiver (add-worktree! root "receiver")
        _ (setup-project! root)
        _ (write-file (fs/path root ".swarmforge/roles.tsv")
                      (format "sender\tsender\t%s\tsession\tSender\tcodex\ttask\nreceiver\treceiver\t%s\tsession\tReceiver\tcodex\ttask\n"
                              sender receiver))]
    (doseq [dir [".swarmforge/handoffs/inbox/new"
                 ".swarmforge/handoffs/inbox/in_process"
                 ".swarmforge/handoffs/inbox/completed"]]
      (fs/create-dirs (fs/path receiver dir)))
    (write-file (fs/path sender "api.md") "coder api\n")
    (run {:dir sender} "git" "add" "api.md")
    (run {:dir sender} "git" "commit" "-q" "-m" "Coder API")
    (write-file (fs/path root "tasks/UiShim.md")
                "# UiShim\n\nType: component\nMerge-from: sender\n\nBuild it\n")
    (write-file
     (fs/path receiver ".swarmforge/handoffs/inbox/new/50_from_New_Task.handoff")
     (str "from: (New Task)\nto: receiver\npriority: 50\ntype: note\n"
          "task: UiShim\n\nBuild it\n"))
    (let [ready (run {:dir receiver :env {"SWARMFORGE_ROLE" "receiver"} :ok? false}
                     (script "ready_for_next.sh"))]
      (is (zero? (:exit ready)))
      (is (str/includes? (:out ready) "TASK_NAME: UiShim"))
      (is (fs/exists? (fs/path receiver "api.md"))))))
(deftest done-with-current-after-reverse-copy-does-not-queue-git-handoff
  ;; Given an in-process reverse git_handoff
  ;; When done_with_current runs
  ;; Then the inbound is completed and no outbox git_handoff is written
  (let [root (tmp-dir)
        _ (init-repo! root)
        _ (setup-project! root)
        inbound (fs/path root ".swarmforge/handoffs/inbox/in_process/00_from_architect.handoff")]
    (write-file inbound (str "from: architect\nto: sender\npriority: 00\ntype: git_handoff\n"
                             "task: HTW\nnon-forwarding: true\n\nmerge\n"))
    (let [result (run {:dir root :env {"SWARMFORGE_ROLE" "sender"}}
                      (script "done_with_current.sh"))
          completed (fs/path root ".swarmforge/handoffs/inbox/completed/00_from_architect.handoff")
          outbox (fs/glob (fs/path root ".swarmforge/handoffs/outbox") "*.handoff")]
      (is (zero? (:exit result)))
      (is (str/includes? (:out result) "COMPLETED:"))
      (is (fs/exists? completed))
      (is (not (fs/exists? inbound)))
      (is (empty? outbox)))))
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

(defn- wake-argv!
  "Deliver one queued note through handoffd with the tmux argv stub in place and
  return the recorded calls. `note` is used on purpose: preflight! rejects any
  other type before delivery ever reaches tmux."
  [root id]
  (let [argv-file (fs/path root "tmux.argv")]
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (write-file (fs/path root (str ".swarmforge/handoffs/outbox/50_" id ".handoff"))
                (handoff {:id id :from "sender" :to "receiver"
                          :priority "50" :type "note" :task-id id :task id}))
    (run {:dir root :env {"SWARMFORGE_TMUX_STUB" (str argv-file)}}
         "bb" (script "handoffd.bb") "--once" (str root))
    (read-argv argv-file)))

(deftest handoffd-routes-every-tmux-call-through-the-argv-stub
  ;; Given a queued outbox handoff and SWARMFORGE_TMUX_STUB set
  ;; When the daemon runs one pass
  ;; Then no real tmux runs: the wake text lands in the stub file instead
  (let [root (tmp-dir)]
    (init-repo! root)
    (setup-project! root {"sender" "task" "receiver" "task"})
    (is (= ["tmux" "-S" "/tmp/fake.sock" "send-keys" "-t" "session" "-l"
            "You have new handoff mail. If idle, run ready_for_next.sh."]
           (first (wake-argv! root "stub-seam")))
        "the wake text send must be recorded, not executed")))

(deftest handoffd-submits-a-codex-wake-with-a-raw-carriage-return
  ;; Given a codex role receiving a handoff
  ;; When the daemon delivers it
  ;; Then Enter goes out as the raw byte 0d, not as the symbolic C-m/C-j that
  ;; tmux re-encodes for a TUI that negotiated extended keys
  (let [root (tmp-dir)]
    (init-repo! root)
    (setup-project! root {"sender" "task" "receiver" "task"})
    (let [argv (wake-argv! root "codex-enter")]
      (is (= ["tmux" "-S" "/tmp/fake.sock" "send-keys" "-t" "session" "-H" "0d"]
             (second argv)))
      (is (= 2 (count argv)) "raw CR replaces the C-m + C-j pair, so one submit call"))))

(deftest handoffd-submits-a-claude-wake-with-csi-u-enter
  ;; Given a claude role receiving a handoff
  ;; When the daemon delivers it
  ;; Then Enter stays CSI-u: claude negotiates the kitty keyboard protocol and
  ;; ignores a bare CR
  (let [root (tmp-dir)]
    (init-repo! root)
    (setup-project! root {"sender" "task" "receiver" "task"})
    (write-file (fs/path root ".swarmforge/roles.tsv")
                (str "sender\tmaster\t" root "\tsession\tSender\tclaude\ttask\n"
                     "receiver\tmaster\t" root "\tsession\tReceiver\tclaude\ttask\n"))
    (is (= ["tmux" "-S" "/tmp/fake.sock" "send-keys" "-t" "session"
            "-H" "1b" "5b" "31" "33" "75"]
           (second (wake-argv! root "claude-enter"))))))

;; ---------------------------------------------------------------------------
;; D-5 (docs/fork-deltas.md): level reconciliation for unclaimed handoffs.
;; ---------------------------------------------------------------------------

(defn- entry-count
  "Entries in dir, or 0 when the dir was never created. fs/glob on a missing
  directory is not portable across babashka.fs versions."
  [dir]
  (if (fs/exists? dir) (count (fs/list-dir dir)) 0))

(defn- stalled-handoff!
  "A handoff sitting in inbox/new since 2026, i.e. past every retry delay."
  [root filename id]
  (put-handoff! root "new" filename
                {:id id :from "sender" :to "receiver" :recipient "receiver"
                 :priority "50" :type "note" :task "stalled"
                 :enqueued-at "2026-01-01T00:00:00Z"}))

(defn- handoffd-once! [root argv-file]
  (run {:dir root :env {"SWARMFORGE_TMUX_STUB" (str argv-file)}}
       "bb" (script "handoffd.bb") "--once" (str root)))

(defn- handoffd-background!
  "Run the daemon for ms with the given extra env, then stop it."
  [root env ms]
  (run {:dir root :ok? false}
       "sh" "-c"
       (str env " bb " (script "handoffd.bb") " " root " >/dev/null 2>&1 &"))
  (Thread/sleep ms)
  (run {:dir root} (script "stop_handoff_daemon.bb") (str root))
  (Thread/sleep 300)
  (read-file (fs/path root ".swarmforge/daemon/handoffd.log")))

(deftest handoffd-rewakes-a-handoff-left-unclaimed-in-inbox-new
  ;; Given a handoff that has sat in inbox/new past the first retry delay
  ;; When the daemon runs one pass
  ;; Then it re-sends the same wake hint, because the file is the level: a
  ;; keystroke the TUI swallowed leaves no other trace. The wakeup queue cannot
  ;; cover this - it only holds entries for a notify! that threw, and a
  ;; swallowed submit key still exits 0.
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (stalled-handoff! root "50_20260101T000000Z_000010_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000010_from_sender")
    (handoffd-once! root argv-file)
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
                   :priority "50" :type "note" :task "claimed"
                   :enqueued-at "2026-01-01T00:00:00Z"})
    (handoffd-once! root argv-file)
    ;; read-argv answers nil for a file the daemon never created.
    (is (empty? (read-argv argv-file)))))

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
    (handoffd-once! root argv-file)
    (handoffd-once! root argv-file)
    (is (= 1 (count (fs/glob new-dir "*.handoff"))))
    (is (= 0 (entry-count (fs/path root ".swarmforge/handoffs/failed"))))))

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
                   :priority "50" :type "note" :task "working"
                   :enqueued-at "2026-01-01T00:00:00Z"})
    (stalled-handoff! root "50_20260101T000000Z_000021_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000021_from_sender")
    (handoffd-once! root argv-file)
    ;; read-argv answers nil for a file the daemon never created.
    (is (empty? (read-argv argv-file)))))

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
                     :priority "50" :type "note" :task "stalled"
                     :enqueued-at "2026-01-01T00:00:00Z"}))
    (handoffd-once! root argv-file)
    ;; two wakes, each recorded as one text send plus one submit key
    (is (= 4 (count (read-argv argv-file))))))

(deftest handoffd-keeps-unclaimed-work-in-inbox-new-when-the-wake-fails
  ;; Given a stalled handoff and a tmux socket with no server behind it, so the
  ;; real tmux call fails
  ;; When the daemon runs one pass with no stub
  ;; Then the file stays in inbox/new and nothing lands in failed/: a lost
  ;; notification is not invalid work, and the role is not isolated
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
    (is (= 0 (entry-count (fs/path root ".swarmforge/handoffs/failed"))))
    (is (str/includes? (read-file (fs/path root ".swarmforge/daemon/handoffd.log"))
                       "wake-retry-failed"))))

(deftest handoffd-stops-waking-after-the-attempt-cap
  ;; Given a one-attempt cap and a 200ms retry interval
  ;; When the daemon runs long enough for several passes
  ;; Then it wakes once, logs wake-exhausted once, and leaves the file in place
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (stalled-handoff! root "50_20260101T000000Z_000041_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000041_from_sender")
    (let [log (handoffd-background!
               root (str "SWARMFORGE_TMUX_STUB=" argv-file
                         " SWARMFORGE_WAKE_ATTEMPT_CAP=1 SWARMFORGE_WAKE_RETRY_MS=200")
               3000)]
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
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (stalled-handoff! root "50_20260101T000000Z_000042_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000042_from_sender")
    (let [log (handoffd-background!
               root (str "SWARMFORGE_TMUX_STUB=" argv-file
                         " SWARMFORGE_WAKE_RETRY_MS=200")
               3500)]
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
        alert-file (fs/path root "alert.log")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (stalled-handoff! root "50_20260101T000000Z_000050_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000050_from_sender")
    (let [log (handoffd-background!
               root (str "SWARMFORGE_TMUX_STUB=" argv-file
                         " SWARMFORGE_WAKE_ATTEMPT_CAP=1 SWARMFORGE_WAKE_RETRY_MS=200"
                         " SWARMFORGE_ALERT_CMD='echo \"$SWARMFORGE_ALERT_HANDOFF"
                         " $SWARMFORGE_ALERT_ATTEMPTS\" >> " alert-file "'")
               3000)
          lines (if (fs/exists? alert-file)
                  (remove str/blank? (str/split-lines (read-file alert-file)))
                  [])]
      (is (= 1 (count lines)) "the alert fires once, not once per poll pass")
      (is (= "20260101T000000Z_000050_from_sender 1" (first lines))
          "the command sees the handoff id and attempt count")
      (is (str/includes? log "alert ")
          "the alert attempt is auditable in the daemon log"))))

(deftest handoffd-survives-a-failing-alert-command
  ;; Given an alert command that exits non-zero
  ;; When the cap is spent
  ;; Then the daemon logs the failure and keeps running: a broken alert channel
  ;; must never stop delivery, and the work must not be quarantined
  (let [root (tmp-dir)
        argv-file (fs/path root "tmux.argv")]
    (init-repo! root)
    (setup-project! root {"receiver" "task"})
    (write-file (fs/path root ".swarmforge/tmux-socket") "/tmp/fake.sock\n")
    (stalled-handoff! root "50_20260101T000000Z_000051_from_sender_to_receiver.handoff"
                      "20260101T000000Z_000051_from_sender")
    (let [log (handoffd-background!
               root (str "SWARMFORGE_TMUX_STUB=" argv-file
                         " SWARMFORGE_WAKE_ATTEMPT_CAP=1 SWARMFORGE_WAKE_RETRY_MS=200"
                         " SWARMFORGE_ALERT_CMD='exit 7'")
               3000)]
      (is (str/includes? log "alert ") "the failed attempt is still audited")
      (is (str/includes? log "exit=7") "the command's exit code is recorded")
      (is (= 1 (count (fs/glob (fs/path root ".swarmforge/handoffs/inbox/new") "*.handoff")))
          "unclaimed work stays in inbox/new"))))
