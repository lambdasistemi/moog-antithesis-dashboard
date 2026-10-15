(ns dashboard.deploy
  "Host-side collector rollout: update | status | rollback.
  Every outside effect goes through gh, docker or curl on PATH."
  (:require [babashka.fs :as fs]
            [babashka.process :as process]
            [cheshire.core :as json]
            [clojure.string :as str])
  (:import [java.nio.channels FileChannel]
           [java.nio.file StandardOpenOption]
           [java.security MessageDigest]
           [java.time Instant]))

(def exit-codes {:ok 0 :failed 1 :refused 2 :ci-pending 3 :pages-pending 4 :pages-failed 5})

(defn env [key fallback] (or (System/getenv key) fallback))
(defn now [] (str (.truncatedTo (Instant/now) java.time.temporal.ChronoUnit/SECONDS)))
(defn seconds [key fallback] (Long/parseLong (env key (str fallback))))

(defn config []
  (let [stack (env "DEPLOY_STACK_DIR" "/srv/prod-hot/services/moog-antithesis-dashboard")
        repo (env "DEPLOY_REPOSITORY" "lambdasistemi/moog-antithesis-dashboard")]
    {:stack stack :project (env "DEPLOY_PROJECT" (str (fs/file-name stack)))
     :service (env "DEPLOY_SERVICE" "collector")
     :repo repo :image-repo (env "DEPLOY_IMAGE_REPOSITORY" (str "ghcr.io/" repo))
     :branch (env "DEPLOY_BRANCH" "main") :workflow (env "DEPLOY_WORKFLOW" "ci.yml")
     :required-jobs (str/split (env "DEPLOY_REQUIRED_JOBS" "CI collector image,CI reproduce evidence") #",")
     :token-file (env "DEPLOY_GH_TOKEN_FILE" "/srv/moog-antithesis-dashboard/gh-read")
     :pages-url (env "DEPLOY_PAGES_URL" "https://lambdasistemi.github.io/moog-antithesis-dashboard/")
     :state (env "DEPLOY_STATE_DIR" (str stack "/deploy-state"))
     :startup (seconds "DEPLOY_STARTUP_SECONDS" 120) :stable (seconds "DEPLOY_STABLE_SECONDS" 20)
     :snapshot (seconds "DEPLOY_SNAPSHOT_SECONDS" 1200) :pages (seconds "DEPLOY_PAGES_SECONDS" 900)
     :poll (seconds "DEPLOY_POLL_SECONDS" 10)}))

;; Output never carries the token: say scrubs it, argv never holds it.
(def token (atom nil))
(defn say [& parts]
  (let [text (str/join " " parts)]
    (println (if @token (str/replace text @token "***") text))))

(defn sh [args & [{:keys [env]}]]
  (try (let [r @(process/process args (cond-> {:in "" :out :string :err :string}
                                       env (assoc :extra-env env)))]
         (select-keys r [:exit :out :err]))
       (catch Exception _ {:exit 127 :out "" :err "command unavailable"})))
(defn ok? [r] (zero? (:exit r)))

(defn gh [config path & extra]
  (let [t (or @token (reset! token (str/trim (slurp (:token-file config)))))
        r (sh (into ["gh" "api" path] extra) {:env {"GH_TOKEN" t "GH_PROMPT_DISABLED" "1"}})]
    (when-not (ok? r) (throw (ex-info (str "GitHub API failed: " path) {})))
    (:out r)))
(defn gh-json [config path] (json/parse-string (gh config path) true))

(defn compose [config & args]
  (let [dir (:stack config)]
    (sh (into ["docker" "compose" "--project-directory" dir "-p" (:project config)
               "-f" (str dir "/compose.yaml") "-f" (str dir "/deployed-image.yaml")] args))))
(defn override-file [config] (str (:stack config) "/deployed-image.yaml"))

(defn state-path [config name] (str (:state config) "/" name))
(defn read-state [config name]
  (let [p (state-path config name)] (when (fs/exists? p) (json/parse-string (slurp p) true))))
(defn atomic-write! [path text]
  (fs/create-dirs (fs/parent path))
  (let [tmp (fs/create-temp-file {:dir (fs/parent path) :prefix ".write-"})]
    (try (spit (str tmp) text) (fs/move tmp path {:replace-existing true :atomic-move true})
         (finally (fs/delete-if-exists tmp)))))
(defn write-state! [config name value]
  (atomic-write! (state-path config name) (str (json/generate-string value {:pretty true}) "\n")))
(defn record! [config event detail]
  (let [entry (merge {:at (now) :event event} detail)]
    (fs/create-dirs (:state config))
    (spit (state-path config "history.jsonl") (str (json/generate-string entry) "\n") :append true)
    (say event (or (:reason detail) (:detail detail) ""))))

;; ---- revision selection -------------------------------------------------

(defn refusal [kind reason] {:refused kind :reason reason})

(defn head-sha [config]
  (get-in (gh-json config (str "repos/" (:repo config) "/branches/" (:branch config))) [:commit :sha]))

(defn select-revision
  "A merged main head whose complete push CI run succeeded, or a refusal."
  [config requested]
  (let [head (head-sha config)]
    (cond
      (and requested (not= requested head))
      (refusal :refused (str "superseded or not on " (:branch config) ": " requested " is not the head " head))
      :else
      (let [runs (:workflow_runs (gh-json config (str "repos/" (:repo config) "/actions/workflows/" (:workflow config)
                                                      "/runs?branch=" (:branch config) "&event=push&head_sha=" head "&per_page=50")))
            runs (filter #(and (= head (:head_sha %)) (= (:branch config) (:head_branch %)) (= "push" (:event %))) runs)
            run (last (sort-by (juxt :id :run_attempt) runs))]
        (cond
          (nil? run) (refusal :ci-pending (str "no push CI run for " head))
          (not= "completed" (:status run)) (refusal :ci-pending (str "CI run " (:id run) " is " (:status run)))
          (not= "success" (:conclusion run)) (refusal :refused (str "CI run " (:id run) " concluded " (:conclusion run)))
          :else
          (let [jobs (:jobs (gh-json config (str "repos/" (:repo config) "/actions/runs/" (:id run) "/jobs?per_page=100&filter=latest")))
                by-name (into {} (map (juxt :name :conclusion) jobs))
                bad (remove #(#{"success" "skipped"} (:conclusion %)) jobs)
                missing (remove #(= "success" (by-name %)) (:required-jobs config))]
            (cond
              (empty? jobs) (refusal :ci-pending "no jobs reported")
              (seq bad) (refusal :refused (str "jobs not successful: " (str/join ", " (map :name bad))))
              (seq missing) (refusal :refused (str "required jobs not successful: " (str/join ", " missing)))
              :else {:revision head :run (:id run) :attempt (:run_attempt run)})))))))

;; ---- images -------------------------------------------------------------

(defn pin-ref [config revision digest] (str (:image-repo config) ":" revision "@" digest))
(defn parse-pin [text]
  (when-let [[_ ref] (re-find #"(?m)^\s+image:\s*(\S+)\s*$" (or text ""))]
    {:ref ref :digest (second (re-find #"@(sha256:[0-9a-f]{64})" ref))}))

(defn resolve-image
  "Pull the revision tag only after CI passed; bind it to its digest."
  [config revision]
  (let [tag (str (:image-repo config) ":" revision)
        pulled (sh ["docker" "pull" "--quiet" tag])
        info (when (ok? pulled)
               (sh ["docker" "image" "inspect" "--format" "{{.Id}} {{json .RepoDigests}}" tag]))]
    (if-not (and info (ok? info))
      (refusal :refused (str "published image missing for " revision))
      (let [[id digests] (str/split (str/trim (:out info)) #" " 2)
            digest (some->> (json/parse-string digests) (filter #(str/starts-with? % (str (:image-repo config) "@"))) first
                            (re-find #"@(sha256:[0-9a-f]{64})") second)
            bound (get (read-state config "bindings.json") (keyword revision))]
        (cond
          (nil? digest) (refusal :refused "image has no registry digest")
          (and bound (not= bound digest)) (refusal :refused (str "tag moved: " revision " was bound to " bound))
          :else {:id id :digest digest :ref (pin-ref config revision digest)})))))

(defn bind! [config revision digest]
  (write-state! config "bindings.json" (assoc (or (read-state config "bindings.json") {}) (keyword revision) digest)))

;; ---- container observation ---------------------------------------------

(defn container [config]
  (let [id (str/trim (:out (compose config "ps" "-q" (:service config))))]
    (when-not (str/blank? id)
      (let [r (sh ["docker" "inspect" "--format" "{{.Image}} {{.State.Status}} {{.RestartCount}}" id])]
        (when (ok? r)
          (let [[image status restarts] (str/split (str/trim (:out r)) #" ")]
            {:id id :image image :status status :restarts (Long/parseLong restarts)}))))))

(defn competing-publishers [config]
  (let [r (sh ["docker" "ps" "--format" "{{.Names}}\t{{.Image}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.service\"}}"])]
    (when (ok? r)
      (->> (str/split-lines (:out r))
           (map #(str/split % #"\t" -1))
           (filter (fn [[_ image project service]]
                     (and (str/starts-with? (or image "") (:image-repo config))
                          (not (and (= project (:project config)) (= service (:service config)))))))
           (mapv first)))))

(declare observe-and-record-pages!)
(defn sleep [config] (Thread/sleep (* 1000 (:poll config))))
(defn until [seconds check config]
  (let [end (+ (System/currentTimeMillis) (* 1000 seconds))]
    (loop []
      (let [r (check)]
        (cond (or (:done r) (:fatal r)) r
              (> (System/currentTimeMillis) end) (assoc r :timeout true)
              :else (do (sleep config) (recur)))))))

(defn observe-startup
  "The pinned image runs, stays up and does not restart for the stable window."
  [config image-id]
  (let [stable-since (atom nil)
        result (until (:startup config)
                      (fn []
                        (let [c (container config)]
                          (cond
                            (nil? c) {:detail "no collector container"}
                            (not= image-id (:image c)) {:detail "running image does not match the selected revision"}
                            (or (not= "running" (:status c)) (pos? (:restarts c)))
                            (do (reset! stable-since nil) {:fatal true :detail (str "collector " (:status c) ", restarts " (:restarts c))})
                            :else (let [since (or @stable-since (reset! stable-since (System/currentTimeMillis)))]
                                    (if (>= (- (System/currentTimeMillis) since) (* 1000 (:stable config)))
                                      {:done true} {:detail "settling"})))))
                      config)]
    (if (:done result) {:ok true} {:ok false :detail (:detail result)})))

(defn snapshot-valid? [snapshot]
  (and (map? snapshot) (string? (:generated_at snapshot)) (map? (:sources snapshot))
       (sequential? (:runs snapshot)) (string? (:tenant snapshot))))

(defn observe-snapshot
  "A new valid snapshot, published to gh-pages after the rollout began."
  [config started-at since]
  (let [result (until (:snapshot config)
                      (fn []
                        (let [c (container config)
                              log (sh ["docker" "logs" "--since" started-at (or (:id c) "")])
                              failed (str/includes? (str (:out log) (:err log)) "cycle failed")]
                          (if (or (nil? c) (not= "running" (:status c)) (pos? (:restarts c)) failed)
                            {:fatal true :detail (if failed "collection cycle failed" "collector stopped during first cycle")}
                            (let [snap (try (json/parse-string (gh config (str "repos/" (:repo config) "/contents/data.json?ref=gh-pages")
                                                                  "-H" "Accept: application/vnd.github.raw") true)
                                            (catch Exception _ nil))]
                              (if (and (snapshot-valid? snap) (not (.isBefore (Instant/parse (:generated_at snap)) since)))
                                {:done true :generated_at (:generated_at snap)}
                                {:detail "no new valid snapshot yet"})))))
                      config)]
    (if (:done result) {:ok true :generated_at (:generated_at result)} {:ok false :detail (:detail result)})))

;; ---- GitHub Pages: reported separately from collector health -----------

(defn sha256 [bytes] (apply str (map #(format "%02x" %) (.digest (MessageDigest/getInstance "SHA-256") bytes))))
(defn renderer-hashes
  "Hash of every page file in the selected image, read in a throwaway container."
  [config image-ref]
  (let [run (fn [& args] (sh (into ["docker" "run" "--rm" "--network" "none" "--read-only" "--entrypoint"] args)))
        listing (run "/bin/ls" image-ref "/app/site")]
    (when (ok? listing)
      (into {} (for [name (str/split-lines (:out listing))
                     :let [r (run "/bin/sha256sum" image-ref (str "/app/site/" name))]
                     :when (ok? r)]
                 [name (first (str/split (:out r) #" "))])))))

(defn fetch-public [config name]
  (let [file (str (fs/create-temp-file))
        r (sh ["curl" "-fsS" "--max-time" "30" "-o" file (str (:pages-url config) name)])]
    (try (when (ok? r) (fs/read-all-bytes file)) (finally (fs/delete-if-exists file)))))

(defn pages-match? [config hashes generated-at]
  (and (seq hashes)
       (every? (fn [[name hash]] (some-> (fetch-public config name) sha256 (= hash))) hashes)
       (let [data (some-> (fetch-public config "data.json") String. (json/parse-string true))]
         (and (snapshot-valid? data) (not (.isBefore (Instant/parse (:generated_at data)) (Instant/parse generated-at)))))))

(defn observe-pages [config image-ref generated-at since]
  (let [hashes (renderer-hashes config image-ref)
        result (until (:pages config)
                      (fn []
                        (cond
                          (pages-match? config hashes generated-at) {:done true}
                          :else (let [build (try (gh-json config (str "repos/" (:repo config) "/pages/builds/latest")) (catch Exception _ nil))]
                                  (if (and (= "errored" (:status build)) (not (.isBefore (Instant/parse (:updated_at build)) since)))
                                    {:fatal true :failed true :detail "GitHub Pages build errored"}
                                    {:detail "public page does not match yet"}))))
                      config)]
    (cond (:done result) {:status "ok"}
          (:failed result) {:status "failed" :detail (:detail result)}
          :else {:status "pending" :detail (:detail result)})))

;; ---- rollout and rollback ----------------------------------------------

(defn replace-image [text ref]
  (if (re-find #"(?m)^(\s+image:\s*)\S+" text)
    (str/replace-first text #"(?m)^(\s+image:\s*)\S+" (str "$1" ref))
    (throw (ex-info "override has no image line" {}))))

(defn apply-override!
  "Write the override and recreate only the collector service."
  [config text]
  (atomic-write! (override-file config) text)
  (let [valid (compose config "config" "--quiet")]
    (when-not (ok? valid) (throw (ex-info "Compose configuration invalid" {})))
    (let [up (compose config "up" "-d" "--no-deps" "--no-build" "--pull" "never" (:service config))]
      (when-not (ok? up) (throw (ex-info "Compose up failed" {}))))))

(defn rollback!
  "Restore the previously pinned override. Returns the observed startup result."
  [config reason]
  (let [previous (read-state config "previous.json")
        saved (state-path config "previous-override.yaml")
        text (when (fs/exists? saved) (slurp saved))]
    (if-not (and previous text)
      (do (record! config "rollback-unavailable" {:reason reason}) {:ok false :detail "no previous pinned image"})
      (do (record! config "rollback-start" {:reason reason :to (:ref previous)})
          (apply-override! config text)
          (let [id (str/trim (:out (sh ["docker" "image" "inspect" "--format" "{{.Id}}" (:ref previous)])))
                started (observe-startup config id)]
            (record! config (if (:ok started) "rollback-ok" "rollback-failed") {:reason (:detail started) :to (:ref previous)})
            (when (:ok started)
              (write-state! config "state.json" (assoc (read-state config "state.json") :revision (:revision previous) :ref (:ref previous)
                                                       :rolled_back_at (now) :collector {:status "healthy"}))
              (fs/delete-if-exists (state-path config "previous.json")))
            started)))))

(defn deploy! [config selection image]
  (let [started (.truncatedTo (Instant/now) java.time.temporal.ChronoUnit/SECONDS) started-text (str started)
        old-text (when (fs/exists? (override-file config)) (slurp (override-file config)))
        old-pin (parse-pin old-text)]
    (when old-text
      (atomic-write! (state-path config "previous-override.yaml") old-text)
      (write-state! config "previous.json" {:ref (:ref old-pin) :revision (some->> (:ref old-pin) (re-find #":([0-9a-f]{40})") second)
                                            :recorded_at (now)}))
    (record! config "rollout-start" {:revision (:revision selection) :ref (:ref image) :run (:run selection)})
    (let [failure (try (apply-override! config (replace-image (or old-text (str "services:\n  " (:service config) ":\n    image: x\n")) (:ref image)))
                       nil
                       (catch Exception e (ex-message e)))
          startup (when-not failure (observe-startup config (:id image)))
          cycle (when (:ok startup) (observe-snapshot config started-text started))
          problem (or failure (when-not (:ok startup) (str "startup: " (:detail startup)))
                      (when-not (:ok cycle) (str "cycle: " (:detail cycle))))]
      (if problem
        (let [back (rollback! config problem)]
          (record! config "rollout-failed" {:revision (:revision selection) :reason problem :rolled-back (:ok back)})
          (write-state! config "state.json" (assoc (or (read-state config "state.json") {}) :last_failure
                                                   {:at (now) :revision (:revision selection) :reason problem :rolled_back (:ok back)}))
          :failed)
        (do (bind! config (:revision selection) (:digest image))
            (record! config "collector-healthy" {:revision (:revision selection) :snapshot (:generated_at cycle)})
            (write-state! config "state.json" (assoc (read-state config "state.json") :revision (:revision selection) :digest (:digest image)
                                                     :ref (:ref image) :run (:run selection) :deployed_at (now)
                                                     :collector {:status "healthy" :snapshot (:generated_at cycle)}))
            (observe-and-record-pages! config image (:generated_at cycle) started))))))

(defn observe-and-record-pages! [config image generated-at since]
  (let [pages (observe-pages config (:ref image) generated-at since)
        state (read-state config "state.json")]
    (write-state! config "state.json" (assoc state :pages (assoc pages :checked_at (now) :snapshot generated-at)))
    (record! config (str "pages-" (:status pages)) {:detail (:detail pages)})
    (case (:status pages) "ok" :ok "pending" :pages-pending "failed" :pages-failed)))

(defn running-this? [config image]
  (let [c (container config) pin (parse-pin (when (fs/exists? (override-file config)) (slurp (override-file config))))]
    (and c (= "running" (:status c)) (= (:id image) (:image c)) (= (:digest image) (:digest pin)))))

(defn update! [config requested retry]
  (let [selection (select-revision config requested)
        failed (:last_failure (read-state config "state.json"))]
    (cond
      (:refused selection)
      (do (record! config "refused" {:reason (:reason selection)}) (if (= :ci-pending (:refused selection)) :ci-pending :refused))
      (and (not retry) (= (:revision selection) (:revision failed)))
      (do (record! config "refused" {:reason (str (:revision selection) " already failed and was rolled back; update --retry to try again")}) :refused)
      :else
      (let [image (resolve-image config (:revision selection))]
        (cond
          (:refused image) (do (record! config "refused" {:reason (:reason image)}) :refused)
          (not= (:revision selection) (head-sha config))
          (do (record! config "refused" {:reason "superseded: main moved during selection"}) :refused)
          (seq (competing-publishers config))
          (do (record! config "refused" {:reason (str "competing publisher running: " (str/join "," (competing-publishers config)))}) :refused)
          (running-this? config image)
          (let [state (read-state config "state.json")]
            (if (= "ok" (get-in state [:pages :status]))
              (do (record! config "noop" {:detail (str (:revision selection) " already deployed")}) :ok)
              (observe-and-record-pages! config image (get-in state [:collector :snapshot]) (Instant/parse (or (:deployed_at state) (now))))))
          :else (deploy! config selection image))))))

(defn status [config]
  (let [state (read-state config "state.json") c (container config)
        pin (parse-pin (when (fs/exists? (override-file config)) (slurp (override-file config))))]
    (say "pinned:" (or (:ref pin) "none"))
    (say "running:" (if c (str (:status c) " image " (:image c) " restarts " (:restarts c)) "no collector container"))
    (say "revision:" (or (:revision state) "unknown") "deployed_at:" (or (:deployed_at state) "unknown"))
    (say "collector:" (or (get-in state [:collector :status]) "unknown") "snapshot:" (or (get-in state [:collector :snapshot]) "none"))
    (say "pages:" (or (get-in state [:pages :status]) "unknown") (or (get-in state [:pages :detail]) ""))
    (say "previous:" (or (:ref (read-state config "previous.json")) "none"))
    (if-let [f (:last_failure state)] (say "last failure:" (:at f) (:revision f) (:reason f) "rolled back:" (:rolled_back f)) (say "last failure: none"))
    :ok))

(defn manual-rollback! [config]
  (let [back (rollback! config "operator rollback")] (if (:ok back) :ok :failed)))

(defn with-lock [config f]
  (fs/create-dirs (:state config))
  (with-open [channel (FileChannel/open (fs/path (state-path config "lock"))
                                        (into-array StandardOpenOption [StandardOpenOption/CREATE StandardOpenOption/WRITE]))]
    (if (try (.tryLock channel) (catch Exception _ nil))
      (f)
      (do (say "another deployment is running; nothing to do") :ok))))

(defn -main [& args]
  (let [config (config)
        [action & more] args
        requested (second (drop-while #(not= "--revision" %) more))
        retry (some #{"--retry"} more)
        result (try (case action
                      "update" (with-lock config #(update! config requested retry))
                      "rollback" (with-lock config #(manual-rollback! config))
                      "status" (status config)
                      (do (say "usage: collector-deploy update [--revision SHA] [--retry] | status | rollback") :refused))
                    (catch Exception e (say "deployment error:" (ex-message e)) :failed))]
    (System/exit (get exit-codes result 1))))
