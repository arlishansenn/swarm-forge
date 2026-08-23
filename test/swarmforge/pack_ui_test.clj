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

(defn queue-handoff! [root {:keys [from to task artifacts]}]
  (write-file
   (fs/path root ".swarmforge/handoffs/outbox"
            (str "50_from_" from "_to_" (str/replace to #"," "_") ".handoff"))
   (str "from: " from "\n"
        "to: " to "\n"
        "priority: 50\n"
        "type: git_handoff\n"
        "task: " task "\n"
        (when artifacts (str "artifacts: " artifacts "\n"))
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

(deftest handoffd-marks-the-task-card-done-for-multi-recipient-handoff
  ;; Given card htw-console-app in QA
  ;; When a git_handoff QA→specifier,coder,cleaner,architect,hardender is delivered
  ;; Then the card lane is done
  (let [root (tmp-dir)
        roles ["QA" "specifier" "coder" "cleaner" "architect" "hardender"]
        to "specifier,coder,cleaner,architect,hardender"
        sock (do (setup-pack! root roles)
                 (create-task root "htw-console-app" "QA")
                 (queue-handoff! root {:from "QA" :to to :task "htw-console-app"})
                 (start-tmux! root roles))]
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
    (is (= [{:name "htw-console-app" :lane "specifier" :updated_at updated}]
           (:tasks state)))
    (is (= [] (:approvals state)))
    (is (= six-pack-roles (mapv :role (:work_in_flight state))))))

(defn dashboard-html [root]
  (:out (pack-web root true "--test-html")))

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

(deftest pack-web-post-task-injects-payload-into-master-session
  ;; Given a tmux argv stub
  ;; When POST /api/tasks records name and text
  ;; Then the card is created and inject-master! send-keys the Task payload
  (let [root (tmp-dir)
        argv-file (str (fs/path root "tmux.argv"))
        sock (str (fs/path root "tmux.sock"))
        text example-task-text]
    (setup-pack! root)
    (write-file (fs/path root ".swarmforge/tmux-socket") (str sock "\n"))
    (let [result (pack-web-env root {"SWARMFORGE_TMUX_STUB" argv-file}
                               "--test-post-task" (str root) "htw-console-app" text)
          argv (read-argv argv-file)]
      (is (zero? (:exit result)))
      (is (= "specifier" (task-lane root "htw-console-app")))
      (is (= example-task-payload (last (first argv))))
      (is (= ["-H" "0d"] (take-last 2 (second argv))))
      (is (= 2 (count argv))))))

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
      (is (= text (last (first argv))))
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
    (is (str/includes? html "/agent/"))
    (is (str/includes? html "setInterval(loadState"))
    (is (str/includes? html "id=\"error\""))
    (is (str/includes? html "Swarm disconnected"))
    (is (not (str/includes? html "Open SL")))
    (is (not (str/includes? html "sl-therm")))
    (is (not (str/includes? html "merger")))))

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
    (write-file (fs/path root ".swarmforge/sessions/coder/cave-walk/pane.txt") text)
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
      (let [pane (pane-path root "coder" "htw-console-app")]
        (is (fs/exists? pane))
        (is (= "pane\n" (slurp (str pane)))))
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
      (is (= "pane\n" (slurp (str (pane-path root "coder" "htw-console-app")))))
      (is (not (fs/exists? (pane-path root "done" "already-done")))))))

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
      (is (= "pane\n" (slurp (str (pane-path root "coder" "htw-console-app"))))))))

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

(defn -main [& _]
  (let [{:keys [fail error]} (run-tests 'swarmforge.pack-ui-test)]
    (System/exit (+ fail error))))
