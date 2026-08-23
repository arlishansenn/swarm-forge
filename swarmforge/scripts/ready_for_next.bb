#!/usr/bin/env bb

(ns ready-for-next
  (:require [babashka.fs :as fs]
            [babashka.process :as process]
            [handoff-lib :as hl]))

(def script-dir (fs/parent *file*))

(defn exit! [status message]
  (binding [*out* *err*]
    (println message))
  (System/exit status))

(defn run-helper! [script]
  (process/exec (str (fs/path script-dir script))))

;; handoff-lib reports failure by throwing, while this script's contract with the
;; agent is an exit code plus one line on stderr. Translate at the edge instead of
;; letting a stack trace reach the pane.
(defn -main []
  (try
    (let [mode (hl/role-receive-mode (hl/role))]
      (case mode
        "batch" (run-helper! "ready_for_next_batch.sh")
        "task" (run-helper! "ready_for_next_task.sh")
        (exit! 2 (str "INVALID_RECEIVE_MODE: " mode " for role " (hl/role)))))
    (catch clojure.lang.ExceptionInfo e
      (exit! (or (:exit (ex-data e)) 1) (ex-message e)))))

(-main)
