#!/usr/bin/env bb

(ns ready-for-next
  (:require [babashka.fs :as fs]
            [babashka.process :as process]))

(def script-dir (fs/parent *file*))
(load-file (str (fs/path script-dir "handoff_lib.bb")))

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
    (let [role-name (handoff-lib/role)
          mode (handoff-lib/role-receive-mode role-name)]
      (case mode
        "batch" (run-helper! "ready_for_next_batch.sh")
        "task" (run-helper! "ready_for_next_task.sh")
        (exit! 2 (str "INVALID_RECEIVE_MODE: " mode " for role " role-name))))
    (catch clojure.lang.ExceptionInfo e
      (exit! (or (:exit (ex-data e)) 1) (ex-message e)))))

(-main)
