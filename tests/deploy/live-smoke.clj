;; Live-boundary smoke for collector-deploy: the packaged command against REAL
;; Docker and Compose, plus read-only GitHub reality. Disposable throughout:
;; its own registry, Compose project, volume and stack directory; the
;; collector runs the real image offline (network none, no secrets) and
;; publishes to a git remote inside the disposable cache volume. Only the
;; GitHub answers for synthetic revisions are stubbed (the revisions do not
;; exist upstream); part A below asks the real GitHub instead.
;;
;; Environment: DEPLOY_COMMAND (the packaged command), DEPLOY_VALIDATOR,
;; SMOKE_IMAGE_ARCHIVE (the Nix-built collector image), and a GitHub read
;; token in SMOKE_GH_TOKEN_FILE or GH_TOKEN. Cleanup removes exactly what
;; this run created.
(require '[babashka.fs :as fs]
         '[babashka.process :as process]
         '[cheshire.core :as json]
         '[clojure.string :as str]
         '[dashboard.deploy :as d])

(def run-id (str "deploy-smoke-" (subs (str (random-uuid)) 0 8)))
(def failures (atom []))
(defn expect [ok? what]
  (println (if ok? "  ok  " "  FAIL") what)
  (when-not ok? (swap! failures conj what)))
(defn env [k] (System/getenv k))
(defn sh [& args]
  (let [r @(process/process (vec args) {:out :string :err :string :in ""})]
    (assoc (select-keys r [:exit :out :err]) :all (str (:out r) (:err r)))))
(defn docker [& args] (apply sh "docker" args))
(defn must [r what] (when-not (zero? (:exit r)) (throw (ex-info (str what ": " (:all r)) {}))) (str/trim (:out r)))

(def owned (atom {:containers [] :images [] :dirs []}))
(defn own! [k v] (swap! owned update k conj v) v)

;; ---- part A: real GitHub, read-only --------------------------------------

(defn token-file []
  (cond (env "SMOKE_GH_TOKEN_FILE") (env "SMOKE_GH_TOKEN_FILE")
        (env "GH_TOKEN") (let [dir (own! :dirs (str (fs/create-temp-dir {:prefix (str run-id "-token-")})))
                               f (str dir "/token")]
                           (spit f (env "GH_TOKEN")) (fs/set-posix-file-permissions f "rw-------") f)
        :else (throw (ex-info "no GitHub read token: set SMOKE_GH_TOKEN_FILE or GH_TOKEN" {}))))

(defn github-reality! [base-image]
  (println "== A. real GitHub (read-only) and the image's own schema")
  (let [cfg (assoc (d/config) :token-file (token-file) :state (str (fs/create-temp-dir {:prefix (str run-id "-state-")})))
        repo (:repo cfg)
        selection (d/select-revision cfg nil)]
    (own! :dirs (:state cfg))
    (println "  selection for the live head:" (pr-str (select-keys selection [:revision :run :refused :reason])))
    (expect (or (re-matches #"[0-9a-f]{40}" (str (:revision selection)))
                (and (#{:ci-pending :refused} (:refused selection)) (string? (:reason selection))))
            "select-revision parses the live Actions API into a selection or a stated refusal")
    (let [runs (d/gh-json cfg (str "repos/" repo "/actions/workflows/" (:workflow cfg) "/runs?branch=" (:branch cfg) "&event=push&status=success&per_page=1"))
          run (first (:workflow_runs runs))
          jobs (:jobs (d/gh-json cfg (str "repos/" repo "/actions/runs/" (:id run) "/jobs?per_page=100&filter=latest")))
          by-name (into {} (map (juxt :name :conclusion) jobs))]
      (expect (some? run) "the live API lists a successful push run on main")
      (println "  latest successful main run:" (:id run) (:head_sha run) "jobs:" (pr-str by-name))
      (expect (every? #(= "success" (by-name %)) (:required-jobs cfg))
              (str "the live run reports the required jobs " (pr-str (:required-jobs cfg)) " as success")))
    (let [build (try (d/gh-json cfg (str "repos/" repo "/pages/builds/latest")) (catch Exception e {:unreadable (ex-message e)}))]
      (println "  pages build keys:" (pr-str (sort (map name (keys build)))) "status:" (:status build))
      (expect (or (and (string? (:status build)) (d/instant (:updated_at build))) (:unreadable build))
              "the Pages builds API answers with a status and timestamp, or is unreadable with this token")
      (when (:unreadable build) (println "  NOTE: Pages builds API not readable with this token; shape not inspected")))
    (let [snapshot (d/gh cfg (str "repos/" repo "/contents/data.json?ref=gh-pages") "-H" "Accept: application/vnd.github.raw")
          problem (d/snapshot-problem cfg base-image snapshot)]
      (expect (nil? problem) (str "the live gh-pages snapshot validates under the candidate image's schema" (when problem (str ": " problem))))
      (let [public (d/fetch-public cfg "data.json")]
        (expect (and public (nil? (d/snapshot-problem cfg base-image (String. public))))
                "the public Pages data.json validates under the candidate image's schema")))))

;; ---- part B: real Docker and Compose -------------------------------------

(def sha {:old (apply str (repeat 40 "1")) :good (apply str (repeat 40 "2"))
          :crash (apply str (repeat 40 "3")) :fail (apply str (repeat 40 "4"))})

(defn write-executable! [path text]
  (spit path text) (fs/set-posix-file-permissions path "rwxr-xr-x"))

(defn stubs! [dir]
  (let [bin (str dir "/bin")]
    (fs/create-dirs bin)
    ;; GitHub answers for synthetic revisions; the snapshot and Pages content are
    ;; read for real from the gh-pages branch the collector published.
    (write-executable! (str bin "/gh")
                       (str "#!/usr/bin/env bash\nset -euo pipefail\nhead=$(cat \"$SMOKE_DIR/head\")\n"
                            "case $2 in\n"
                            "*/branches/*) printf '{\"commit\":{\"sha\":\"%s\"}}\\n' \"$head\" ;;\n"
                            "*/workflows/*/runs*) printf '{\"workflow_runs\":[{\"id\":1,\"run_attempt\":1,\"head_sha\":\"%s\",\"head_branch\":\"main\",\"event\":\"push\",\"status\":\"completed\",\"conclusion\":\"success\"}]}\\n' \"$head\" ;;\n"
                            "*/actions/runs/*/jobs*) printf '{\"jobs\":[{\"name\":\"CI collector image\",\"conclusion\":\"success\"},{\"name\":\"CI reproduce evidence\",\"conclusion\":\"success\"}]}\\n' ;;\n"
                            "*/contents/data.json*) \"$SMOKE_SHOW\" data.json ;;\n"
                            "*/pages/builds/latest) printf '{\"status\":\"built\",\"updated_at\":\"2000-01-01T00:00:00Z\"}\\n' ;;\n"
                            "*) exit 1 ;;\nesac\n"))
    (write-executable! (str bin "/curl")
                       (str "#!/usr/bin/env bash\nset -euo pipefail\nout=\nurl=\n"
                            "while (($#)); do case $1 in -o) out=$2; shift ;; http*) url=$1 ;; esac; shift; done\n"
                            "\"$SMOKE_SHOW\" \"${url##*/}\" >\"$out\" || exit 22\n"))
    (write-executable! (str dir "/show")
                       (str "#!/usr/bin/env bash\nset -euo pipefail\n"
                            "exec docker run --rm --network none -v \"$SMOKE_VOLUME:/cache:ro\" --entrypoint /bin/git \"$SMOKE_IMAGE\" "
                            "--git-dir=/cache/remote.git show \"gh-pages:$1\"\n"))
    bin))

(defn build-scenario! [repo base label dockerfile-lines]
  (let [tag (str repo ":" (sha label))
        dockerfile (str/join "\n" (into [(str "FROM " base) (str "LABEL smoke.scenario=" (name label))] dockerfile-lines))
        r @(process/process ["docker" "build" "-q" "-t" tag "-"] {:in dockerfile :out :string :err :string})]
    (when-not (zero? (:exit r)) (throw (ex-info (str "docker build " label ": " (:err r)) {})))
    (own! :images tag)
    (must (docker "push" "-q" tag) (str "push " label))
    tag))

(defn docker-smoke! [base-image]
  (println "== B. real Docker and Compose: pull, digest, --pull never, rollout and rollback")
  (let [dir (own! :dirs (str (fs/create-temp-dir {:prefix (str run-id "-")})))
        registry (own! :containers (str run-id "-registry"))
        _ (must (docker "run" "-d" "--name" registry "-p" "127.0.0.1::5000" "registry:2") "registry")
        port (second (re-find #":(\d+)\s*$" (first (str/split-lines (must (docker "port" registry "5000/tcp") "registry port")))))
        repo (str "localhost:" port "/smoke-collector")
        _ (Thread/sleep 1500)
        stack (str dir "/stack") project run-id volume (str project "_cache")
        base (own! :images (str run-id "-base:image"))]
    (must (docker "tag" base-image base) "tag base")
    (build-scenario! repo base :old [])
    (build-scenario! repo base :good [])
    (build-scenario! repo base :crash ["CMD [\"/bin/false\"]"])
    (build-scenario! repo base :fail ["ENV CYCLE_CMD=/bin/false"])
    (fs/create-dirs stack)
    (spit (str stack "/compose.yaml")
          (str "services:\n  collector:\n    image: unused:placeholder\n    restart: unless-stopped\n    user: \"1000:1000\"\n"
               "    read_only: true\n    tmpfs:\n      - /tmp\n    cap_drop:\n      - ALL\n    network_mode: none\n"
               "    environment:\n      DASHBOARD_CACHE: /cache\n      DASHBOARD_REMOTE: file:///cache/remote.git\n"
               "      PAGES_PUSH_TOKEN_FILE: /cache/pages-push\n      DASHBOARD_INTERVAL: \"3600\"\n"
               "    volumes:\n      - cache:/cache\nvolumes:\n  cache:\n"))
    (let [pull (must (docker "pull" "-q" (str repo ":" (:old sha))) "pull old")
          old-digest (re-find #"sha256:[0-9a-f]{64}" (must (docker "image" "inspect" "--format" "{{json .RepoDigests}}" (str repo ":" (:old sha))) "old digest"))
          old-pin (str repo ":" (:old sha) "@" old-digest)]
      (spit (str stack "/deployed-image.yaml") (str "services:\n  collector:\n    image: " old-pin "\n"))
      (let [compose (fn [& args] (apply docker "compose" "--project-directory" stack "-p" project "-f" (str stack "/compose.yaml") "-f" (str stack "/deployed-image.yaml") args))
            old-id (must (docker "image" "inspect" "--format" "{{.Id}}" old-pin) "old id")]
        (try
          (must (compose "up" "--no-start" "--no-build" "--pull" "never" "collector") "create incumbent")
          (must (docker "run" "--rm" "-v" (str volume ":/cache") "--entrypoint" "/bin/bash" base-image "-c"
                        "printf smoke-not-a-credential >/cache/pages-push && git init --bare -q /cache/remote.git")
                "initialise the disposable remote")
          (must (compose "up" "-d" "--no-build" "--pull" "never" "collector") "start incumbent")
          (let [bin (stubs! dir)
                run (fn [head & args]
                      (spit (str dir "/head") head)
                      (let [token (str dir "/gh-token")
                            _ (spit token "smoke-fake-token")
                            r @(process/process (into [(env "DEPLOY_COMMAND")] args)
                                                {:out :string :err :string :in ""
                                                 :extra-env {"PATH" (str bin ":" (env "PATH"))
                                                             "SMOKE_DIR" dir "SMOKE_SHOW" (str dir "/show") "SMOKE_VOLUME" volume "SMOKE_IMAGE" base-image
                                                             "DEPLOY_STACK_DIR" stack "DEPLOY_PROJECT" project "DEPLOY_IMAGE_REPOSITORY" repo
                                                             "DEPLOY_GH_TOKEN_FILE" token "DEPLOY_PAGES_URL" "http://pages.invalid/"
                                                             "DEPLOY_STARTUP_SECONDS" "90" "DEPLOY_STABLE_SECONDS" "5"
                                                             "DEPLOY_SNAPSHOT_SECONDS" "240" "DEPLOY_PAGES_SECONDS" "60" "DEPLOY_POLL_SECONDS" "2"}})]
                        (assoc (select-keys r [:exit :out :err]) :all (str (:out r) (:err r)))))
                running (fn [] (str/trim (:out (docker "inspect" "--format" "{{.Image}}" (str/trim (:out (compose "ps" "-q" "collector")))))))
                state #(json/parse-string (slurp (str stack "/deploy-state/" %)) true)
                history #(slurp (str stack "/deploy-state/history.jsonl"))]
            ;; the incumbent publishes its own first snapshot; wait for it
            (loop [n 0] (when (and (< n 60) (not (zero? (:exit (docker "run" "--rm" "--network" "none" "-v" (str volume ":/cache:ro") "--entrypoint" "/bin/git" base-image "--git-dir=/cache/remote.git" "rev-parse" "gh-pages")))))
                          (Thread/sleep 2000) (recur (inc n))))
            (expect (= old-id (running)) "incumbent runs the selected image id")
            (println "-- crash candidate: the new image exits at once")
            (let [r (run (:crash sha) "update")]
              (println (str/replace (:all r) #"(?m)^" "     "))
              (expect (= 1 (:exit r)) "crashing candidate: exit 1")
              (expect (= old-id (running)) "crashing candidate: previous image running again")
              (expect (str/includes? (slurp (str stack "/deployed-image.yaml")) old-pin) "crashing candidate: previous pin restored")
              (expect (str/includes? (history) "rollback-ok") "crashing candidate: real rollback recorded"))
            (println "-- failing-cycle candidate: starts, every cycle fails")
            (let [r (run (:fail sha) "update")]
              (println (str/replace (:all r) #"(?m)^" "     "))
              (expect (= 1 (:exit r)) "failing-cycle candidate: exit 1")
              (expect (= old-id (running)) "failing-cycle candidate: previous image running again")
              (expect (= (:fail sha) (get-in (state "state.json") [:last_failure :revision])) "failing-cycle candidate: failure recorded"))
            (println "-- good candidate")
            (let [r (run (:good sha) "update")
                  digest (re-find #"sha256:[0-9a-f]{64}" (must (docker "image" "inspect" "--format" "{{json .RepoDigests}}" (str repo ":" (:good sha))) "good digest"))
                  good-id (must (docker "image" "inspect" "--format" "{{.Id}}" (str repo "@" digest)) "good id")]
              (println (str/replace (:all r) #"(?m)^" "     "))
              (expect (zero? (:exit r)) "good candidate: exit 0")
              (expect (= good-id (running)) "good candidate: the running image is the pulled digest")
              (expect (= digest (:digest (state "state.json"))) "good candidate: state binds the real registry digest")
              (expect (str/includes? (slurp (str stack "/deployed-image.yaml")) (str repo ":" (:good sha) "@" digest)) "good candidate: override pins tag@digest")
              (expect (= "ok" (get-in (state "state.json") [:pages :status])) "good candidate: the published pages match the image's renderer")
              (expect (str/includes? (history) "collector-healthy") "good candidate: healthy recorded")
              (println "-- repeat is a no-op, rollback is honest")
              (let [before (str/trim (:out (compose "ps" "-q" "collector")))
                    again (run (:good sha) "update")]
                (expect (zero? (:exit again)) "repeat: exit 0")
                (expect (= before (str/trim (:out (compose "ps" "-q" "collector")))) "repeat: the container was not recreated"))
              (let [back (run (:good sha) "rollback")
                    s (state "state.json")]
                (println (str/replace (:all back) #"(?m)^" "     "))
                (expect (zero? (:exit back)) "manual rollback: exit 0")
                (expect (= old-id (running)) "manual rollback: previous image running")
                (expect (= old-digest (:digest s)) "manual rollback: state carries the restored digest")
                (expect (= (:good sha) (get-in s [:suppressed :revision])) "manual rollback: reverted revision suppressed")
                (expect (= 2 (:exit (run (:good sha) "update"))) "next timer refuses the reverted revision"))))
          (finally
            (println "== cleanup of this run's resources")
            (docker "compose" "--project-directory" stack "-p" project "-f" (str stack "/compose.yaml") "-f" (str stack "/deployed-image.yaml") "down" "-v" "--remove-orphans")))))))

(defn cleanup! []
  (doseq [c (:containers @owned)] (docker "rm" "-f" "-v" c))
  (doseq [i (reverse (:images @owned))] (docker "rmi" i))
  (doseq [dir (:dirs @owned)] (fs/delete-tree dir)))

(try
  (println "smoke run" run-id)
  (must (docker "load" "-i" (env "SMOKE_IMAGE_ARCHIVE")) "load the Nix-built collector image")
  (let [loaded (own! :images (str run-id "-loaded:image"))]
    (must (docker "tag" "moog-collector:nix" loaded) "tag loaded image")
    (github-reality! loaded)
    (docker-smoke! loaded))
  (catch Throwable e (swap! failures conj (str "aborted: " (ex-message e))) (println "ABORT:" (ex-message e)))
  (finally (cleanup!)))
(if (seq @failures)
  (do (println (count @failures) "live smoke failures:" (pr-str @failures)) (System/exit 1))
  (println "deploy live smoke ok"))
