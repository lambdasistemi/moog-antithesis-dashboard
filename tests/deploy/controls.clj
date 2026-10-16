;; Executable deployment controls: the real collector-deploy command runs
;; against disposable fixtures behind fake gh, docker and curl (fake-tool.sh)
;; and the packaged snapshot validator. Every refusal and failure path is
;; driven, not described. Real Docker, Compose and GitHub are exercised by
;; live-smoke.clj.
(require '[babashka.fs :as fs]
         '[babashka.process :as process]
         '[cheshire.core :as json]
         '[clojure.string :as str])

(def token "synthetic-deploy-token-9f3c")
(defn hex [c] (apply str (repeat 40 c)))
(defn digest [c] (str "sha256:" (apply str (repeat 64 c))))
(def new-sha (hex "a"))
(def old-sha (hex "0"))
(def other-sha (hex "b"))
(def new-digest (digest "2"))
(def old-digest (digest "1"))
(def moved-digest (digest "c"))
(def other-digest (digest "3"))
(def image-repo "ghcr.io/lambdasistemi/moog-antithesis-dashboard")
(defn image-id [d] (str "sha256:image-" (subs d 7)))
(def old-id (image-id old-digest))
(def new-id (image-id new-digest))
(def old-pin (str image-repo ":" old-sha "@" old-digest))
(def new-pin (str image-repo ":" new-sha "@" new-digest))
(defn override-with [pin]
  (str "services:\n  collector:\n    image: " pin "\n    environment:\n      STATUS_ISSUE_ORACLE: \"27\"\n"
       "volumes:\n  dashboard-cache:\n    external: true\n    name: moog-antithesis-dashboard_dashboard-cache\n"))
(def override-text (override-with old-pin))
(def failures (atom []))
(defn expect [ok? what] (when-not ok? (swap! failures conj what) (println "FAIL:" what)))

(defn write [path text] (fs/create-dirs (fs/parent path)) (spit (str path) text))
(defn job [name conclusion] {:name name :conclusion conclusion :status "completed"})
(defn good-jobs [] [(job "Build Gate" "success") (job "CI collector image" "success")
                    (job "CI reproduce evidence" "success") (job "CI PR preview" "skipped")])
(defn run-record [& {:as over}]
  (merge {:id 100 :run_attempt 1 :head_sha new-sha :head_branch "main" :event "push" :status "completed" :conclusion "success"} over))
(def example (json/parse-string (slurp "tests/snapshot.example.json") true))
(defn snapshot [generated] (json/generate-string (assoc example :generated_at generated)))
(defn behaviour-of [dir d {:keys [startup cycle pages]}]
  (write (fs/path dir "images" d "behavior") (str "startup=" startup "\ncycle=" cycle "\npages=" pages "\n"))
  (write (fs/path dir "images" d "snapshot.json") (snapshot "@GENERATED@"))
  (fs/create-dirs (fs/path dir "images" d "site"))
  (write (fs/path dir "images" d "site" "openapi.json") (slurp "site/openapi.json"))
  (write (fs/path dir "images" d "site" "index.html") (str "<html>renderer " d "</html>\n"))
  (write (fs/path dir "images" d "site" "compose.js") (str "// " d "\n")))

(defn publish-site! [dir d]
  (fs/create-dirs (fs/path dir "public"))
  (doseq [f (fs/list-dir (fs/path dir "images" d "site"))] (write (fs/path dir "public" (fs/file-name f)) (slurp (str f)))))

(defn container-row [name id configured project service] (str/join "\t" [name id configured project service]))
(def own-row (container-row "stack-collector-1" old-id old-pin "moog-antithesis-dashboard" "collector"))

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
    (behaviour-of dir moved-digest incumbent)
    (write (str dir "/snapshot.json") (snapshot "2026-10-01T00:00:00Z"))
    (write (str dir "/pages-build.json") "{\"status\":\"built\",\"updated_at\":\"2026-10-01T00:00:00Z\"}")
    (publish-site! dir old-digest)
    (write (str dir "/public/data.json") (snapshot "2026-10-01T00:00:00Z"))
    (write (str dir "/container") (str old-id " running 0\n"))
    (write (str dir "/container.log") "")
    (write (str dir "/containers") (str own-row "\n"))
    (write (str dir "/calls.log") "")
    (fs/create-dirs (str dir "/fail"))
    (fs/create-dirs stack)
    (fs/copy "compose.yaml" (str stack "/compose.yaml"))
    (write (str stack "/deployed-image.yaml") override-text)
    (fs/create-dirs (str dir "/bin"))
    (doseq [tool ["gh" "docker" "curl"] :let [stub (str dir "/bin/" tool) bash (str (fs/which "bash"))]]
      (write stub (str "#!" bash "\nFAKE_TOOL=" tool " exec " bash " " (fs/absolutize "tests/deploy/fake-tool.sh") " \"$@\"\n"))
      (fs/set-posix-file-permissions stub "rwxr-xr-x"))
    dir))

(defn fail! [dir what & [mode]] (write (str dir "/fail/" what) (or mode "always")))
(defn add-container! [dir row] (spit (str dir "/containers") (str row "\n") :append true))

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
(defn state-file [dir name] (str dir "/stack/deploy-state/" name))
(defn state [dir] (let [f (state-file dir "state.json")] (if (fs/exists? f) (json/parse-string (slurp f) true) {})))
(defn history [dir] (let [f (state-file dir "history.jsonl")] (if (fs/exists? f) (slurp f) "")))
(defn running-image [dir] (first (str/split (slurp (str dir "/container")) #" ")))

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
    (write (str dir "/stack/deploy-state/bindings.json") (json/generate-string {new-sha (digest "3")}))
    (refused "tag moved after binding" dir (deploy dir "update") 2 "tag moved")))

(defn discovery-controls []
  (let [dir (fixture {})]
    (add-container! dir (container-row "manual-collector" "sha256:image-d" (str image-repo ":main") "" ""))
    (refused "competing publisher" dir (deploy dir "update") 2 "competing publisher"))
  (let [dir (fixture {})]
    (add-container! dir (container-row "renamed" (image-id (digest "d")) (image-id (digest "d")) "" ""))
    (refused "competing publisher known only by image id" dir (deploy dir "update") 2 "competing publisher"))
  (let [dir (fixture {})]
    (add-container! dir (container-row "stack-collector-2" old-id old-pin "moog-antithesis-dashboard" "collector"))
    (refused "duplicate publishers in the project service" dir (deploy dir "update") 2 "competing publisher"))
  (let [dir (fixture {})]
    (fail! dir "ps")
    (refused "docker ps fails" dir (deploy dir "update") 2 "cannot establish the state of the host"))
  (let [dir (fixture {})]
    (fail! dir "inspect")
    (refused "docker inspect fails" dir (deploy dir "update") 2 "cannot establish the state of the host"))
  (let [dir (fixture {})]
    (fail! dir "compose-ps")
    (refused "compose ps fails" dir (deploy dir "update") 2 "cannot establish the state of the host"))
  (let [dir (fixture {})]
    (add-container! dir (container-row "web" "sha256:image-unrelated" "alpine:latest" "other" "web"))
    (let [r (deploy dir "update")]
      (expect (zero? (:exit r)) (str "unrelated container does not block: " (:all r)))
      (expect (= 1 (count (ups dir))) "unrelated container does not block the rollout"))))

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
    (expect (not (fs/exists? (state-file dir "rollout.json"))) "finished rollout leaves no in-progress marker")
    (let [again (deploy dir "update")]
      (expect (zero? (:exit again)) "repeat exits zero")
      (expect (= 1 (count (ups dir))) "repeating the same revision is a no-op")
      (expect (str/includes? (:all again) "already deployed") "repeat says already deployed"))
    (let [status (deploy dir "status")]
      (expect (zero? (:exit status)) "status exits zero")
      (expect (str/includes? (:all status) new-pin) "status shows the pinned image")
      (expect (not (str/includes? (:all status) token)) "status leaks no token"))
    ;; manual rollback: honest identity, and the reverted revision is not redeployed
    (let [back (deploy dir "rollback") s (state dir)]
      (expect (zero? (:exit back)) (str "manual rollback exit " (:exit back) ": " (:all back)))
      (expect (= override-text (override dir)) "manual rollback restores the previous pin")
      (expect (= old-id (running-image dir)) "manual rollback runs the previous image")
      (expect (= old-sha (:revision s)) "state names the restored revision")
      (expect (= old-digest (:digest s)) "state carries the restored digest, not the newer one")
      (expect (= old-pin (:ref s)) "state carries the restored pin")
      (expect (nil? (:pages s)) "newer Pages state is not kept for the restored image")
      (expect (= "healthy" (get-in s [:collector :status])) "restored collector observed healthy")
      (expect (= new-sha (get-in s [:suppressed :revision])) "reverted revision is suppressed")
      (expect (not (zero? (:exit (deploy dir "rollback")))) "second rollback has nothing to restore")
      (let [timer (deploy dir "update")]
        (expect (= 2 (:exit timer)) (str "next timer refuses the reverted revision: " (:all timer)))
        (expect (str/includes? (:all timer) "rolled back") "refusal says it was rolled back")
        (expect (= 2 (count (ups dir))) "no rollout after a manual rollback"))
      (let [retry (deploy dir "update" "--retry")]
        (expect (zero? (:exit retry)) (str "explicit retry redeploys: " (:all retry)))
        (expect (= new-id (running-image dir)) "retry runs the reverted revision again")
        (expect (nil? (:suppressed (state dir))) "retry clears the suppression"))))
  ;; a new head is not suppressed
  (let [dir (fixture {})]
    (deploy dir "update") (deploy dir "rollback")
    (write (str dir "/heads") (str other-sha "\n"))
    (write (str dir "/runs.json") (json/generate-string {:workflow_runs [(run-record :head_sha other-sha)]}))
    (write (str dir "/registry/" other-sha) other-digest)
    (behaviour-of dir other-digest {:startup "ok" :cycle "ok" :pages "ok"})
    (let [r (deploy dir "update")]
      (expect (zero? (:exit r)) (str "a new head deploys after a rollback: " (:all r)))
      (expect (= (image-id other-digest) (running-image dir)) "the new head is running"))))

(defn failure-control [name behaviour & [{:keys [retry]}]]
  (let [dir (fixture behaviour) r (deploy dir "update")]
    (expect (= 1 (:exit r)) (str name ": exit " (:exit r) " want 1: " (:all r)))
    (expect (= override-text (override dir)) (str name ": previous pin restored"))
    (expect (= old-id (running-image dir)) (str name ": previous image running"))
    (expect (= 2 (count (ups dir))) (str name ": one rollout and one rollback"))
    (expect (str/includes? (history dir) "rollback-ok") (str name ": rollback recorded"))
    (expect (= new-sha (get-in (state dir) [:last_failure :revision])) (str name ": failure recorded"))
    (expect (= old-sha (:revision (state dir))) (str name ": state names the restored revision"))
    (expect (not (fs/exists? (state-file dir "rollout.json"))) (str name ": recovered rollout leaves no marker"))
    (let [again (deploy dir "update")]
      (expect (= 2 (:exit again)) (str name ": failed revision is not retried"))
      (expect (= 2 (count (ups dir))) (str name ": no retry rollout")))
    (when (not= false retry)
      (let [retry (deploy dir "update" "--retry")]
        (expect (= 1 (:exit retry)) (str name ": explicit retry runs again"))
        (expect (= 4 (count (ups dir))) (str name ": retry rolled out and back"))))))

(defn failure-controls []
  (failure-control "startup crash" {:candidate {:startup "crash" :cycle "ok" :pages "ok"}})
  (failure-control "cycle failure" {:candidate {:startup "ok" :cycle "fail" :pages "ok"}})
  (failure-control "no new snapshot" {:candidate {:startup "ok" :cycle "stale" :pages "ok"}})
  ;; the snapshot is checked by the image's own schema and bound to the running collector
  (failure-control "unparseable generation time" {:candidate {:startup "ok" :cycle "badtime" :pages "ok"}})
  (failure-control "snapshot violating the schema" {:candidate {:startup "ok" :cycle "invalid" :pages "ok"}})
  (failure-control "snapshot the running collector did not publish" {:candidate {:startup "ok" :cycle "unpublished" :pages "ok"}})
  ;; an exception after mutation is a rollout failure, not an escape past rollback
  (let [dir (fixture {})]
    (fail! dir "logs" "once")
    (let [r (deploy dir "update")]
      (expect (= 1 (:exit r)) (str "thrown observation error: exit " (:exit r) ": " (:all r)))
      (expect (= override-text (override dir)) "thrown observation error: previous pin restored")
      (expect (= old-id (running-image dir)) "thrown observation error: previous image running")
      (expect (str/includes? (history dir) "rollback-ok") "thrown observation error: rollback recorded")
      (expect (str/includes? (get-in (state dir) [:last_failure :reason]) "exception during rollout") "thrown observation error: recorded as a failure")
      (expect (true? (get-in (state dir) [:last_failure :rolled_back])) "thrown observation error: rolled back")))
  ;; a rollback that cannot start is stated truthfully and its recovery state is kept
  (let [dir (fixture {:candidate {:startup "crash" :cycle "ok" :pages "ok"} :incumbent {:startup "crash" :cycle "ok" :pages "ok"}})
        r (deploy dir "update")]
    (expect (= 1 (:exit r)) "rollback that cannot start still fails")
    (expect (str/includes? (history dir) "rollback-failed") "failed rollback is recorded")
    (expect (not (:rolled_back (:last_failure (state dir)))) "state does not claim a rollback")
    (expect (not= "healthy" (get-in (state dir) [:collector :status])) "failed rollback never claims healthy")
    (expect (fs/exists? (state-file dir "rollout.json")) "failed rollback keeps the in-progress marker")
    (expect (fs/exists? (state-file dir "previous.json")) "failed rollback keeps the previous pin record")
    (expect (str/includes? (:all (deploy dir "status")) "rollout in progress: " ) "status shows the unfinished rollout")
    ;; once the incumbent can run, the next invocation finishes the recovery
    (behaviour-of dir old-digest {:startup "ok" :cycle "ok" :pages "ok"})
    (let [again (deploy dir "update")]
      (expect (= 2 (:exit again)) (str "recovery then refusal of the failed revision: " (:all again)))
      (expect (= old-id (running-image dir)) "recovery restores the previous image")
      (expect (not (fs/exists? (state-file dir "rollout.json"))) "recovery clears the marker")))
  ;; a rollback that starts but never publishes cannot claim healthy
  (let [dir (fixture {})]
    (deploy dir "update")
    (behaviour-of dir old-digest {:startup "ok" :cycle "fail" :pages "ok"})
    (let [back (deploy dir "rollback")]
      (expect (= 1 (:exit back)) (str "unready rollback fails: " (:all back)))
      (expect (not= "healthy" (get-in (state dir) [:collector :status])) "unready rollback never claims healthy")
      (expect (str/includes? (history dir) "rollback-failed") "unready rollback is recorded")))
  ;; a rollback that throws after a successful deployment: neither Compose failing
  ;; nor the observation failing may leave the superseded deployment claiming health
  (doseq [[what mode] [["compose-up" "always"] ["logs" "always"]]]
    (let [dir (fixture {})]
      (expect (zero? (:exit (deploy dir "update"))) (str what ": deployment succeeds first"))
      (expect (= "healthy" (get-in (state dir) [:collector :status])) (str what ": healthy before the rollback"))
      (expect (= "ok" (get-in (state dir) [:pages :status])) (str what ": pages ok before the rollback"))
      (fail! dir what mode)
      (let [back (deploy dir "rollback") s (state dir) status (deploy dir "status")]
        (expect (not (zero? (:exit back))) (str what ": throwing rollback exits nonzero: " (:all back)))
        (expect (str/includes? (history dir) "rollback-failed") (str what ": rollback-failed recorded"))
        (expect (not (str/includes? (history dir) "rollback-ok")) (str what ": no rollback-ok recorded"))
        (expect (= "unhealthy" (get-in s [:collector :status])) (str what ": collector unhealthy, got " (pr-str (:collector s))))
        (expect (str/includes? (str (get-in s [:collector :detail])) "rollback exception") (str what ": failure detail recorded"))
        (expect (nil? (:pages s)) (str what ": superseded pages state invalidated"))
        (expect (not (str/includes? (:all status) "collector: healthy")) (str what ": status never prints healthy"))
        (expect (str/includes? (:all status) "pages: unknown") (str what ": status prints no pages verdict"))
        (expect (fs/exists? (state-file dir "previous.json")) (str what ": previous pin record kept"))
        (expect (fs/exists? (state-file dir "previous-override.yaml")) (str what ": previous override kept"))
        (expect (= old-id (:image_id (json/parse-string (slurp (state-file dir "previous.json")) true))) (str what ": previous image identity unchanged")))))
  ;; a mutable tag that moved is not the image that was running
  (let [dir (fixture {:candidate {:startup "crash" :cycle "ok" :pages "ok"}})]
    (write (str dir "/stack/deployed-image.yaml") (override-with (str image-repo ":" old-sha)))
    (write (str dir "/tags/" old-sha) moved-digest)
    (let [r (deploy dir "update")]
      (expect (= 1 (:exit r)) (str "moved-tag rollback: " (:all r)))
      (expect (= old-id (running-image dir)) "rollback runs the recorded image, not what the tag now names")
      (expect (str/includes? (override dir) old-id) "rollback pins the recorded image id")))
  ;; a deployment that dies after Compose applied the rollout
  (let [dir (fixture {})]
    (write (str dir "/die-after-up") "")
    (let [r (deploy dir "update")]
      (expect (not (zero? (:exit r))) "killed deployment does not exit cleanly")
      (expect (fs/exists? (state-file dir "rollout.json")) "interrupted rollout leaves its marker")
      (expect (= new-id (running-image dir)) "interrupted rollout left the candidate running"))
    (let [again (deploy dir "update")]
      (expect (= 2 (:exit again)) (str "next invocation recovers, then refuses the interrupted revision: " (:all again)))
      (expect (= override-text (override dir)) "recovery restored the original previous pin")
      (expect (= override-text (slurp (state-file dir "previous-override.yaml"))) "the original previous pin was not overwritten")
      (expect (= old-id (running-image dir)) "recovery runs the previous image")
      (expect (str/includes? (history dir) "rollout-interrupted") "interruption recorded")
      (expect (= 2 (count (ups dir))) "recovery is one rollback, not a second rollout"))
    (expect (zero? (:exit (deploy dir "update" "--retry"))) "retry after recovery deploys")))

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
    (expect (= 1 (count (ups dir))) "pages failure triggers no rollback"))
  ;; a page that publishes only part of the renderer is not canonical
  (let [dir (fixture {:candidate {:startup "ok" :cycle "ok" :pages "partial"}}) r (deploy dir "update")]
    (expect (= 4 (:exit r)) (str "partial renderer is pending: " (:all r)))
    (expect (= new-id (running-image dir)) "partial renderer keeps the collector")
    (expect (= 1 (count (ups dir))) "partial renderer triggers no rollback"))
  ;; the renderer files of the image cannot all be inspected: no success, no partial comparison
  (let [dir (fixture {})]
    (fail! dir "sha256sum")
    (let [r (deploy dir "update")]
      (expect (= 4 (:exit r)) (str "uninspectable renderer is pending: " (:all r)))
      (expect (str/includes? (get-in (state dir) [:pages :detail]) "renderer") "uninspectable renderer is stated")
      (expect (not= "ok" (get-in (state dir) [:pages :status])) "uninspectable renderer is never ok")
      (expect (= 1 (count (ups dir))) "uninspectable renderer triggers no rollback")))
  ;; an image without index.html cannot be matched against a public page
  (let [dir (fixture {})]
    (fs/delete (fs/path dir "images" new-digest "site" "index.html"))
    (let [r (deploy dir "update")]
      (expect (= 4 (:exit r)) (str "image without index.html is pending: " (:all r)))
      (expect (str/includes? (get-in (state dir) [:pages :detail]) "index.html") "missing index.html is stated"))))

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

(defn unit-controls []
  (doseq [unit ["deploy/systemd/collector-deploy.service" "deploy/systemd/user/collector-deploy.service"]]
    (let [text (slurp unit)
          exec (second (re-find #"(?m)^ExecStart=(.*)$" text))]
      (expect (re-find #"^(/nix/var/nix/profiles/|%h/\.local/state/nix/profiles/)" (or exec "")) (str unit ": ExecStart runs the installed profile binary: " exec))
      (expect (not (re-find #"nix run|github:|flake" (or exec ""))) (str unit ": ExecStart resolves no remote code"))
      (expect (str/includes? text "LoadCredential=gh-read:") (str unit ": token arrives as a credential file"))
      (when (str/includes? unit "/user/")
        (expect (not (re-find #"(?m)^(User=|After=.*docker|Wants=network-online)" text)) (str unit ": user unit has no system-only directives"))))))

(refusal-controls)
(discovery-controls)
(success-controls)
(failure-controls)
(pages-controls)
(lock-control)
(unit-controls)
(if (seq @failures)
  (do (println (count @failures) "control failures") (System/exit 1))
  (println "deploy controls ok"))
