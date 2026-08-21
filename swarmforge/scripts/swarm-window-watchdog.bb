#!/usr/bin/env bb

(ns swarm-window-watchdog
  (:require [babashka.fs :as fs]
            [babashka.process :as process]
            [clojure.string :as str]))

(def missing-threshold 3)

(defn log! [& parts]
  (println (str (java.time.Instant/now) " " (str/join " " (map str parts))))
  (flush))

(defn sq [value]
  (str "'" (str/replace (str value) #"'" "'\"'\"'") "'"))

(defn rows [window-state-file]
  (when (fs/exists? window-state-file)
    (->> (str/split-lines (slurp (str window-state-file)))
         (remove str/blank?)
         (map #(zipmap [:index :window-id :session :title]
                       (str/split % #"\t" -1)))
         vec)))

(defn write-rows! [window-state-file window-ids-file rows]
  (spit (str window-state-file)
        (apply str
               (for [{:keys [index window-id session title]} rows]
                 (format "%s\t%s\t%s\t%s\n" index window-id session title))))
  (spit (str window-ids-file)
        (apply str (for [{:keys [window-id]} rows] (str window-id "\n")))))

(defn rewrite-window-id! [window-state-file window-ids-file target-index replacement-id]
  (write-rows! window-state-file
               window-ids-file
               (mapv #(if (= (:index %) target-index)
                        (assoc % :window-id replacement-id)
                        %)
                     (rows window-state-file))))

(defn adapter-script [script-dir working-dir tmux-socket backend command & args]
  (let [script (str "SCRIPT_DIR=" (sq (str script-dir)) "\n"
                    "WORKING_DIR=" (sq (str working-dir)) "\n"
                    "TMUX_SOCKET=" (sq tmux-socket) "\n"
                    "source " (sq (str (fs/path script-dir "swarm-terminal-adapter.sh")))
                    " && load_terminal_backend " (sq backend)
                    " && " command
                    (apply str (map #(str " " (sq %)) args)))]
    ["zsh" "-c" script]))

(defn terminal-ok? [script-dir working-dir tmux-socket backend command & args]
  (let [result (apply process/sh (concat [{:continue true}]
                                         (apply adapter-script script-dir working-dir tmux-socket backend command args)))]
    ;; A nonzero exit means either the window is really gone or the query itself
    ;; failed (Automation permission denied, stale window id). The caller only
    ;; sees a boolean, so record stderr here to tell those two cases apart.
    (when-not (zero? (:exit result))
      (log! "terminal-call-failed" command (vec args)
            "exit=" (:exit result)
            "err=" (pr-str (str/trim (str (:err result))))))
    (zero? (:exit result))))

(defn terminal-out [script-dir working-dir tmux-socket backend command & args]
  (str/trim (:out (apply process/sh (apply adapter-script script-dir working-dir tmux-socket backend command args)))))

(defn tmux-session? [tmux-socket session]
  (zero? (:exit (process/sh {:continue true} "tmux" "-S" tmux-socket "has-session" "-t" session))))

(defn kill-session! [tmux-socket session]
  (process/sh {:continue true} "tmux" "-S" tmux-socket "kill-session" "-t" session))

(defn stop-handoff-daemon! [script-dir working-dir]
  (process/sh {:continue true}
              "bb" (str (fs/path script-dir "stop_handoff_daemon.bb"))
              (str working-dir)))

(defn kill-all-sessions! [script-dir window-state-file working-dir tmux-socket backend]
  (log! "KILL-ALL-SESSIONS" "tearing down the entire swarm")
  (stop-handoff-daemon! script-dir working-dir)
  (doseq [{:keys [session]} (rows window-state-file)]
    (when-not (str/blank? session)
      (kill-session! tmux-socket session)))
  (doseq [{:keys [window-id]} (rows window-state-file)]
    (when-not (str/blank? window-id)
      (terminal-ok? script-dir working-dir tmux-socket backend "terminal_close_window" window-id))))

(defn -main [& args]
  (let [[window-state-file window-ids-file cleanup-owner-index tmux-socket working-dir backend] args
        window-state-file (fs/path window-state-file)
        window-ids-file (fs/path window-ids-file)
        backend (or backend "terminal-app")
        script-dir (fs/parent *file*)]
    (when (= "--rewrite-window-id" (first args))
      (let [[_ state ids target replacement] args]
        (rewrite-window-id! (fs/path state) (fs/path ids) target replacement)
        (System/exit 0)))
    (log! "watchdog-start"
          "backend=" backend
          "cleanup-owner-index=" (pr-str cleanup-owner-index)
          "socket=" tmux-socket
          "state=" (str window-state-file))
    (loop [missing-counts {}]
      (if-not (fs/exists? window-state-file)
        (log! "watchdog-exit" "window state file is gone:" (str window-state-file))
        (let [current-rows (rows window-state-file)
              cleanup-row (some #(when (= cleanup-owner-index (:index %)) %) current-rows)]
          (if-not (and cleanup-row (tmux-session? tmux-socket (:session cleanup-row)))
            (log! "watchdog-exit"
                  "cleanup owner row or its tmux session is missing;"
                  "row=" (pr-str cleanup-row))
            (let [cleanup-window-id (:window-id cleanup-row)]
              (if (terminal-ok? script-dir working-dir tmux-socket backend "terminal_window_exists" cleanup-window-id)
                (let [missing-counts (assoc missing-counts cleanup-owner-index 0)
                      missing-counts
                      (reduce
                       (fn [counts {:keys [index window-id session title]}]
                         (if (or (= index cleanup-owner-index)
                                 (not (tmux-session? tmux-socket session)))
                           counts
                           (if (terminal-ok? script-dir working-dir tmux-socket backend "terminal_window_exists" window-id)
                             (assoc counts index 0)
                             (let [count (inc (get counts index 0))]
                               (if (< count missing-threshold)
                                 (do
                                   (log! "window-missing" "role-index=" index "id=" window-id
                                         "strike=" (str count "/" missing-threshold))
                                   (assoc counts index count))
                                 (let [new-window-id (terminal-out script-dir working-dir tmux-socket backend
                                                                   "terminal_open_session" session title cleanup-window-id)]
                                   (log! "window-reopened" "role-index=" index "session=" session
                                         "old-id=" window-id "new-id=" (pr-str new-window-id))
                                   (when-not (str/blank? new-window-id)
                                     (rewrite-window-id! window-state-file window-ids-file index new-window-id))
                                   (assoc counts index 0)))))))
                       missing-counts
                       current-rows)]
                  (Thread/sleep 2000)
                  (recur missing-counts))
                (let [count (inc (get missing-counts cleanup-owner-index 0))]
                  (log! "cleanup-owner-window-missing" "id=" cleanup-window-id
                        "strike=" (str count "/" missing-threshold))
                  (if (>= count missing-threshold)
                    (kill-all-sessions! script-dir window-state-file working-dir tmux-socket backend)
                    (do
                      (Thread/sleep 2000)
                      (recur (assoc missing-counts cleanup-owner-index count)))))))))))))

(apply -main *command-line-args*)
