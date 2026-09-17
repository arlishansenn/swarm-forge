;; 最小可跑检查：在一个真 git 仓上跑 ensure-runtime-git-excludes!，
;; 断言 forge 写的 mission.md 之后不再出现在 git status 里。
(require '[babashka.fs :as fs] '[clojure.string :as str] '[babashka.process :as p])
(def tmp (str (fs/create-temp-dir)))
(p/shell {:dir tmp :out :string} "git" "init" "-q" "-b" "main")
(spit (str (fs/path tmp "f")) "x\n")
(spit (str (fs/path tmp "mission.md")) "ship the thing\n")   ; forge.bb/instantiate! 干的事
(defn status [] (:out (p/shell {:dir tmp :out :string} "git" "status" "--porcelain")))
(println "之前:" (pr-str (str/trim (status))))
(assert (str/includes? (status) "mission.md") "前置条件：mission.md 本应是脏的")
;; 复制生产实现的那一段
(defn sh-out [& args] (str/trim (:out (apply p/shell {:out :string} args))))
(defn ensure-in-file! [f line]
  (let [cur (if (fs/exists? f) (slurp (str f)) "")]
    (when-not (some #{line} (str/split-lines cur))
      (spit (str f) (str (if (or (= "" cur) (str/ends-with? cur "\n")) cur (str cur "\n")) line "\n")))))
(let [ex (fs/path (sh-out "git" "-C" tmp "rev-parse" "--git-path" "info/exclude"))
      ex (if (fs/absolute? ex) ex (fs/path tmp (str ex)))]
  (fs/create-dirs (fs/parent ex))
  (ensure-in-file! ex ".swarmforge/") (ensure-in-file! ex ".worktrees/") (ensure-in-file! ex "mission.md"))
(println "之后:" (pr-str (str/trim (status))))
(assert (not (str/includes? (status) "mission.md")) "mission.md 仍然是脏的")
(assert (str/includes? (status) "?? f") "真正的未跟踪文件不该被一起藏掉")
;; 代价：被排除的路径拒绝裸 add，要 -f
(p/shell {:dir tmp :out :string :err :string} "git" "add" "-f" "mission.md")
(assert (str/includes? (status) "A  mission.md") "git add -f 仍应可用")
(println "PASS  mission.md 被排除 / 真正的脏文件仍可见 / git add -f 仍可用")
