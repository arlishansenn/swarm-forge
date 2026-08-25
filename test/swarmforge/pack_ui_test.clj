(ns swarmforge.pack-ui-test
  (:require [babashka.fs :as fs]
            [cheshire.core :as json]
            [clojure.java.shell :as sh]
            [clojure.string :as str]
            [clojure.test :refer [deftest is run-tests use-fixtures]]))

(def six-pack-roles ["specifier" "coder" "cleaner" "architect" "hardender" "QA"])

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
  (let [dir (fs/create-temp-dir {:prefix "swarmforge-pack-ui-test."})]
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

(defn pack-worktree [root roles role]
  (if (= role (first roles))
    (str root)
    (str (fs/path root ".worktrees" role))))

(defn setup-pack!
  ([root] (setup-pack! root ["specifier"]))
  ([root roles]
   (write-file
    (fs/path root ".swarmforge/roles.tsv")
    (apply str
           (map-indexed
            (fn [i role]
              (format "%s\t%s\t%s\t%s\t%s\tcodex\ttask\n"
                      role
                      (if (zero? i) "master" role)
                      (pack-worktree root roles role)
                      role
                      (str/capitalize role)))
            roles)))
   (doseq [role roles
           dir [".swarmforge/handoffs/outbox"
                ".swarmforge/handoffs/sent"
                ".swarmforge/handoffs/failed"
                ".swarmforge/handoffs/inbox/new"]]
     (fs/create-dirs (fs/path (pack-worktree root roles role) dir)))
   (fs/create-dirs (fs/path root ".swarmforge/handoffs/pending_approval"))))

(defn pack-board
  ([root ok? & args]
   (apply run {:dir root :ok? ok?} (script "pack_board.sh") args)))

(defn pack-web
  ([root ok? & args]
   (apply run {:dir root :ok? ok?} (script "pack_web.sh") args)))

(defn pack-web-env
  [root env & args]
  (apply run {:dir root :env env} (script "pack_web.sh") args))

(defn set-backend!
  [root backend]
  (let [file (fs/path root ".swarmforge/roles.tsv")]
    (spit (str file)
          (str/replace (slurp (str file)) #"\tcodex\t" (str "\t" backend "\t")))))

(defn read-argv [path]
  (when (fs/exists? path)
    (->> (str/split-lines (slurp (str path)))
         (remove str/blank?)
         (mapv read-string))))

(defn create-task
  ([root name lane] (create-task root name lane true))
  ([root name lane ok?]
   (pack-board root ok?
               "create"
               "--root" (str root)
               "--name" name
               "--lane" lane
               "--text" "Integrate HTW stories")))

(defn list-tasks [root]
  (pack-board root true "list" "--root" (str root)))

(defn task-row [listed name]
  (some #(when (str/starts-with? % (str name "\t")) %)
        (str/split-lines listed)))

(defn task-lane [root name]
  (let [cols (str/split (or (task-row (:out (list-tasks root)) name) "") #"\t")]
    (nth cols 1 nil)))

(defn queue-handoff! [root {:keys [from to task artifacts non-forwarding]}]
  (write-file
   (fs/path root ".swarmforge/handoffs/outbox"
            (str "50_from_" from "_to_" (str/replace to #"," "_") ".handoff"))
   (str "from: " from "\n"
        "to: " to "\n"
        "priority: 50\n"
        "type: git_handoff\n"
        "task: " task "\n"
        (when artifacts (str "artifacts: " artifacts "\n"))
        (when non-forwarding "non-forwarding: true\n")
        "\n"
        "payload\n")))

(defn handoff-names [dir]
  (if (fs/directory? dir)
    (->> (fs/list-dir dir)
         (filter #(str/ends-with? (fs/file-name %) ".handoff"))
         (mapv #(fs/file-name %)))
    []))

(defn pending-names [root]
  (handoff-names (fs/path root ".swarmforge/handoffs/pending_approval")))

(defn inbox-names [root roles role]
  (handoff-names (fs/path (pack-worktree root roles role)
                          ".swarmforge/handoffs/inbox/new")))

(defn in-process-dir [root roles role]
  (fs/path (pack-worktree root roles role)
           ".swarmforge/handoffs/inbox/in_process"))

(defn put-in-process! [root roles role {:keys [from task filename]}]
  (write-file
   (fs/path (in-process-dir root roles role)
            (or filename (str "50_from_" from "_to_" role ".handoff")))
   (str "from: " from "\n"
        "to: " role "\n"
        "priority: 50\n"
        "type: git_handoff\n"
        "task: " task "\n"
        "\n"
        "payload\n")))

(defn web-state [root]
  (json/parse-string (:out (pack-web root true "--test-state" (str root))) true))

(defn start-tmux! [root sessions]
  (let [sock (str (fs/path root "tmux.sock"))]
    (write-file (fs/path root ".swarmforge/tmux-socket") (str sock "\n"))
    (doseq [session sessions]
      (run {:dir root} "tmux" "-S" sock "new-session" "-d" "-s" session "sleep" "120"))
    sock))

(defn stop-tmux! [sock]
  (run {:dir "." :ok? false} "tmux" "-S" sock "kill-server"))

(defn handoffd-once
  ([root] (handoffd-once root nil))
  ([root env]
   (run {:dir root :env env} "bb" (script "handoffd.bb") "--once" (str root))))

(defn pane-path [root role task]
  (fs/path root ".swarmforge/sessions" role task "pane.txt"))

(defn role-pane-path [root role]
  (fs/path root ".swarmforge/sessions" role "pane.txt"))

(deftest pack-board-creates-a-task-in-the-master-lane
  ;; Given a pack with specifier on master
  ;; When New Task records name htw-console-app
  ;; Then the card sits in lane specifier
  (let [root (tmp-dir)
        _ (setup-pack! root)
        created (create-task root "htw-console-app" "specifier")
        listed (:out (list-tasks root))
        on-disk (slurp (str (fs/path root ".swarmforge/board/tasks.tsv")))
        cols (str/split (or (task-row listed "htw-console-app") "") #"\t")]
    (is (zero? (:exit created)))
    (is (= listed on-disk))
    (is (= "htw-console-app" (nth cols 0 nil)))
    (is (= "specifier" (nth cols 1 nil)))
    (is (re-matches #"\d{4}-\d{2}-\d{2}T.*Z" (nth cols 2 "")))
    (is (= (nth cols 2 nil) (nth cols 3 nil)))))

(deftest new-task-writes-the-card-and-body
  ;; Given specifier is master
  ;; When create name=htw-console-app text="Integrate HTW stories…"
  ;; Then lane is specifier AND board/htw-console-app.txt has the text
  (let [root (tmp-dir)
        text "Integrate HTW stories…"]
    (write-file
     (fs/path root ".swarmforge/roles.tsv")
     (str "specifier\tmaster\t" root "\tsession\tSpecifier\tcodex\ttask\n"))
    (let [created (pack-board root true
                              "create"
                              "--root" (str root)
                              "--name" "htw-console-app"
                              "--lane" "specifier"
                              "--text" text)
          body (slurp (str (fs/path root ".swarmforge/board/htw-console-app.txt")))]
      (is (zero? (:exit created)))
      (is (= "specifier" (task-lane root "htw-console-app")))
      (is (= text body)))))

(deftest pack-board-lists-lanes-in-role-order
  ;; Given roles specifier, coder, QA
  ;; When pack_board lanes
  ;; Then it prints those roles in conf order
  (let [root (tmp-dir)
        _ (setup-pack! root ["specifier" "coder" "QA"])
        result (pack-board root true "lanes" "--root" (str root))]
    (is (= "specifier\ncoder\nQA\n" (:out result)))))

(deftest pack-board-reports-the-master-lane
  ;; Given specifier's worktree is master
  ;; When pack_board master-lane
  ;; Then it prints specifier
  (let [root (tmp-dir)]
    (write-file
     (fs/path root ".swarmforge/roles.tsv")
     (str "specifier\tmaster\t" root "\tsession\tSpecifier\tcodex\ttask\n"
          "coder\tcoder\t" root "/.worktrees/coder\tsession\tCoder\tcodex\ttask\n"))
    (let [result (pack-board root true "master-lane" "--root" (str root))]
      (is (= "specifier\n" (:out result))))))

(deftest pack-board-rejects-a-duplicate-task-name
  ;; Given a card named htw-console-app
  ;; When New Task records the same name again
  ;; Then the create is rejected and the original card is unchanged
  (let [root (tmp-dir)
        _ (setup-pack! root)
        _ (create-task root "htw-console-app" "specifier")
        before (:out (list-tasks root))
        duplicate (create-task root "htw-console-app" "specifier" false)
        after (:out (list-tasks root))]
    (is (not (zero? (:exit duplicate))))
    (is (str/includes? (str (:err duplicate) (:out duplicate)) "Duplicate"))
    (is (= before after))))

(deftest handoffd-moves-the-task-card-to-the-recipient
  ;; Given card htw-console-app in coder
  ;; When a git_handoff coder→cleaner for that task is delivered
  ;; Then the card lane is cleaner
  (let [root (tmp-dir)
        roles ["specifier" "coder" "cleaner"]
        sock (do (setup-pack! root roles)
                 (create-task root "htw-console-app" "coder")
                 (queue-handoff! root {:from "coder" :to "cleaner" :task "htw-console-app"})
                 (start-tmux! root roles))]
    (try
      (handoffd-once root)
      (is (= "cleaner" (task-lane root "htw-console-app")))
      (finally
        (stop-tmux! sock)))))

(deftest handoffd-marks-the-task-card-done-for-terminal-handoff
  ;; Given six-pack, card in QA (not master)
  ;; When QA queues git_handoff to every other role
  ;; Then the card lane is done
  (let [root (tmp-dir)
        to "specifier,coder,cleaner,architect,hardender"
        sock (do (setup-pack! root six-pack-roles)
                 (create-task root "htw-console-app" "QA")
                 (queue-handoff! root {:from "QA" :to to :task "htw-console-app"})
                 (start-tmux! root six-pack-roles))]
    (try
      (handoffd-once root)
      (is (= "done" (task-lane root "htw-console-app")))
      (finally
        (stop-tmux! sock)))))

(deftest pack-web-exposes-dashboard-state-from-conf-and-board
  ;; Given a six-pack with specifier as master and a board card
  ;; When pack_web --test-state
  ;; Then JSON includes lanes from conf, the master display name, and the card
  (let [root (tmp-dir)
        _ (setup-pack! root six-pack-roles)
        _ (create-task root "htw-console-app" "specifier")
        listed (:out (list-tasks root))
        updated (nth (str/split (or (task-row listed "htw-console-app") "") #"\t") 3 nil)
        result (pack-web root true "--test-state" (str root))
        state (json/parse-string (:out result) true)]
    (is (zero? (:exit result)))
    (is (= "specifier" (:master_role state)))
    (is (= "Specifier" (:master_display state)))
    (is (= six-pack-roles (:lanes state)))
    (is (= [{:name "htw-console-app" :lane "specifier" :updated_at updated :status ""}]
           (:tasks state)))
    (is (= [] (:approvals state)))
    (is (= six-pack-roles (mapv :role (:work_in_flight state))))))

(defn dashboard-html [root]
  (:out (pack-web root true "--test-html")))

(defn dashboard-js-fn [html name]
  (let [needle (str "function " name "(")
        start (str/index-of html needle)]
    (when start
      (let [rest (subs html start)
            cuts (remove nil? [(str/index-of rest "\nfunction " 1)
                               (str/index-of rest "\nasync function " 1)])
            nxt (when (seq cuts) (apply min cuts))]
        (subs rest 0 (or nxt (count rest)))))))

(deftest pack-dashboard-html-has-new-task-and-no-add-story
  ;; When serving dashboard.html
  ;; Then New Task exists, Add Story does not, Troubleshooter does not
  (let [root (tmp-dir)
        html (dashboard-html root)]
    (is (str/includes? html "New Task"))
    (is (not (str/includes? html "Add Story")))
    (is (not (str/includes? html "Troubleshooter")))
    (is (re-find #"id=\"nt-name\"" html))
    (is (re-find #"id=\"nt-text\"" html))
    (is (re-find #"id=\"nt-ok\"" html))
    (is (re-find #"id=\"nt-cancel\"" html))))

(deftest pack-dashboard-renders-a-lane-per-conf-role
  ;; Given --test-state lanes
  ;; (JS uses lanes from /api/state; test HTML has id="columns" and id="btn-new-task")
  (let [root (tmp-dir)
        _ (setup-pack! root six-pack-roles)
        state (json/parse-string (:out (pack-web root true "--test-state" (str root))) true)
        html (dashboard-html root)]
    (is (= six-pack-roles (:lanes state)))
    (is (re-find #"id=\"columns\"" html))
    (is (re-find #"id=\"btn-new-task\"" html))
    (is (str/includes? html "/api/state"))
    (is (str/includes? html "data.lanes"))
    (doseq [role six-pack-roles]
      (is (not (str/includes? html (str "data-lane=\"" role "\"")))))))

(deftest pack-web-post-task-creates-a-card-in-the-master-lane
  ;; Given a pack whose master role is coder
  ;; When POST /api/tasks records name and text
  ;; Then the card sits in lane coder with that body
  (let [root (tmp-dir)
        text "Integrate HTW stories"]
    (setup-pack! root ["coder" "cleaner"])
    (let [result (pack-web root true "--test-post-task" (str root) "htw-console-app" text)
          body (slurp (str (fs/path root ".swarmforge/board/htw-console-app.txt")))]
      (is (zero? (:exit result)))
      (is (= "coder" (task-lane root "htw-console-app")))
      (is (= text body)))))

(deftest handoffd-delivers-new-task-note-without-moving-the-card
  ;; Given a New Task note in the project outbox
  ;; When handoffd --once
  ;; Then specifier inbox has it, the card stays in specifier, and sent is on master
  (let [root (tmp-dir)
        roles six-pack-roles
        sock (do (setup-pack! root roles)
                 (pack-web root true "--test-post-task" (str root) "HTW" "Print hello")
                 (start-tmux! root roles))]
    (try
      (handoffd-once root)
      (is (= "specifier" (task-lane root "HTW")))
      (is (= [] (pending-names root)))
      (is (seq (inbox-names root roles "specifier")))
      (is (seq (handoff-names (fs/path root ".swarmforge/handoffs/sent"))))
      (is (empty? (handoff-names (fs/path (pack-worktree root roles "coder")
                                         ".swarmforge/handoffs/sent"))))
      (finally
        (stop-tmux! sock)))))

(deftest specifier-git-handoff-waits-for-attention
  ;; Given six-pack-shaped roles + card in specifier
  ;; When specifier→coder is queued and handoffd --once
  ;; Then file is in pending_approval, coder inbox empty, pack_web --test-state approvals has the task
  (let [root (tmp-dir)
        artifacts "features/console.feature,qa/console.md"
        sock (do (setup-pack! root six-pack-roles)
                 (create-task root "htw-console-app" "specifier")
                 (queue-handoff! root {:from "specifier" :to "coder" :task "htw-console-app"
                                       :artifacts artifacts})
                 (start-tmux! root six-pack-roles))]
    (try
      (handoffd-once root)
      (let [state (web-state root)]
        (is (= ["50_from_specifier_to_coder.handoff"] (pending-names root)))
        (is (= [] (inbox-names root six-pack-roles "coder")))
        (is (= "specifier" (task-lane root "htw-console-app")))
        (is (= [{:id "50_from_specifier_to_coder"
                 :gate "spec → coder"
                 :task "htw-console-app"
                 :artifacts ["features/console.feature" "qa/console.md"]}]
               (:approvals state))))
      (finally
        (stop-tmux! sock)))))

(deftest two-pack-git-handoff-does-not-wait
  ;; Given coder master, cleaner next, no specifier
  ;; When coder→cleaner queued + --once
  ;; Then delivered to cleaner; approvals empty
  (let [root (tmp-dir)
        roles ["coder" "cleaner"]
        sock (do (setup-pack! root roles)
                 (create-task root "htw-console-app" "coder")
                 (queue-handoff! root {:from "coder" :to "cleaner" :task "htw-console-app"})
                 (start-tmux! root roles))]
    (try
      (handoffd-once root)
      (is (seq (inbox-names root roles "cleaner")))
      (is (= [] (pending-names root)))
      (is (= "cleaner" (task-lane root "htw-console-app")))
      (is (= [] (:approvals (web-state root))))
      (finally
        (stop-tmux! sock)))))

(deftest two-pack-end-broadcast-marks-the-card-done
  ;; Given two-pack, card in cleaner
  ;; When cleaner queues git_handoff to coder (every other role)
  ;; Then the card is done and coder inbox has the file
  (let [root (tmp-dir)
        roles ["coder" "cleaner"]
        sock (do (setup-pack! root roles)
                 (create-task root "htw-console-app" "cleaner")
                 (queue-handoff! root {:from "cleaner" :to "coder" :task "htw-console-app"})
                 (start-tmux! root roles))]
    (try
      (handoffd-once root)
      (is (= "done" (task-lane root "htw-console-app")))
      (is (seq (inbox-names root roles "coder")))
      (is (= [] (pending-names root)))
      (finally
        (stop-tmux! sock)))))

(deftest four-pack-end-broadcast-marks-the-card-done
  ;; Given four-pack, card in architect
  ;; When architect queues git_handoff to every other role
  ;; Then the card is done
  (let [root (tmp-dir)
        roles ["specifier" "coder" "refactorer" "architect"]
        sock (do (setup-pack! root roles)
                 (create-task root "htw-console-app" "architect")
                 (queue-handoff! root {:from "architect"
                                       :to "specifier,coder,refactorer"
                                       :task "htw-console-app"})
                 (start-tmux! root roles))]
    (try
      (handoffd-once root)
      (is (= "done" (task-lane root "htw-console-app")))
      (is (seq (inbox-names root roles "specifier")))
      (is (seq (inbox-names root roles "coder")))
      (is (seq (inbox-names root roles "refactorer")))
      (is (= [] (pending-names root)))
      (finally
        (stop-tmux! sock)))))

(deftest four-pack-partial-to-is-not-done
  ;; Given four-pack, card in architect
  ;; When architect queues git_handoff to specifier,coder (not every other role)
  ;; Then the card is not done
  (let [root (tmp-dir)
        roles ["specifier" "coder" "refactorer" "architect"]
        sock (do (setup-pack! root roles)
                 (create-task root "htw-console-app" "architect")
                 (queue-handoff! root {:from "architect"
                                       :to "specifier,coder"
                                       :task "htw-console-app"})
                 (start-tmux! root roles))]
    (try
      (handoffd-once root)
      (is (not= "done" (task-lane root "htw-console-app")))
      (finally
        (stop-tmux! sock)))))

(deftest four-pack-one-recipient-non-forwarding-is-done
  ;; Given four-pack, card in architect
  ;; When architect queues a non-forwarding git_handoff to specifier only
  ;; Then the card is done, not moved to specifier
  (let [root (tmp-dir)
        roles ["specifier" "coder" "refactorer" "architect"]
        sock (do (setup-pack! root roles)
                 (create-task root "HTW" "architect")
                 (queue-handoff! root {:from "architect"
                                       :to "specifier"
                                       :task "HTW"
                                       :non-forwarding true})
                 (start-tmux! root roles))]
    (try
      (handoffd-once root)
      (is (= "done" (task-lane root "HTW")))
      (is (seq (inbox-names root roles "specifier")))
      (finally
        (stop-tmux! sock)))))

(deftest terminal-handoff-dones-finished-batch-cards-in-sender-lane
  ;; Given two-pack, Command syntax and validation in cleaner, those names in a
  ;; completed cleaner batch, HTW still in cleaner but not in that batch
  ;; When cleaner queues a terminal git_handoff named HTW
  ;; Then Command syntax and validation are done and HTW is done
  (let [root (tmp-dir)
        roles ["coder" "cleaner"]
        batch (fs/path (pack-worktree root roles "cleaner")
                       ".swarmforge/handoffs/inbox/completed"
                       "batch_20260824T150500Z_000001")
        sock (do (setup-pack! root roles)
                 (create-task root "HTW" "cleaner")
                 (create-task root "Command syntax" "cleaner")
                 (create-task root "validation" "cleaner")
                 (write-file (fs/path batch "50_command.handoff")
                             "from: coder\nto: cleaner\npriority: 50\ntype: git_handoff\ntask: Command syntax\n\npayload\n")
                 (write-file (fs/path batch "50_validation.handoff")
                             "from: coder\nto: cleaner\npriority: 50\ntype: git_handoff\ntask: validation\n\npayload\n")
                 (queue-handoff! root {:from "cleaner" :to "coder" :task "HTW"})
                 (start-tmux! root roles))]
    (try
      (handoffd-once root)
      (is (= "done" (task-lane root "HTW")))
      (is (= "done" (task-lane root "Command syntax")))
      (is (= "done" (task-lane root "validation")))
      (finally
        (stop-tmux! sock)))))

(deftest terminal-handoff-leaves-unfinished-lane-cards
  ;; Given two-pack, HTW finished in a completed batch, Command syntax only in the lane
  ;; When cleaner terminals with task HTW
  ;; Then HTW is done and Command syntax stays in cleaner
  (let [root (tmp-dir)
        roles ["coder" "cleaner"]
        done (fs/path (pack-worktree root roles "cleaner")
                      ".swarmforge/handoffs/inbox/completed")
        sock (do (setup-pack! root roles)
                 (create-task root "HTW" "cleaner")
                 (create-task root "Command syntax" "cleaner")
                 (write-file (fs/path done "50_htw.handoff")
                             "from: coder\nto: cleaner\npriority: 50\ntype: git_handoff\ntask: HTW\n\npayload\n")
                 (queue-handoff! root {:from "cleaner" :to "coder" :task "HTW"})
                 (start-tmux! root roles))]
    (try
      (handoffd-once root)
      (is (= "done" (task-lane root "HTW")))
      (is (= "cleaner" (task-lane root "Command syntax")))
      (finally
        (stop-tmux! sock)))))

(deftest terminal-handoff-dones-in-process-batch-cards
  ;; Given two-pack, one liners/validate/HHG in an in-process cleaner batch,
  ;; and Command syntax in cleaner but not in that batch
  ;; When cleaner terminals with task one liners before done_with_current
  ;; Then the three batch cards are done and Command syntax stays in cleaner
  (let [root (tmp-dir)
        roles ["coder" "cleaner"]
        batch (fs/path (in-process-dir root roles "cleaner")
                       "batch_20260824T202830Z_000001")
        sock (do (setup-pack! root roles)
                 (create-task root "one liners" "cleaner")
                 (create-task root "validate" "cleaner")
                 (create-task root "Holy Hand Grenade" "cleaner")
                 (create-task root "Command syntax" "cleaner")
                 (write-file (fs/path batch "50_oneliners.handoff")
                             "from: coder\nto: cleaner\npriority: 50\ntype: git_handoff\ntask: one liners\n\npayload\n")
                 (write-file (fs/path batch "50_validate.handoff")
                             "from: coder\nto: cleaner\npriority: 50\ntype: git_handoff\ntask: validate\n\npayload\n")
                 (write-file (fs/path batch "50_hhg.handoff")
                             "from: coder\nto: cleaner\npriority: 50\ntype: git_handoff\ntask: Holy Hand Grenade\n\npayload\n")
                 (queue-handoff! root {:from "cleaner" :to "coder" :task "one liners"})
                 (start-tmux! root roles))]
    (try
      (handoffd-once root)
      (is (= "done" (task-lane root "one liners")))
      (is (= "done" (task-lane root "validate")))
      (is (= "done" (task-lane root "Holy Hand Grenade")))
      (is (= "cleaner" (task-lane root "Command syntax")))
      (finally
        (stop-tmux! sock)))))

(deftest six-pack-qa-broadcast-marks-the-card-done
  ;; Given six-pack, card in QA
  ;; When QA queues git_handoff to every other role
  ;; Then the card is done
  (let [root (tmp-dir)
        others "specifier,coder,cleaner,architect,hardender"
        sock (do (setup-pack! root six-pack-roles)
                 (create-task root "htw-console-app" "QA")
                 (queue-handoff! root {:from "QA" :to others :task "htw-console-app"})
                 (start-tmux! root six-pack-roles))]
    (try
      (handoffd-once root)
      (is (= "done" (task-lane root "htw-console-app")))
      (is (seq (inbox-names root six-pack-roles "specifier")))
      (is (seq (inbox-names root six-pack-roles "hardender")))
      (is (= [] (pending-names root)))
      (finally
        (stop-tmux! sock)))))

(deftest attention-approve-delivers-the-handoff
  ;; Given pending approval
  ;; When pack_web --test-approve <root> <id>
  ;; Then coder inbox has the file, card lane coder (handoffd --once after approve)
  (let [root (tmp-dir)
        sock (do (setup-pack! root six-pack-roles)
                 (create-task root "htw-console-app" "specifier")
                 (queue-handoff! root {:from "specifier" :to "coder" :task "htw-console-app"
                                       :artifacts "features/console.feature"})
                 (start-tmux! root six-pack-roles))]
    (try
      (handoffd-once root)
      (let [id (:id (first (:approvals (web-state root))))]
        (pack-web root true "--test-approve" (str root) id)
        (handoffd-once root)
        (is (seq (inbox-names root six-pack-roles "coder")))
        (is (= "coder" (task-lane root "htw-console-app")))
        (is (= [] (pending-names root)))
        (is (= [] (:approvals (web-state root)))))
      (finally
        (stop-tmux! sock)))))

(deftest attention-reject-returns-to-master
  ;; Given pending
  ;; When --test-reject
  ;; Then pending gone, card stays specifier
  (let [root (tmp-dir)
        sock (do (setup-pack! root six-pack-roles)
                 (create-task root "htw-console-app" "specifier")
                 (queue-handoff! root {:from "specifier" :to "coder" :task "htw-console-app"})
                 (start-tmux! root six-pack-roles))]
    (try
      (handoffd-once root)
      (let [id (:id (first (:approvals (web-state root))))]
        (pack-web root true "--test-reject" (str root) id)
        (is (= [] (pending-names root)))
        (is (= [] (inbox-names root six-pack-roles "coder")))
        (is (= "specifier" (task-lane root "htw-console-app")))
        (is (= [] (:approvals (web-state root))))
        (is (fs/exists? (fs/path root ".swarmforge/notify/reject-htw-console-app"))))
      (finally
        (stop-tmux! sock)))))

(deftest pack-dashboard-renders-attention-approvals
  ;; Given dashboard HTML
  ;; Then it renders data.approvals with View document, Approve, and Reject
  (let [html (dashboard-html (tmp-dir))]
    (is (re-find #"id=\"attention-rows\"" html))
    (is (str/includes? html "data.approvals"))
    (is (str/includes? html "/api/approvals/"))
    (is (str/includes? html "/doc?path="))
    (is (str/includes? html "Approve"))
    (is (str/includes? html "Reject"))))

(def example-task-text
  "Integrate the stories in ~/junk/htw-stories into one console application.")

(def example-task-payload
  (str "Task: htw-console-app\n\n" example-task-text))

(deftest inject-payload-formats-task-name-and-body
  ;; Given the New Task example name and body
  ;; When pack_web --test-inject-payload
  ;; Then it prints Task: name, a blank line, and the body
  (let [result (pack-web (tmp-dir) false "--test-inject-payload")]
    (is (zero? (:exit result)))
    (is (= (str example-task-payload "\n") (:out result)))))

(deftest pack-web-post-task-creates-a-card-when-tmux-is-missing
  ;; Given no tmux socket or live session
  ;; When POST /api/tasks via --test-post-task
  ;; Then inject failure is ignored and the card is still created
  (let [root (tmp-dir)
        text example-task-text]
    (setup-pack! root ["coder" "cleaner"])
    (let [result (pack-web root false "--test-post-task" (str root) "htw-console-app" text)
          body (slurp (str (fs/path root ".swarmforge/board/htw-console-app.txt")))]
      (is (zero? (:exit result)))
      (is (= "coder" (task-lane root "htw-console-app")))
      (is (= text body)))))

(deftest inject-master-records-send-keys-argv
  ;; Given master session swarmforge-specifier running codex in roles.tsv
  ;; When --test-inject-argv records the would-be tmux argv
  ;; Then it send-keys -l the text, then a raw carriage return — the same
  ;; encoding handoffd uses, because a symbolic C-m is re-encoded by tmux for a
  ;; TUI that negotiated extended keys and then never submits
  (let [root (tmp-dir)
        argv-file (str (fs/path root "tmux.argv"))
        sock (str (fs/path root "tmux.sock"))
        text "hello from operator"]
    (write-file
     (fs/path root ".swarmforge/roles.tsv")
     (str "specifier\tmaster\t" root "\tswarmforge-specifier\tSpecifier\tcodex\ttask\n"))
    (write-file (fs/path root ".swarmforge/tmux-socket") (str sock "\n"))
    (let [result (pack-web root false "--test-inject-argv" (str root) argv-file text)
          argv (read-argv argv-file)]
      (is (zero? (:exit result)))
      (is (= ["tmux" "-S" sock "send-keys" "-t" "swarmforge-specifier:Specifier.0" "-l" text]
             (first argv)))
      (is (= ["tmux" "-S" sock "send-keys" "-t" "swarmforge-specifier:Specifier.0" "-H" "0d"]
             (second argv)))
      (is (= 2 (count argv))))))

(deftest pack-web-post-task-queues-a-note-for-master
  ;; Given a specifier pack and a tmux argv stub
  ;; When POST /api/tasks records name and text
  ;; Then the card is in specifier, a (New Task) note is in the outbox, and the pane is not injected
  (let [root (tmp-dir)
        argv-file (str (fs/path root "tmux.argv"))
        sock (str (fs/path root "tmux.sock"))
        text example-task-text]
    (setup-pack! root)
    (write-file (fs/path root ".swarmforge/tmux-socket") (str sock "\n"))
    (let [result (pack-web-env root {"SWARMFORGE_TMUX_STUB" argv-file}
                               "--test-post-task" (str root) "htw-console-app" text)
          queued (handoff-names (fs/path root ".swarmforge/handoffs/outbox"))
          content (when (seq queued)
                    (slurp (str (fs/path root ".swarmforge/handoffs/outbox" (first queued)))))]
      (is (zero? (:exit result)))
      (is (= "specifier" (task-lane root "htw-console-app")))
      (is (= 1 (count queued)))
      (is (str/includes? (str content) "from: (New Task)\n"))
      (is (str/includes? (str content) "to: specifier\n"))
      (is (str/includes? (str content) "type: note\n"))
      (is (str/includes? (str content) "task: htw-console-app\n"))
      (is (str/includes? (str content) text))
      (is (empty? (read-argv argv-file))))))

(deftest pack-web-post-chat-injects-text-as-is
  ;; Given a tmux argv stub
  ;; When POST /api/chat {text}
  ;; Then inject-master! send-keys that text, not a Task payload
  (let [root (tmp-dir)
        argv-file (str (fs/path root "tmux.argv"))
        sock (str (fs/path root "tmux.sock"))
        text "Please add a --help flag"]
    (setup-pack! root)
    (write-file (fs/path root ".swarmforge/tmux-socket") (str sock "\n"))
    (let [result (pack-web-env root {"SWARMFORGE_TMUX_STUB" argv-file}
                               "--test-post-chat" (str root) text)
          argv (read-argv argv-file)]
      (is (zero? (:exit result)))
      (is (str/includes? (str (last (first argv))) text))
      (is (re-find #"\[req-" (str (last (first argv)))))
      (is (not (str/starts-with? (str (last (first argv))) "Task:")))
      (is (= ["-H" "0d"] (take-last 2 (second argv))))
      (is (= 2 (count argv))))))

(deftest attention-reject-injects-a-message-to-master
  ;; Given a pending approval and a tmux argv stub
  ;; When --test-reject
  ;; Then the notify file is written and master receives a one-line reject
  (let [root (tmp-dir)
        argv-file (str (fs/path root "tmux.argv"))
        sock (str (fs/path root "tmux.sock"))]
    (setup-pack! root six-pack-roles)
    (create-task root "htw-console-app" "specifier")
    (write-file (fs/path root ".swarmforge/tmux-socket") (str sock "\n"))
    (write-file
     (fs/path root ".swarmforge/handoffs/pending_approval/50_from_specifier_to_coder.handoff")
     (str "from: specifier\n"
          "to: coder\n"
          "priority: 50\n"
          "type: git_handoff\n"
          "task: htw-console-app\n"
          "\n"
          "payload\n"))
    (let [result (pack-web-env root {"SWARMFORGE_TMUX_STUB" argv-file}
                               "--test-reject" (str root) "50_from_specifier_to_coder")
          argv (read-argv argv-file)]
      (is (zero? (:exit result)))
      (is (= [] (pending-names root)))
      (is (fs/exists? (fs/path root ".swarmforge/notify/reject-htw-console-app")))
      (is (= "Rejected: htw-console-app" (last (first argv))))
      (is (= ["-H" "0d"] (take-last 2 (second argv))))
      (is (= 2 (count argv))))))

(deftest pack-dashboard-chat-rail-posts-to-master
  ;; Given dashboard HTML
  ;; Then the rail title uses data.master_display and the composer posts /api/chat
  (let [html (dashboard-html (tmp-dir))]
    (is (str/includes? html "data.master_display"))
    (is (re-find #"id=\"master-title\"" html))
    (is (re-find #"id=\"chat-input\"" html))
    (is (str/includes? html "/api/chat"))))

(deftest pack-web-lists-every-role-in-the-work-queue
  ;; Given a six-pack with no in_process mail
  ;; When pack_web --test-state
  ;; Then work_in_flight has one row per conf role
  (let [root (tmp-dir)
        _ (setup-pack! root six-pack-roles)
        wif (:work_in_flight (web-state root))]
    (is (= six-pack-roles (mapv :role wif)))
    (is (every? #(= "no_session" (:state %)) wif))
    (is (every? #(= 0 (:activity %)) wif))))

(deftest pack-web-lists-in-process-work-in-flight
  ;; Given in_process handoff for coder task cave-walk
  ;; When pack_web --test-state
  ;; Then work_in_flight includes task cave-walk role coder
  (let [root (tmp-dir)
        roles ["specifier" "coder"]]
    (setup-pack! root roles)
    (put-in-process! root roles "coder" {:from "specifier" :task "cave-walk"})
    (let [wif (:work_in_flight (web-state root))
          row (some #(when (= "coder" (:role %)) %) wif)]
      (is (= roles (mapv :role wif)))
      (is (= "cave-walk" (:task row)))
      (is (= "coder" (:role row)))
      (is (re-matches #"\d{4}-\d{2}-\d{2}T.*Z" (or (:updated_at row) ""))))))

(deftest pack-web-marks-in-process-roles-live-when-session-exists
  ;; Given coder in_process and live tmux sessions
  ;; When pack_web --test-state
  ;; Then coder is live with that task and specifier is idle
  (let [root (tmp-dir)
        roles ["specifier" "coder"]
        sock (do (setup-pack! root roles)
                 (put-in-process! root roles "coder" {:from "specifier" :task "cave-walk"})
                 (start-tmux! root roles))]
    (try
      (let [wif (:work_in_flight (web-state root))
            by-role (into {} (map (juxt :role identity) wif))]
        (is (= "idle" (:state (get by-role "specifier"))))
        (is (= "live" (:state (get by-role "coder"))))
        (is (= "cave-walk" (:task (get by-role "coder"))))
        (is (= "" (:task (get by-role "specifier")))))
      (finally
        (stop-tmux! sock)))))

(deftest pack-web-lists-batch-in-process-in-work-in-flight
  ;; Given a batch dir in coder in_process for task cave-walk
  ;; When pack_web --test-state
  ;; Then work_in_flight includes task cave-walk role coder
  (let [root (tmp-dir)
        roles ["specifier" "coder"]]
    (setup-pack! root roles)
    (put-in-process! root roles "coder"
                     {:from "specifier"
                      :task "cave-walk"
                      :filename "batch_20260615T000001Z_000001/50_from_specifier_to_coder.handoff"})
    (let [wif (:work_in_flight (web-state root))]
      (is (some #(and (= "cave-walk" (:task %)) (= "coder" (:role %))) wif)))))

(deftest pack-dashboard-html-has-work-queue-and-no-sl
  ;; When serving dashboard.html
  ;; Then Work Queue role links use data-open-agent
  ;; And Open SL / sl-therm / merger are absent
  (let [html (dashboard-html (tmp-dir))]
    (is (str/includes? html "Work Queue"))
    (is (str/includes? html "data-open-agent"))
    (is (str/includes? html "data.work_in_flight"))
    (is (str/includes? html "item.state"))
    (is (str/includes? html "item.activity"))
    (is (str/includes? html "data.chat"))
    (is (str/includes? html "data-task-name"))
    (is (str/includes? html "/task?name="))
    (is (str/includes? html "Documents"))
    (is (str/includes? html "resizable=yes"))
    (is (str/includes? html "/agent/"))
    (is (str/includes? html "setInterval(loadState"))
    (is (str/includes? html "id=\"error\""))
    (is (str/includes? html "Swarm disconnected"))
    (is (not (str/includes? html "Open SL")))
    (is (not (str/includes? html "sl-therm")))
    (is (not (str/includes? html "merger")))))

(deftest pack-dashboard-has-no-top-bar-open-master
  ;; Given dashboard HTML
  ;; Then the top bar has no Open master button; the rail still does
  (let [html (dashboard-html (tmp-dir))]
    (is (not (str/includes? html "id=\"btn-open-master\"")))
    (is (str/includes? html "id=\"btn-open-master-rail\""))))

(deftest pack-agent-page-polls-live-pane
  ;; When serving the agent session window
  ;; Then it polls /api/agents/<role>/pane
  (let [result (pack-web (tmp-dir) false "--test-agent-page" "specifier")]
    (is (zero? (:exit result)))
    (is (str/includes? (:out result) "/api/agents/specifier/pane"))
    (is (str/includes? (:out result) "setInterval(refresh"))
    (is (str/includes? (:out result) "toEndSoon"))
    (is (str/includes? (:out result) "stickBottom"))))

(deftest pack-web-test-pane-prints-recorded-pane
  ;; Given a recorded pane.txt for coder task cave-walk
  ;; When pack_web --test-pane
  ;; Then it prints that text
  (let [root (tmp-dir)
        text "coder pane snapshot\n"]
    (setup-pack! root ["specifier" "coder"])
    (write-file (fs/path root ".swarmforge/sessions/coder/pane.txt") text)
    (let [result (pack-web root false "--test-pane" (str root) "coder")]
      (is (zero? (:exit result)))
      (is (str/includes? (:out result) "coder pane snapshot")))))

(deftest handoffd-archives-sender-pane-when-task-moves
  ;; Given card and specifier→coder handoff (two-pack coder→cleaner to skip attention)
  ;; When delivered
  ;; Then .swarmforge/sessions/<from>/<task>/pane.txt exists
  (let [root (tmp-dir)
        roles ["coder" "cleaner"]
        sock (do (setup-pack! root roles)
                 (create-task root "htw-console-app" "coder")
                 (queue-handoff! root {:from "coder" :to "cleaner" :task "htw-console-app"})
                 (start-tmux! root roles))]
    (try
      (handoffd-once root {"SWARMFORGE_PANE_STUB" "pane\n"})
      (let [pane (role-pane-path root "coder")]
        (is (fs/exists? pane))
        (is (= "pane\n" (slurp (str pane))))
        (is (not (fs/exists? (pane-path root "coder" "htw-console-app")))))
      (finally
        (stop-tmux! sock)))))

(deftest pack-board-archives-live-role-panes
  ;; Given a two-pack with a live card in coder and a done card
  ;; When pack_board archive-all with SWARMFORGE_PANE_STUB
  ;; Then coder's pane.txt exists and the done card is skipped
  (let [root (tmp-dir)
        roles ["coder" "cleaner"]]
    (setup-pack! root roles)
    (create-task root "htw-console-app" "coder")
    (create-task root "already-done" "done")
    (let [result (run {:dir root :env {"SWARMFORGE_PANE_STUB" "pane\n"}}
                      (script "pack_board.sh")
                      "archive-all" "--root" (str root))]
      (is (zero? (:exit result)))
      (is (= "pane\n" (slurp (str (role-pane-path root "coder")))))
      (is (not (fs/exists? (role-pane-path root "done"))))
      (is (not (fs/exists? (pane-path root "coder" "htw-console-app")))))))

(deftest close-swarm-archives-live-role-panes
  ;; Given a two-pack with a live card in coder
  ;; When close-swarm
  ;; Then coder's pane.txt is archived
  (let [root (tmp-dir)
        roles ["coder" "cleaner"]]
    (setup-pack! root roles)
    (create-task root "htw-console-app" "coder")
    (write-file (fs/path root ".swarmforge/tmux-socket")
                (str (fs/path root "tmux.sock") "\n"))
    (write-file (fs/path root ".swarmforge/window-ids") "")
    (let [result (run {:dir root
                       :env {"SWARMFORGE_TERMINAL_BACKEND" "none"
                             "SWARMFORGE_PANE_STUB" "pane\n"}}
                      (str (fs/path repo-root "close-swarm"))
                      (str root))]
      (is (zero? (:exit result)))
      (is (= "pane\n" (slurp (str (role-pane-path root "coder"))))))))

(defn wait-file [path timeout-ms]
  (let [deadline (+ (System/currentTimeMillis) timeout-ms)]
    (loop []
      (cond
        (fs/exists? path) true
        (> (System/currentTimeMillis) deadline) false
        :else (do (Thread/sleep 50) (recur))))))

(deftest pack-web-serve-writes-dashboard-url-and-binds-localhost
  ;; Given a pack root
  ;; When pack_web --serve <root>
  ;; Then dashboard-url is a localhost URL and GET / serves the dashboard
  (let [root (tmp-dir)
        url-file (fs/path root ".swarmforge/dashboard-url")
        pb (doto (java.lang.ProcessBuilder. [(script "pack_web.sh") "--serve" (str root)])
             (.directory (java.io.File. (str root))))
        _ (doto (.environment pb)
            (.put "PATH" (System/getenv "PATH"))
            (.put "GIT_CONFIG_NOSYSTEM" "1"))
        proc (.start pb)]
    (try
      (is (wait-file url-file 5000) "dashboard-url was written")
      (when (fs/exists? url-file)
        (let [url (str/trim (slurp (str url-file)))
              html (slurp url)]
          (is (re-find #"^http://127\.0\.0\.1:\d+$" url))
          (is (str/includes? html "New Task"))))
      (finally
        (.destroyForcibly proc)
        (.waitFor proc)))))

(deftest pack-web-thermometer-heat-rises-when-pane-changes
  ;; Given a specifier row
  ;; When --test-heat samples two different pane texts
  ;; Then activity after is greater than activity before
  (let [root (tmp-dir)
        _ (setup-pack! root ["specifier"])
        result (pack-web root false "--test-heat" (str root))
        body (json/parse-string (:out result) true)]
    (is (zero? (:exit result)))
    (is (< (:before body) (:after body)))
    (is (<= 0 (:before body)))
    (is (<= (:after body) 6))))

(deftest pack-web-thermometer-heats-on-codex-working-timer
  ;; Given a Codex specifier pane whose only change is the working timer
  ;; When --test-heat-codex samples both
  ;; Then activity rises
  (let [root (tmp-dir)
        _ (setup-pack! root ["specifier"])
        result (pack-web root false "--test-heat-codex" (str root))
        body (json/parse-string (:out result) true)]
    (is (zero? (:exit result)))
    (is (< (:before body) (:after body)))))

(deftest pack-dashboard-html-wires-teardown
  ;; When serving dashboard.html
  ;; Then Teardown posts /api/teardown after confirm
  (let [html (dashboard-html (tmp-dir))]
    (is (re-find #"id=\"teardown-btn\"" html))
    (is (str/includes? html "/api/teardown"))
    (is (str/includes? html "TEARDOWN"))
    (is (str/includes? html "teardownSwarm"))))

(deftest pack-web-teardown-requires-confirm
  ;; Given a pack root
  ;; When POST /api/teardown without confirm
  ;; Then it is rejected
  (let [root (tmp-dir)
        result (pack-web root false "--test-teardown" (str root))]
    (is (= 2 (:exit result)))
    (is (str/includes? (str (:err result) (:out result)) "TEARDOWN"))))

(deftest pack-web-teardown-kills-sessions-and-handoffd
  ;; Given a live tmux session and a fake handoffd pid
  ;; When teardown is confirmed
  ;; Then the tmux server is dead and the daemon pid is gone
  (let [root (tmp-dir)
        _ (setup-pack! root ["coder" "cleaner"])
        sock (start-tmux! root ["coder" "cleaner"])
        daemon (.start (java.lang.ProcessBuilder. ["sleep" "120"]))
        pid (str (.pid daemon))]
    (try
      (write-file (fs/path root ".swarmforge/daemon/handoffd.pid") (str pid "\n"))
      (let [result (pack-web root false "--test-teardown" (str root) "TEARDOWN")]
        (is (zero? (:exit result)))
        (is (str/includes? (:out result) "teardown_started"))
        (is (not= 0 (:exit (run {:dir root :ok? false} "tmux" "-S" sock "list-sessions"))))
        (is (false? (.isAlive daemon)))
        (is (not (fs/exists? (fs/path root ".swarmforge/daemon/handoffd.pid")))))
      (finally
        (when (.isAlive daemon)
          (.destroyForcibly daemon))
        (stop-tmux! sock)))))

(deftest pack-board-move-matches-task-name-ignoring-case
  ;; Given board card HTW
  ;; When pack_board move --name htw --lane coder
  ;; Then the card HTW is in coder
  (let [root (tmp-dir)]
    (setup-pack! root)
    (create-task root "HTW" "specifier")
    (pack-board root true "move" "--root" (str root) "--name" "htw" "--lane" "coder")
    (is (= "coder" (task-lane root "HTW")))))

(deftest handoffd-moves-card-when-handoff-task-case-differs
  ;; Given card HTW in coder
  ;; When git_handoff coder→cleaner task htw is delivered
  ;; Then HTW is in cleaner
  (let [root (tmp-dir)
        roles ["coder" "cleaner"]
        sock (do (setup-pack! root roles)
                 (create-task root "HTW" "coder")
                 (queue-handoff! root {:from "coder" :to "cleaner" :task "htw"})
                 (start-tmux! root roles))]
    (try
      (handoffd-once root)
      (is (= "cleaner" (task-lane root "HTW")))
      (finally
        (stop-tmux! sock)))))

(deftest handoffd-does-not-deliver-when-board-task-is-unknown
  ;; Given card HTW and a handoff for other-task
  ;; When delivered
  ;; Then coder inbox stays empty and HTW stays in specifier
  (let [root (tmp-dir)
        roles ["coder" "cleaner"]
        sock (do (setup-pack! root roles)
                 (create-task root "HTW" "coder")
                 (queue-handoff! root {:from "coder" :to "cleaner" :task "other-task"})
                 (start-tmux! root roles))]
    (try
      (handoffd-once root)
      (is (= "coder" (task-lane root "HTW")))
      (is (= [] (inbox-names root roles "cleaner")))
      (finally
        (stop-tmux! sock)))))

(deftest pack-web-shows-board-card-as-live-work
  ;; Given card HTW in specifier and a live specifier session
  ;; When pack_web --test-state
  ;; Then specifier row is live with task HTW
  (let [root (tmp-dir)
        sock (do (setup-pack! root)
                 (create-task root "HTW" "specifier")
                 (start-tmux! root ["specifier"]))]
    (try
      (let [row (some #(when (= "specifier" (:role %)) %)
                      (:work_in_flight (web-state root)))]
        (is (= "HTW" (:task row)))
        (is (= "live" (:state row))))
      (finally
        (stop-tmux! sock)))))

(deftest pack-web-chat-persists-and-answers
  ;; Given a pack root
  ;; When POST /api/chat then pack_dashboard_request answer
  ;; Then /api/state chat has the body and response
  (let [root (tmp-dir)
        argv-file (str (fs/path root "tmux.argv"))
        sock (str (fs/path root "tmux.sock"))
        answer (fs/path root "tmp" "answer.txt")]
    (setup-pack! root)
    (write-file (fs/path root ".swarmforge/tmux-socket") (str sock "\n"))
    (write-file answer "the spec is ready\n")
    (pack-web-env root {"SWARMFORGE_TMUX_STUB" argv-file}
                  "--test-post-chat" (str root) "status?")
    (let [listed (run {:dir root}
                      (script "pack_dashboard_request.sh")
                      "list" "--root" (str root))
          id (first (str/split (str/trim (:out listed)) #"\t"))]
      (is (str/starts-with? id "req-"))
      (run {:dir root} (script "pack_dashboard_request.sh") "answer" id (str answer))
      (let [chat (:chat (web-state root))
            row (first chat)]
        (is (= "status?" (str/trim (:body row))))
        (is (= "the spec is ready" (str/trim (:response row))))
        (is (= "done" (:status row)))))))

(deftest pack-dashboard-documents-menu-paints-above-the-board
  ;; Given dashboard HTML
  ;; When the Documents menu opens
  ;; Then it is position:fixed (not clipped by Attention overflow)
  (let [html (dashboard-html (tmp-dir))]
    (is (str/includes? html ".menu-list{"))
    (is (re-find #"(?s)\.menu-list\{[^}]*position:fixed" html))
    (is (str/includes? html "getBoundingClientRect"))))

(deftest pack-dashboard-pins-chat-to-the-bottom
  ;; Given dashboard HTML
  ;; When the first chat turn renders
  ;; Then the history pins to the bottom on first paint
  (let [html (dashboard-html (tmp-dir))]
    (is (re-find #"id=\"chat-history\"" html))
    (is (str/includes? html "scrollHeight"))
    (is (str/includes? html "firstPaint"))))

(deftest pack-dashboard-updates-chat-without-rebuilding-history
  ;; Given dashboard HTML
  ;; Then chat turns are keyed and existing bubbles are not replaced
  (let [html (dashboard-html (tmp-dir))]
    (is (str/includes? html "data-chat-id"))
    (is (not (str/includes? html "history.replaceChildren")))))

(deftest pack-dashboard-cards-show-im-status
  ;; Given dashboard HTML
  ;; Then cards render task.status from /api/state
  (let [html (dashboard-html (tmp-dir))]
    (is (str/includes? html "task.status"))))

(deftest pack-dashboard-html-flushes-batched-cards
  ;; When serving dashboard.html
  ;; Then a batch group has no vertical gap between its cards
  (let [html (dashboard-html (tmp-dir))]
    (is (str/includes? html "className = \"batch\""))
    (is (re-find #"\.batch\{[^}]*gap:0" html))))

(deftest pack-dashboard-cards-drop-lane-name
  ;; Given dashboard HTML
  ;; When cards are rendered
  ;; Then they do not print the agent or lane name
  (let [html (dashboard-html (tmp-dir))]
    (is (not (str/includes? html "lane.textContent = task.lane")))))

(deftest pack-dashboard-batch-only-top-card-has-status
  ;; Given dashboard HTML
  ;; When a batch is rendered
  ;; Then only the top card has a status line and the rest are thin name-only cards
  (let [html (dashboard-html (tmp-dir))]
    (is (str/includes? html "card-thin"))
    (is (str/includes? html "thin: idx > 0"))
    (is (re-find #"\.card-thin\{" html))))

(deftest pack-web-state-groups-in-process-batch-cards
  ;; Given two-pack and two cleaner in-process handoffs in one batch dir
  ;; When --test-state
  ;; Then those tasks share a batch id
  (let [root (tmp-dir)
        roles ["coder" "cleaner"]
        _ (setup-pack! root roles)
        _ (create-task root "Command syntax" "cleaner")
        _ (create-task root "validation" "cleaner")
        batch "batch_20260824T150500Z_000001"
        dir (fs/path (in-process-dir root roles "cleaner") batch)]
    (write-file (fs/path dir "50_command.handoff")
                "from: coder\nto: cleaner\npriority: 50\ntype: git_handoff\ntask: Command syntax\n\npayload\n")
    (write-file (fs/path dir "50_validation.handoff")
                "from: coder\nto: cleaner\npriority: 50\ntype: git_handoff\ntask: validation\n\npayload\n")
    (let [by-name (into {} (map (juxt :name identity) (:tasks (web-state root))))]
      (is (= (get-in by-name ["Command syntax" :batch])
             (get-in by-name ["validation" :batch])))
      (is (some? (get-in by-name ["Command syntax" :batch]))))))

(deftest pack-dashboard-new-task-alerts-on-duplicate
  ;; Given dashboard HTML
  ;; Then duplicate create keeps the dialog and alerts
  (let [html (dashboard-html (tmp-dir))]
    (is (str/includes? html "submitNewTask"))
    (is (str/includes? html "if (!res.ok)"))
    (is (str/includes? html "alert("))
    (is (str/includes? html "nt-name"))))

(deftest pack-dashboard-rejected-card-has-delete
  ;; Given dashboard HTML
  ;; Then a REJECTED card is red and can be deleted
  (let [html (dashboard-html (tmp-dir))]
    (is (str/includes? html "REJECTED"))
    (is (str/includes? html "card-rejected"))
    (is (str/includes? html "/api/tasks/delete"))))

(deftest pack-dashboard-splitter-drags-the-rail
  ;; Given dashboard HTML
  ;; Then the board/Work Queue border can be dragged
  (let [html (dashboard-html (tmp-dir))]
    (is (str/includes? html "col-resize"))
    (is (str/includes? html "pointerdown"))
    (is (str/includes? html "setProperty(\"--rail\""))))

(deftest pack-dashboard-rejected-card-has-edit-retry
  ;; Given dashboard HTML
  ;; Then a rejected card opens an edit pane with Delete and Retry
  (let [html (dashboard-html (tmp-dir))]
    (is (str/includes? html "openRejectEdit"))
    (is (str/includes? html "/api/tasks/retry"))
    (is (str/includes? html "rt-text"))
    (is (str/includes? html "Retry"))))

(deftest pack-dashboard-attention-has-clarification-row
  ;; Given dashboard HTML
  ;; Then Attention can show Request clarification with a text box
  (let [html (dashboard-html (tmp-dir))]
    (is (str/includes? html "Clarification requested from:"))
    (is (str/includes? html "data.clarifications"))
    (is (str/includes? html "/api/clarifications/"))))

(deftest pack-web-thermometer-ignores-reordered-tail
  ;; Given a pane whose last 20 lines are the same bag in a new order
  ;; When --test-heat-reorder samples both
  ;; Then activity does not rise
  (let [root (tmp-dir)
        _ (setup-pack! root ["specifier"])
        result (pack-web root false "--test-heat-reorder" (str root))
        body (json/parse-string (:out result) true)]
    (is (zero? (:exit result)))
    (is (= (:before body) (:after body)))))

(deftest pack-web-thermometer-uses-last-twenty-line-bag
  ;; Given a 25-line pane whose first five lines then change
  ;; When --test-heat-head samples both
  ;; Then activity stays at the baseline (tail bag unchanged)
  (let [root (tmp-dir)
        _ (setup-pack! root ["specifier"])
        result (pack-web root false "--test-heat-head" (str root))
        body (json/parse-string (:out result) true)]
    (is (zero? (:exit result)))
    (is (= (:before body) (:after body)))))

(deftest pack-web-card-status-is-last-im-sentence
  ;; Given a specifier card and a pane tail with an I'm sentence
  ;; When --test-state
  ;; Then that task's status is that sentence
  (let [root (tmp-dir)
        _ (setup-pack! root)
        _ (create-task root "HTW" "specifier")]
    (let [result (pack-web-env root {} "--test-status-pane" (str root)
                               "Working on HTW.\nI'm idle, so I'm running ready_for_next.sh.\nesc to interrupt · 3s\n")
          state (json/parse-string (:out result) true)
          card (first (:tasks state))]
      (is (zero? (:exit result)))
      (is (= "HTW" (:name card)))
      (is (str/includes? (str (:status card)) "I'm idle, so I'm running ready_for_next.sh")))))

(deftest pack-web-card-status-includes-continue-sentences
  ;; Given a specifier card and a pane tail whose last matching sentence uses continue
  ;; When --test-status-pane
  ;; Then that task's status is that sentence
  (let [root (tmp-dir)
        _ (setup-pack! root)
        _ (create-task root "HTW" "specifier")]
    (let [result (pack-web-env root {} "--test-status-pane" (str root)
                               "Working on HTW.\nI'll continue with the cave map.\nesc to interrupt · 3s\n")
          state (json/parse-string (:out result) true)
          card (first (:tasks state))]
      (is (zero? (:exit result)))
      (is (str/includes? (str (:status card)) "I'll continue with the cave map.")))))

(deftest pack-web-card-status-joins-wrapped-pane-lines
  ;; Given an I'll sentence split across two pane lines
  ;; When --test-status-pane
  ;; Then status is the full sentence with a space at the wrap
  (let [root (tmp-dir)
        _ (setup-pack! root)
        _ (create-task root "HTW" "specifier")]
    (let [result (pack-web-env root {} "--test-status-pane" (str root)
                               "I'll continue with the\ncave map for HTW.\n")
          card (first (:tasks (json/parse-string (:out result) true)))]
      (is (zero? (:exit result)))
      (is (str/includes? (str (:status card)) "I'll continue with the cave map for HTW.")))))

(deftest pack-web-card-status-ignores-handoff-mail-banner
  ;; Given an I'll sentence and a later If idle, run ready_for_next.sh banner
  ;; When --test-status-pane
  ;; Then status is the I'll sentence, not the mail line
  (let [root (tmp-dir)
        _ (setup-pack! root)
        _ (create-task root "HTW" "specifier")
        result (pack-web-env root {} "--test-status-pane" (str root)
                             (str "I'll commit the spec and queue the coder handoff.\n"
                                  "You have new handoff mail. If idle, run ready_for_next.sh.\n"
                                  "esc to interrupt · 1s\n"))
        state (json/parse-string (:out result) true)
        card (first (:tasks state))]
    (is (zero? (:exit result)))
    (is (str/includes? (str (:status card)) "I'll commit the spec"))
    (is (not (str/includes? (str (:status card)) "ready_for_next")))))

(deftest pack-web-grok-card-status-uses-work-not-chrome
  ;; Given a Grok pane with an I'll sentence under mail and chrome
  ;; When --test-status-pane
  ;; Then status is the I'll sentence
  (let [root (tmp-dir)
        _ (setup-pack! root)
        _ (set-backend! root "grok")
        _ (create-task root "HTW" "specifier")
        result (pack-web-env root {} "--test-status-pane" (str root)
                             (str "I'll commit the spec and queue the coder handoff.\n"
                                  "You have new handoff mail. If idle, run ready_for_next.sh.\n"
                                  "always-approve  shift+tab\n"
                                  "Waiting for response...\n"
                                  "enter:send  Esc:cancel\n"))
        state (json/parse-string (:out result) true)
        card (first (:tasks state))]
    (is (zero? (:exit result)))
    (is (str/includes? (str (:status card)) "I'll commit the spec"))
    (is (not (str/includes? (str (:status card)) "ready_for_next")))
    (is (not (str/includes? (str (:status card)) "Waiting for response")))))

(deftest pack-web-waiting-cards-say-waiting-in-queue
  ;; Given two specifier cards and a pane I'm sentence
  ;; When --test-status-pane
  ;; Then the first card has that sentence and the other says waiting in queue
  (let [root (tmp-dir)
        _ (setup-pack! root)
        _ (create-task root "HTW" "specifier")
        _ (create-task root "Holy Hand Grenade" "specifier")
        result (pack-web-env root {} "--test-status-pane" (str root)
                             "I'm specifying HTW.\nesc to interrupt · 1s\n")
        state (json/parse-string (:out result) true)
        by-name (into {} (map (juxt :name identity) (:tasks state)))]
    (is (zero? (:exit result)))
    (is (str/includes? (str (:status (get by-name "HTW"))) "I'm specifying HTW"))
    (is (= "waiting in queue" (:status (get by-name "Holy Hand Grenade"))))))

(deftest pack-web-in-process-card-gets-pane-status
  ;; Given two coder cards and in-process mail for Holy Hand Grenade
  ;; When --test-status-pane
  ;; Then Holy Hand Grenade has the pane sentence and HTW says waiting in queue
  (let [root (tmp-dir)
        roles ["specifier" "coder"]
        _ (setup-pack! root roles)
        _ (create-task root "HTW" "coder")
        _ (create-task root "Holy Hand Grenade" "coder")
        _ (put-in-process! root roles "coder"
                           {:from "specifier" :task "Holy Hand Grenade"})
        result (pack-web-env root {} "--test-status-pane" (str root)
                             "I'm merging the grenade.\nesc to interrupt · 1s\n")
        state (json/parse-string (:out result) true)
        by-name (into {} (map (juxt :name identity) (:tasks state)))]
    (is (zero? (:exit result)))
    (is (str/includes? (str (:status (get by-name "Holy Hand Grenade")))
                       "I'm merging the grenade"))
    (is (= "waiting in queue" (:status (get by-name "HTW"))))))

(deftest pack-web-pending-approval-card-says-waiting-for-approval
  ;; Given HTW in specifier and a pending specifier→coder git_handoff for HTW
  ;; When --test-state
  ;; Then HTW status is Waiting for approval
  (let [root (tmp-dir)
        _ (setup-pack! root six-pack-roles)
        _ (create-task root "HTW" "specifier")
        _ (create-task root "Command Syntax" "specifier")]
    (write-file
     (fs/path root ".swarmforge/handoffs/pending_approval/50_from_specifier_to_coder.handoff")
     "from: specifier\nto: coder\npriority: 50\ntype: git_handoff\ntask: HTW\n\npayload\n")
    (let [state (web-state root)
          by-name (into {} (map (juxt :name identity) (:tasks state)))]
      (is (= "Waiting for approval" (:status (get by-name "HTW"))))
      (is (= "waiting in queue" (:status (get by-name "Command Syntax")))))))

(deftest pack-web-rejected-card-says-rejected
  ;; Given HTW is rejected
  ;; When --test-state
  ;; Then HTW status is REJECTED
  (let [root (tmp-dir)
        _ (setup-pack! root)
        _ (create-task root "HTW" "specifier")]
    (write-file (fs/path root ".swarmforge/notify/reject-HTW") "rejected\n")
    (let [card (first (:tasks (web-state root)))]
      (is (= "REJECTED" (:status card))))))

(deftest pack-web-delete-removes-a-rejected-card
  ;; Given a rejected HTW card
  ;; When POST /api/tasks/delete
  ;; Then the card is gone from the board
  (let [root (tmp-dir)
        _ (setup-pack! root)
        _ (create-task root "HTW" "specifier")
        _ (write-file (fs/path root ".swarmforge/notify/reject-HTW") "rejected\n")
        result (pack-web root false "--test-delete-task" (str root) "HTW")]
    (is (zero? (:exit result)))
    (is (nil? (task-lane root "HTW")))
    (is (not (fs/exists? (fs/path root ".swarmforge/board/HTW.txt"))))))

(deftest pack-web-delete-rejected-purges-handoffs-into-rejected-tasks
  ;; Given a rejected HTW card with a pending git_handoff
  ;; When POST /api/tasks/delete
  ;; Then the card, notify, and handoff are gone and rejected-tasks keeps the set
  (let [root (tmp-dir)
        _ (setup-pack! root)
        _ (create-task root "HTW" "specifier")
        _ (write-file (fs/path root ".swarmforge/notify/reject-HTW") "rejected\n")
        pending (fs/path root ".swarmforge/handoffs/pending_approval/50_from_specifier_to_coder.handoff")
        _ (write-file pending
                      "from: specifier\nto: coder\ntype: git_handoff\ntask: HTW\n\npayload\n")
        result (pack-web root false "--test-delete-task" (str root) "HTW")]
    (is (zero? (:exit result)))
    (is (nil? (task-lane root "HTW")))
    (is (not (fs/exists? pending)))
    (is (not (fs/exists? (fs/path root ".swarmforge/notify/reject-HTW"))))
    (is (fs/exists? (fs/path root ".swarmforge/rejected-tasks")))))

(deftest pack-web-retry-rejected-queues-a-master-note
  ;; Given a rejected HTW card with a pending git_handoff
  ;; When POST /api/tasks/retry with edited text
  ;; Then the card stays, is not REJECTED, pending is gone, and a master note is queued
  (let [root (tmp-dir)
        _ (setup-pack! root)
        _ (create-task root "HTW" "specifier")
        _ (write-file (fs/path root ".swarmforge/notify/reject-HTW") "rejected\n")
        pending (fs/path root ".swarmforge/handoffs/pending_approval/50_hello.handoff")
        _ (write-file pending
                      "from: specifier\nto: coder\ntype: git_handoff\ntask: HTW\n\nold\n")
        result (pack-web root false "--test-retry-task" (str root) "HTW" "new payload")
        card (first (:tasks (web-state root)))
        notes (fs/list-dir (fs/path root ".swarmforge/handoffs/outbox"))
        note (slurp (str (first notes)))]
    (is (zero? (:exit result)))
    (is (= "specifier" (:lane card)))
    (is (not= "REJECTED" (:status card)))
    (is (not (fs/exists? pending)))
    (is (not (fs/exists? (fs/path root ".swarmforge/notify/reject-HTW"))))
    (is (seq notes))
    (is (str/includes? note "new payload"))
    (is (str/includes? note "to: specifier"))))

(deftest pack-web-post-task-duplicate-keeps-the-server
  ;; Given a card named HTW
  ;; When POST /api/tasks uses HTW again
  ;; Then it reports Duplicate and does not create a second card
  (let [root (tmp-dir)
        _ (setup-pack! root)
        _ (pack-web root true "--test-post-task" (str root) "HTW" "first")
        duplicate (pack-web root false "--test-post-task" (str root) "HTW" "second")
        listed (:out (list-tasks root))
        htw-rows (filter #(str/starts-with? % "HTW\t") (str/split-lines listed))]
    (is (not (zero? (:exit duplicate))))
    (is (str/includes? (str (:err duplicate) (:out duplicate)) "Duplicate"))
    (is (= 1 (count htw-rows)))))

(deftest pack-web-unknown-approval-keeps-the-server
  ;; Given a pack with no pending approval
  ;; When POST /api/approvals/missing/reject
  ;; Then it reports Unknown approval and the next request still works
  (let [root (tmp-dir)
        _ (setup-pack! root)
        result (pack-web root false "--test-reject" (str root) "no-such-id")]
    (is (not (zero? (:exit result))))
    (is (str/includes? (:out result) "error"))
    (is (str/includes? (str (:err result) (:out result)) "Unknown approval"))
    (is (zero? (:exit (pack-web root false "--test-state" (str root)))))))

(deftest pack-web-unknown-clarification-keeps-the-server
  ;; Given a pack with no pending clarification
  ;; When POST /api/clarifications/missing/answer
  ;; Then it reports Unknown clarification and the next request still works
  (let [root (tmp-dir)
        _ (setup-pack! root)
        result (pack-web root false "--test-answer-clarification"
                         (str root) "no-such-id" "nope")]
    (is (not (zero? (:exit result))))
    (is (str/includes? (:out result) "error"))
    (is (str/includes? (str (:err result) (:out result)) "Unknown clarification"))
    (is (zero? (:exit (pack-web root false "--test-state" (str root)))))))

(deftest pack-web-clarification-posts-to-attention-and-answers-into-the-role
  ;; Given QA posts a clarification question
  ;; When the operator answers
  ;; Then /api/state listed it and the answer is injected into QA with the durable id
  (let [root (tmp-dir)
        argv-file (str (fs/path root "tmux.argv"))
        question (fs/path root "tmp" "question.txt")]
    (setup-pack! root ["QA"])
    (write-file (fs/path root ".swarmforge/tmux-socket") (str (fs/path root "tmux.sock") "\n"))
    (write-file question "Does the bat drop to any of 20 rooms?\n")
    (let [created (run {:dir root :env {"SWARMFORGE_ROLE" "QA"}}
                       (script "pack_dashboard_request.sh")
                       "clarify" (str question))
          id (str/trim (:out created))
          pending (web-state root)
          item (first (:clarifications pending))]
      (is (zero? (:exit created)))
      (is (str/starts-with? id "clar-"))
      (is (= "QA" (:role item)))
      (is (str/includes? (:body item) "Does the bat drop to any of 20 rooms?"))
      (is (= "pending" (:status item)))
      (pack-web-env root {"SWARMFORGE_TMUX_STUB" argv-file}
                    "--test-answer-clarification" (str root) id "Yes, 1 to 20.")
      (let [argv (slurp argv-file)
            done (first (:clarifications (web-state root)))]
        (is (str/includes? argv id))
        (is (str/includes? argv "Yes, 1 to 20."))
        (is (= "done" (:status done)))
        (is (str/includes? (:response done) "Yes, 1 to 20."))))))

(deftest pack-web-serves-the-task-body
  ;; Given New Task HTW with body
  ;; When pack_web --test-task HTW
  ;; Then it prints the name and body
  (let [root (tmp-dir)
        text "Find the stories in ~/junk/htw-stories and implement them."]
    (setup-pack! root)
    (pack-board root true
                "create" "--root" (str root)
                "--name" "HTW" "--lane" "specifier" "--text" text)
    (let [result (pack-web root false "--test-task" (str root) "HTW")]
      (is (zero? (:exit result)))
      (is (str/includes? (:out result) "HTW"))
      (is (str/includes? (:out result) text)))))

(deftest pack-dashboard-stamps-clarification-with-the-agent
  ;; Given dashboard HTML
  ;; Then Attention names the requesting agent
  (let [html (dashboard-html (tmp-dir))]
    (is (str/includes? html "Clarification requested from:"))))

(deftest pack-dashboard-keeps-clarification-draft-across-poll
  ;; Given dashboard HTML
  ;; Then clarifications live in their own div and existing inputs are not rebuilt
  (let [html (dashboard-html (tmp-dir))]
    (is (str/includes? html "id=\"attention-clarifications\""))
    (is (str/includes? html "id=\"attention-approvals\""))
    (is (str/includes? html "data-clar-id"))
    (is (str/includes? html "renderClarifications"))
    (is (not (str/includes? html "setSelectionRange")))))

(deftest pack-dashboard-clarification-enter-submits
  ;; Given a clarification answer box
  ;; When the operator presses Enter
  ;; Then the answer is submitted
  (let [src (dashboard-js-fn (dashboard-html (tmp-dir)) "clarificationRow")]
    (is (str/includes? src "createElement(\"form\")"))
    (is (str/includes? src "addEventListener(\"submit\""))
    (is (str/includes? src "preventDefault"))
    (is (str/includes? src "postClarification"))))

(deftest pack-dashboard-keeps-documents-menu-open-across-poll
  ;; Given dashboard HTML
  ;; Then an open Documents menu is restored after loadState
  (let [html (dashboard-html (tmp-dir))]
    (is (str/includes? html "openDocMenus"))))

(deftest pack-web-card-status-matches-unicode-im-and-i-keywords
  ;; Given a pane with Unicode I’m and let me
  ;; When --test-status-pane
  ;; Then those sentences can be card status
  (let [root (tmp-dir)
        _ (setup-pack! root)
        _ (create-task root "HTW" "specifier")
        im (pack-web-env root {} "--test-status-pane" (str root)
                         "I’m merging the QA handoff.\nesc to interrupt · 1s\n")
        let-me (pack-web-env root {} "--test-status-pane" (str root)
                             "Let me inspect the conflicts.\nesc to interrupt · 1s\n")
        handoff (pack-web-env root {} "--test-status-pane" (str root)
                              "HANDOFF queued to cleaner.\nesc to interrupt · 1s\n")]
    (is (str/includes? (:out im) "merging the QA handoff"))
    (is (str/includes? (:out let-me) "Let me inspect the conflicts"))
    (is (str/includes? (:out handoff) "HANDOFF queued to cleaner"))))

(deftest pack-web-card-status-stays-until-replaced
  ;; Given a status sentence then a pane with no status keywords
  ;; When --test-status-persist
  ;; Then the first sentence remains
  (let [root (tmp-dir)
        _ (setup-pack! root)
        _ (create-task root "HTW" "specifier")
        result (pack-web-env root {} "--test-status-persist" (str root)
                             "I'm working on HTW.\n"
                             "esc to interrupt · 9s\n")
        body (json/parse-string (:out result) true)]
    (is (zero? (:exit result)))
    (is (str/includes? (str (:first body)) "I'm working on HTW"))
    (is (= (:first body) (:second body)))))

(deftest pack-web-work-queue-lists-every-in-process-task
  ;; Given two in-process handoffs on architect
  ;; When --test-state
  ;; Then the row's task is the first name and tasks lists both
  (let [root (tmp-dir)
        roles ["specifier" "architect"]]
    (setup-pack! root roles)
    (put-in-process! root roles "architect"
                     {:from "cleaner" :task "HTW"
                      :filename "10_from_cleaner_htw.handoff"})
    (put-in-process! root roles "architect"
                     {:from "cleaner" :task "Command Syntax"
                      :filename "11_from_cleaner_cs.handoff"})
    (let [row (some #(when (= "architect" (:role %)) %)
                    (:work_in_flight (web-state root)))]
      (is (= "HTW" (:task row)))
      (is (= ["HTW" "Command Syntax"] (:tasks row))))))

(deftest pack-dashboard-batch-plus-lists-tasks-on-hover
  ;; Given a work row with more than one task
  ;; When the operator hovers the +
  ;; Then a list of every task in the batch appears
  (let [html (dashboard-html (tmp-dir))
        src (dashboard-js-fn html "workRow")]
    (is (str/includes? src "item.tasks"))
    (is (str/includes? src "batch-more"))
    (is (str/includes? src "mouseenter"))
    (is (str/includes? html "batch-more"))))

(deftest pack-dashboard-keeps-work-rows-across-poll
  ;; Given dashboard HTML
  ;; Then work rows are keyed and not rebuilt when the batch is unchanged
  (let [html (dashboard-html (tmp-dir))]
    (is (str/includes? html "data-work-role"))
    (is (str/includes? html "renderWork"))
    (is (not (str/includes? html "rows.replaceChildren")))))

(deftest pack-web-thermometer-heats-on-work-after-handoff-mail
  ;; Given a Codex pane whose only cut-point used to be an old › mail line
  ;; When later transcript lines change
  ;; Then heat rises
  (let [root (tmp-dir)
        _ (setup-pack! root ["specifier"])
        result (pack-web root false "--test-heat-mail" (str root))
        body (json/parse-string (:out result) true)]
    (is (zero? (:exit result)))
    (is (< (:before body) (:after body)))))

(deftest pack-web-grok-thermometer-heats-on-waiting-timer
  ;; Given a Grok pane whose only change is Waiting for response Ns
  ;; When --test-heat-grok
  ;; Then activity rises
  (let [root (tmp-dir)
        _ (setup-pack! root ["specifier"])
        _ (set-backend! root "grok")
        result (pack-web root false "--test-heat-grok" (str root))
        body (json/parse-string (:out result) true)]
    (is (zero? (:exit result)))
    (is (< (:before body) (:after body)))))

(deftest pack-web-thermometer-heats-on-collapsed-transcript-counts
  ;; Given Codex collapsed output whose +N line changes
  ;; When --test-heat-collapse
  ;; Then heat rises
  (let [root (tmp-dir)
        _ (setup-pack! root ["specifier"])
        result (pack-web root false "--test-heat-collapse" (str root))
        body (json/parse-string (:out result) true)]
    (is (zero? (:exit result)))
    (is (< (:before body) (:after body)))))

(deftest pack-web-clarification-answer-echoes-the-question
  ;; Given QA asked a clarification
  ;; When the operator answers
  ;; Then the injected pane text includes the question and Clarification requested from
  (let [root (tmp-dir)
        argv-file (str (fs/path root "tmux.argv"))
        question (fs/path root "tmp" "question.txt")]
    (setup-pack! root ["QA"])
    (write-file (fs/path root ".swarmforge/tmux-socket") (str (fs/path root "tmux.sock") "\n"))
    (write-file question "Does the bat drop to any of 20 rooms?\n")
    (let [id (str/trim (:out (run {:dir root :env {"SWARMFORGE_ROLE" "QA"}}
                                  (script "pack_dashboard_request.sh")
                                  "clarify" (str question))))]
      (pack-web-env root {"SWARMFORGE_TMUX_STUB" argv-file}
                    "--test-answer-clarification" (str root) id "Yes, 1 to 20.")
      (let [argv (slurp argv-file)]
        (is (str/includes? argv "Clarification requested from: QA"))
        (is (str/includes? argv "Does the bat drop to any of 20 rooms?"))
        (is (str/includes? argv "Yes, 1 to 20."))))))

(defn -main [& _]
  (let [{:keys [fail error]} (run-tests 'swarmforge.pack-ui-test)]
    (System/exit (+ fail error))))
