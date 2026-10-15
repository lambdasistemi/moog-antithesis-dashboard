;; Executable deployment controls: the real collector-deploy command runs
;; against disposable fixtures behind fake gh, docker and curl (fake-tool.sh).
;; Every refusal and failure path is driven, not described.
(require '[babashka.fs :as fs]
         '[babashka.process :as process]
         '[cheshire.core :as json]
         '[clojure.string :as str])

(def token "synthetic-deploy-token-9f3c")
(def new-sha (apply str (repeat 40 "a")))
(def old-sha (apply str (repeat 40 "0")))
(def other-sha (apply str (repeat 40 "b")))
(def new-digest (str "sha256:" (apply str (repeat 64 "2"))))
(def old-digest (str "sha256:" (apply str (repeat 64 "1"))))
(def image-repo "ghcr.io/lambdasistemi/moog-antithesis-dashboard")
(def old-pin (str image-repo ":" old-sha "@" old-digest))
(def new-pin (str image-repo ":" new-sha "@" new-digest))
(def override-text
  (str "services:\n  collector:\n    image: " old-pin "\n    environment:\n      STATUS_ISSUE_ORACLE: \"27\"\n"
       "volumes:\n  dashboard-cache:\n    external: true\n    name: moog-antithesis-dashboard_dashboard-cache\n"))
(def failures (atom []))
(defn expect [ok? what] (when-not ok? (swap! failures conj what) (println "FAIL:" what)))

(defn write [path text] (fs/create-dirs (fs/parent path)) (spit (str path) text))
(defn job [name conclusion] {:name name :conclusion conclusion :status "completed"})
(defn good-jobs [] [(job "Build Gate" "success") (job "CI collector image" "success")
                    (job "CI reproduce evidence" "success") (job "CI PR preview" "skipped")])
(defn run-record [& {:as over}]
  (merge {:id 100 :run_attempt 1 :head_sha new-sha :head_branch "main" :event "push" :status "completed" :conclusion "success"} over))
(defn snapshot [generated]
  (json/generate-string {:generated_at generated :tenant "amaru-cardano" :sources {:antithesis {:status "ok"}} :runs []}))
(defn behaviour-of [dir digest {:keys [startup cycle pages]}]
  (write (fs/path dir "images" digest "behavior") (str "startup=" startup "\ncycle=" cycle "\npages=" pages "\n"))
  (write (fs/path dir "images" digest "snapshot.json") (str/replace (snapshot "@GENERATED@") "@GENERATED@" "@GENERATED@"))
  (write (fs/path dir "images" digest "site" "index.html") (str "<html>renderer " digest "</html>\n"))
  (write (fs/path dir "images" digest "site" "compose.js") (str "// " digest "\n")))

(defn publish-site! [dir digest]
  (fs/create-dirs (fs/path dir "public"))
  (doseq [f (fs/list-dir (fs/path dir "images" digest "site"))] (fs/copy f (fs/path dir "public" (fs/file-name f)) {:replace-existing true})))

(defn fixture [{:keys [candidate incumbent runs jobs heads registry-new]
                :or {candidate {:startup "ok" :cycle "ok" :pages "ok"} incumbent {:startup "ok" :cycle "ok" :pages "ok"}
                     runs [(run-record)] jobs (good-jobs) heads [new-sha] registry-new true}}]
  (let [dir (str (fs/create-temp-dir {:prefix "deploy-control-"}))
        stack (str dir "/stack")]
    (write (str dir "/token") (str token "\n"))
    (write (str dir "/heads") (str (str/join "\n" heads) "\n"))
    (write (str dir "/runs.json") (json/generate-string {:workflow_runs runs}))
    (write (str dir "/jobs.json") (json/generate-string {:jobs jobs}))
    (write (str dir "/registry/" old-sha) old-digest)
    (when registry-new (write (str dir "/registry/" new-sha) new-digest))
    (behaviour-of dir new-digest candidate)
    (behaviour-of dir old-digest incumbent)
    (write (str dir "/snapshot.json") (snapshot "2026-10-01T00:00:00Z"))
    (write (str dir "/pages-build.json") "{\"status\":\"built\",\"updated_at\":\"2026-10-01T00:00:00Z\"}")
    (publish-site! dir old-digest)
    (write (str dir "/public/data.json") (snapshot "2026-10-01T00:00:00Z"))
    (write (str dir "/container") (str "sha256:image-" (apply str (repeat 64 "1")) " running 0\n"))
    (write (str dir "/containers") (str "stack-collector-1\t" old-pin "\tmoog-antithesis-dashboard\tcollector\n"))
    (write (str dir "/calls.log") "")
    (fs/create-dirs stack)
    (fs/copy "compose.yaml" (str stack "/compose.yaml"))
    (write (str stack "/deployed-image.yaml") override-text)
    (fs/create-dirs (str dir "/bin"))
    (doseq [tool ["gh" "docker" "curl"] :let [stub (str dir "/bin/" tool) bash (str (fs/which "bash"))]]
      (write stub (str "#!" bash "\nFAKE_TOOL=" tool " exec " bash " " (fs/absolutize "tests/deploy/fake-tool.sh") " \"$@\"\n"))
      (fs/set-posix-file-permissions stub "rwxr-xr-x"))
    dir))

(def bb (str (fs/which "bb")))
(defn deploy [dir & args]
  (let [r @(process/process (into (if-let [command (System/getenv "DEPLOY_COMMAND")]
                                    [command]
                                    [bb "-cp" (or (System/getenv "DEPLOY_SRC") "host/src") "-m" "dashboard.deploy"])
                                  args)
                            {:out :string :err :string :in ""
                             :extra-env {"PATH" (str dir "/bin:" (System/getenv "PATH")) "FIXTURE" dir
                                         "DEPLOY_STACK_DIR" (str dir "/stack") "DEPLOY_PROJECT" "moog-antithesis-dashboard"
                                         "DEPLOY_GH_TOKEN_FILE" (str dir "/token") "DEPLOY_PAGES_URL" "http://pages.invalid/"
                                         "DEPLOY_STARTUP_SECONDS" "2" "DEPLOY_STABLE_SECONDS" "0" "DEPLOY_SNAPSHOT_SECONDS" "2"
                                         "DEPLOY_PAGES_SECONDS" "2" "DEPLOY_POLL_SECONDS" "0"}})]
    (assoc (select-keys r [:exit :out :err]) :all (str (:out r) (:err r)))))
(defn calls [dir] (str/split-lines (slurp (str dir "/calls.log"))))
(defn ups [dir] (filter #(re-find #"^docker compose .* up " %) (calls dir)))
(defn override [dir] (slurp (str dir "/stack/deployed-image.yaml")))
(defn state [dir] (json/parse-string (slurp (str dir "/stack/deploy-state/state.json")) true))
(defn history [dir] (let [f (str dir "/stack/deploy-state/history.jsonl")] (if (fs/exists? f) (slurp f) "")))
(defn running-image [dir] (first (str/split (slurp (str dir "/container")) #" ")))
(def old-id (str "sha256:image-" (apply str (repeat 64 "1"))))
(def new-id (str "sha256:image-" (apply str (repeat 64 "2"))))

(defn refused [name dir r code reason]
  (expect (= code (:exit r)) (str name ": exit " (:exit r) " want " code ": " (:all r)))
  (expect (empty? (ups dir)) (str name ": rollout started"))
  (expect (= override-text (override dir)) (str name ": override changed"))
  (expect (str/includes? (:all r) reason) (str name ": reason missing: " reason)))

(defn refusal-controls []
  (let [dir (fixture {:runs [(run-record :event "pull_request")]})]
    (refused "pull request run only" dir (deploy dir "update") 3 "no push CI run"))
  (let [dir (fixture {:heads [new-sha]})]
    (refused "pull request revision" dir (deploy dir "update" "--revision" other-sha) 2 "superseded or not on main"))
  (let [dir (fixture {:runs [(run-record :conclusion "failure")]})]
    (refused "failed CI" dir (deploy dir "update") 2 "concluded failure"))
  (let [dir (fixture {:runs [(run-record :status "in_progress" :conclusion nil)]})]
    (refused "pending CI" dir (deploy dir "update") 3 "in_progress"))
  (let [dir (fixture {:runs [(run-record :id 99 :conclusion "success") (run-record :id 100 :conclusion "failure")]})]
    (refused "newest attempt failed" dir (deploy dir "update") 2 "concluded failure"))
  (let [dir (fixture {:jobs (conj (vec (butlast (good-jobs))) (job "CI reproduce evidence" "cancelled"))})]
    (refused "unsuccessful job under green run" dir (deploy dir "update") 2 "not successful"))
  (let [dir (fixture {:jobs [(job "Build Gate" "success")]})]
    (refused "required job absent" dir (deploy dir "update") 2 "required jobs"))
  (let [dir (fixture {:heads [new-sha other-sha]})]
    (refused "head moved during selection" dir (deploy dir "update") 2 "main moved"))
  (let [dir (fixture {:registry-new false})]
    (refused "image not published" dir (deploy dir "update") 2 "published image missing"))
  (let [dir (fixture {})]
    (write (str dir "/stack/deploy-state/bindings.json") (json/generate-string {new-sha (str "sha256:" (apply str (repeat 64 "3")))}))
    (refused "tag moved after binding" dir (deploy dir "update") 2 "tag moved"))
  (let [dir (fixture {})]
    (spit (str dir "/containers") (str "manual-collector\t" image-repo ":main\t\t\n") :append true)
    (refused "competing publisher" dir (deploy dir "update") 2 "competing publisher")))

(defn success-controls []
  (let [dir (fixture {}) compose-before (slurp (str dir "/stack/compose.yaml"))
        r (deploy dir "update") gh-calls (filter #(str/starts-with? % "gh ") (calls dir))]
    (expect (zero? (:exit r)) (str "rollout exit " (:exit r) ": " (:all r)))
    (expect (= (str/replace override-text old-pin new-pin) (override dir)) "override changes only the image pin")
    (expect (= compose-before (slurp (str dir "/stack/compose.yaml"))) "compose.yaml untouched")
    (expect (= new-id (running-image dir)) "running image is the selected digest")
    (expect (= 1 (count (ups dir))) "exactly one rollout")
    (expect (every? #(and (str/includes? % "--no-deps") (str/ends-with? % " collector")) (ups dir)) "only the collector service is recreated")
    (expect (not-any? #(re-find #"compose .* (down|rm|stop|kill)|volume|prune|-v\b" %) (calls dir)) "cache and mounts never touched")
    (expect (every? #(str/includes? % " api repos/") gh-calls) "only GitHub API reads")
    (expect (not-any? #(re-find #"(-X|--method|-f|-F|--field|--input)\b" %) gh-calls) "no GitHub mutation, no Pages reset")
    (expect (not (str/includes? (str/join "\n" (calls dir)) token)) "token never in process arguments")
    (expect (not (str/includes? (:all r) token)) "token never in output")
    (expect (not (str/includes? (history dir) token)) "token never in the history")
    (expect (= "healthy" (get-in (state dir) [:collector :status])) "collector healthy recorded")
    (expect (= "ok" (get-in (state dir) [:pages :status])) "pages ok recorded")
    (expect (= new-digest (:digest (state dir))) "digest bound in state")
    (let [again (deploy dir "update")]
      (expect (zero? (:exit again)) "repeat exits zero")
      (expect (= 1 (count (ups dir))) "repeating the same revision is a no-op")
      (expect (str/includes? (:all again) "already deployed") "repeat says already deployed"))
    (let [status (deploy dir "status")]
      (expect (zero? (:exit status)) "status exits zero")
      (expect (str/includes? (:all status) new-pin) "status shows the pinned image")
      (expect (not (str/includes? (:all status) token)) "status leaks no token"))
    (let [back (deploy dir "rollback")]
      (expect (zero? (:exit back)) (str "manual rollback exit " (:exit back) ": " (:all back)))
      (expect (= override-text (override dir)) "manual rollback restores the previous pin")
      (expect (= old-id (running-image dir)) "manual rollback runs the previous image")
      (expect (not (zero? (:exit (deploy dir "rollback")))) "second rollback has nothing to restore"))))

(defn failure-control [name behaviour]
  (let [dir (fixture behaviour) r (deploy dir "update")]
    (expect (= 1 (:exit r)) (str name ": exit " (:exit r) " want 1: " (:all r)))
    (expect (= override-text (override dir)) (str name ": previous pin restored"))
    (expect (= old-id (running-image dir)) (str name ": previous image running"))
    (expect (= 2 (count (ups dir))) (str name ": one rollout and one rollback"))
    (expect (str/includes? (history dir) "rollback-ok") (str name ": rollback recorded"))
    (expect (= new-sha (get-in (state dir) [:last_failure :revision])) (str name ": failure recorded"))
    (let [again (deploy dir "update")]
      (expect (= 2 (:exit again)) (str name ": failed revision is not retried"))
      (expect (= 2 (count (ups dir))) (str name ": no retry rollout")))
    (let [retry (deploy dir "update" "--retry")]
      (expect (= 1 (:exit retry)) (str name ": explicit retry runs again"))
      (expect (= 4 (count (ups dir))) (str name ": retry rolled out and back")))))

(defn failure-controls []
  (failure-control "startup crash" {:candidate {:startup "crash" :cycle "ok" :pages "ok"}})
  (failure-control "cycle failure" {:candidate {:startup "ok" :cycle "fail" :pages "ok"}})
  (failure-control "no new snapshot" {:candidate {:startup "ok" :cycle "stale" :pages "ok"}})
  (let [dir (fixture {:candidate {:startup "crash" :cycle "ok" :pages "ok"} :incumbent {:startup "crash" :cycle "ok" :pages "ok"}})
        r (deploy dir "update")]
    (expect (= 1 (:exit r)) "rollback that cannot start still fails")
    (expect (str/includes? (history dir) "rollback-failed") "failed rollback is recorded")
    (expect (not (:rolled_back (:last_failure (state dir)))) "state does not claim a rollback")))

(defn pages-controls []
  (let [dir (fixture {:candidate {:startup "ok" :cycle "ok" :pages "pending"}}) r (deploy dir "update")]
    (expect (= 4 (:exit r)) (str "pages pending exit " (:exit r) ": " (:all r)))
    (expect (= new-id (running-image dir)) "pages pending keeps the new collector")
    (expect (= 1 (count (ups dir))) "pages pending triggers no rollback")
    (expect (= "healthy" (get-in (state dir) [:collector :status])) "collector reported healthy")
    (expect (= "pending" (get-in (state dir) [:pages :status])) "pages reported pending")
    (expect (not-any? #(re-find #"(-X|--method|DELETE|--input)" %) (calls dir)) "pages never reset")
    (publish-site! dir new-digest)
    (spit (str dir "/public/data.json") (slurp (str dir "/snapshot.json")))
    (let [again (deploy dir "update")]
      (expect (zero? (:exit again)) (str "pages recovery exit " (:exit again) ": " (:all again)))
      (expect (= 1 (count (ups dir))) "pages recovery re-observes without redeploying")
      (expect (= "ok" (get-in (state dir) [:pages :status])) "pages recovered")))
  (let [dir (fixture {:candidate {:startup "ok" :cycle "ok" :pages "failed"}}) r (deploy dir "update")]
    (expect (= 5 (:exit r)) (str "pages failed exit " (:exit r) ": " (:all r)))
    (expect (= new-id (running-image dir)) "pages failure keeps the new collector")
    (expect (= "failed" (get-in (state dir) [:pages :status])) "pages reported failed")
    (expect (= 1 (count (ups dir))) "pages failure triggers no rollback")))

(defn lock-control []
  (let [dir (fixture {})
        holder (process/process [bb "-e" (str "(import '[java.nio.channels FileChannel] '[java.nio.file StandardOpenOption Paths OpenOption]) "
                                              "(let [c (FileChannel/open (Paths/get \"" dir "/stack/deploy-state/lock\" (into-array String []))"
                                              " (into-array OpenOption [StandardOpenOption/CREATE StandardOpenOption/WRITE]))] (.lock c) (println \"held\") (flush) (Thread/sleep 6000))")]
                               {:out :pipe :err :string})]
    (fs/create-dirs (str dir "/stack/deploy-state"))
    (.readLine (java.io.BufferedReader. (java.io.InputStreamReader. (:out holder))))
    (let [r (deploy dir "update")]
      (expect (zero? (:exit r)) "busy run exits zero")
      (expect (str/includes? (:all r) "another deployment is running") "busy run reports the lock")
      (expect (empty? (ups dir)) "serialized: no competing rollout")
      (expect (empty? (filter #(str/starts-with? % "gh ") (calls dir))) "serialized: no work done while locked"))
    (.destroy (:proc holder))))

(refusal-controls)
(success-controls)
(failure-controls)
(pages-controls)
(lock-control)
(if (seq @failures)
  (do (println (count @failures) "control failures") (System/exit 1))
  (println "deploy controls ok"))
