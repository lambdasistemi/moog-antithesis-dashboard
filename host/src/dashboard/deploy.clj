(ns dashboard.deploy
  "Host-side collector rollout: update | status | rollback.
  Every outside effect goes through gh, docker, curl or the snapshot
  validator on PATH or named in the environment."
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
(defn instant
  "A parsed timestamp, or nil when the text is not one."
  [text] (try (Instant/parse text) (catch Exception _ nil)))

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
     :validator (env "DEPLOY_VALIDATOR" "validate-snapshot")
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
       (catch Exception e {:exit 127 :out "" :err (str "command unavailable: " (ex-message e))})))
(defn ok? [r] (zero? (:exit r)))

(defn discovery-failed!
  "Docker state that cannot be read is never evidence of absence."
  [what r]
  (throw (ex-info (str what " failed (exit " (:exit r) "): " (first (str/split-lines (str (:err r) "\n")))) {:discovery true})))

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
(defn read-pin [config] (parse-pin (when (fs/exists? (override-file config)) (slurp (override-file config)))))
(defn revision-of [ref] (some->> ref (re-find #":([0-9a-f]{40})") second))

(defn image-id
  "The immutable local image id a reference resolves to now, or nil."
  [ref]
  (let [r (sh ["docker" "image" "inspect" "--format" "{{.Id}}" ref])]
    (when (ok? r) (not-empty (str/trim (:out r))))))

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

;; ---- container discovery ------------------------------------------------

(defn container
  "The one collector container of the project, or nil when there is none.
  A failed or ambiguous lookup throws: it is not evidence of absence."
  [config]
  (let [listed (compose config "ps" "-q" (:service config))
        _ (when-not (ok? listed) (discovery-failed! "compose ps" listed))
        ids (remove str/blank? (str/split-lines (:out listed)))]
    (case (count ids)
      0 nil
      1 (let [id (first ids)
              r (sh ["docker" "inspect" "--format" "{{.Image}} {{.State.Status}} {{.RestartCount}}" id])]
          (when-not (ok? r) (discovery-failed! "docker inspect" r))
          (let [[image status restarts] (str/split (str/trim (:out r)) #" ")]
            {:id id :image image :status status :restarts (Long/parseLong restarts)}))
      (throw (ex-info (str "several " (:service config) " containers in the project: " (str/join "," ids)) {:discovery true})))))

(defn publisher-image?
  "Whether a container runs an image of the collector repository, whatever
  tag it was started from: by its configured reference or by what its
  image id is known as."
  [config configured image-id]
  (or (str/starts-with? (or configured "") (:image-repo config))
      (let [r (sh ["docker" "image" "inspect" "--format" "{{json .RepoTags}} {{json .RepoDigests}}" image-id])]
        (when-not (ok? r) (discovery-failed! "docker image inspect" r))
        (str/includes? (:out r) (str "\"" (:image-repo config))))))

(defn competing-publishers
  "Names of running publishers that must not coexist with a rollout. The
  project's own collector may appear once; anything else, or a second copy,
  is competing. A failed lookup throws."
  [config]
  (let [listed (sh ["docker" "ps" "-q"])
        _ (when-not (ok? listed) (discovery-failed! "docker ps" listed))
        rows (for [id (remove str/blank? (str/split-lines (:out listed)))]
               (let [r (sh ["docker" "inspect" "--format"
                            "{{.Name}}\t{{.Image}}\t{{.Config.Image}}\t{{index .Config.Labels \"com.docker.compose.project\"}}\t{{index .Config.Labels \"com.docker.compose.service\"}}" id])]
                 (when-not (ok? r) (discovery-failed! "docker inspect" r))
                 (str/split (str/trim-newline (:out r)) #"\t" -1)))
        publishers (filter (fn [[_ image configured]] (publisher-image? config configured image)) rows)
        own? (fn [[_ _ _ project service]] (and (= project (:project config)) (= service (:service config))))
        own (filter own? publishers)]
    (vec (concat (map first (remove own? publishers))
                 (when (> (count own) 1) (map first own))))))

;; ---- waiting ------------------------------------------------------------

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

;; ---- snapshot validity: the schema shipped in the selected image ---------

(def schemas (atom {}))
(defn image-run [& args]
  (sh (into ["docker" "run" "--rm" "--pull" "never" "--network" "none" "--read-only" "--entrypoint"] args)))

(defn image-schema
  "The snapshot contract of the selected image, read from the image."
  [image]
  (or (get @schemas image)
      (let [r (image-run "/bin/cat" image "/app/site/openapi.json")]
        (when (ok? r) (get (swap! schemas assoc image (:out r)) image)))))

(defn snapshot-problem
  "Nil when the text is a snapshot valid under the image's own schema with
  a parseable generation time; otherwise a reason."
  [config image text]
  (let [schema (image-schema image)]
    (cond
      (nil? schema) "snapshot schema unreadable in the selected image"
      :else
      (let [data (str (fs/create-temp-file {:prefix "snapshot-" :suffix ".json"}))
            spec (str (fs/create-temp-file {:prefix "schema-" :suffix ".json"}))]
        (try (spit data text) (spit spec schema)
             (let [r (sh [(:validator config) spec data])
                   generated (try (:generated_at (json/parse-string text true)) (catch Exception _ nil))]
               (cond (not (ok? r)) (str "snapshot violates the schema: " (first (str/split-lines (str (:err r) "\n"))))
                     (not (instant generated)) "snapshot generated_at is not a timestamp"))
             (finally (fs/delete-if-exists data) (fs/delete-if-exists spec)))))))

(defn snapshot-time [text] (try (some-> (:generated_at (json/parse-string text true)) instant) (catch Exception _ nil)))

(defn container-log [c]
  (let [r (sh ["docker" "logs" (:id c)])]
    (when-not (ok? r) (discovery-failed! "docker logs" r))
    (str (:out r) (:err r))))

(defn observe-snapshot
  "A fresh snapshot, valid under the image's schema, that the selected
  running collector itself published: its log names the snapshot's time."
  [config image-id started]
  (let [result (until (:snapshot config)
                      (fn []
                        (let [c (container config)]
                          (if (or (nil? c) (not= image-id (:image c)) (not= "running" (:status c)) (pos? (:restarts c)))
                            {:fatal true :detail "collector stopped or changed during first cycle"}
                            (let [log (container-log c)]
                              (if (str/includes? log "cycle failed")
                                {:fatal true :detail "collection cycle failed"}
                                (let [text (try (gh config (str "repos/" (:repo config) "/contents/data.json?ref=gh-pages")
                                                    "-H" "Accept: application/vnd.github.raw")
                                                (catch Exception _ nil))
                                      generated (some-> text snapshot-time)]
                                  (cond
                                    (nil? text) {:detail "no snapshot on gh-pages"}
                                    (nil? generated) {:fatal true :detail "published snapshot has no valid generation time"}
                                    (.isBefore generated started) {:detail "no new snapshot yet"}
                                    (not (str/includes? log (str "published " (:generated_at (json/parse-string text true)))))
                                    {:detail "snapshot not published by the selected collector yet"}
                                    :else (if-let [problem (snapshot-problem config image-id text)]
                                            {:fatal true :detail problem}
                                            {:done true :generated_at (str generated)}))))))))
                      config)]
    (if (:done result) {:ok true :generated_at (:generated_at result)} {:ok false :detail (:detail result)})))

;; ---- GitHub Pages: reported separately from collector health -----------

(defn sha256 [bytes] (apply str (map #(format "%02x" %) (.digest (MessageDigest/getInstance "SHA-256") bytes))))
(defn renderer-hashes
  "Hash of every page file in the selected image, read in a throwaway
  container. Fails closed: any file that cannot be inspected, or an image
  without index.html, yields an error instead of a partial map."
  [image]
  (let [listing (image-run "/bin/ls" image "/app/site")
        names (when (ok? listing) (remove str/blank? (str/split-lines (:out listing))))]
    (cond
      (not (ok? listing)) {:error "renderer files unreadable in the selected image"}
      (not (some #{"index.html"} names)) {:error "selected image has no index.html"}
      :else
      (let [r (apply image-run "/bin/sha256sum" image (map #(str "/app/site/" %) names))
            pairs (map #(str/split % #"\s+" 2) (remove str/blank? (str/split-lines (:out r))))]
        (if (and (ok? r) (= (count names) (count pairs)))
          {:hashes (into {} (for [[hash path] pairs] [(last (str/split path #"/")) hash]))}
          {:error "renderer file hashes incomplete in the selected image"})))))

(defn fetch-public [config name]
  (let [file (str (fs/create-temp-file))
        r (sh ["curl" "-fsS" "--max-time" "30" "-o" file (str (:pages-url config) name)])]
    (try (when (ok? r) (fs/read-all-bytes file)) (finally (fs/delete-if-exists file)))))

(defn pages-match? [config image hashes generated-at]
  (and (seq hashes) (instant generated-at)
       (every? (fn [[name hash]] (some-> (fetch-public config name) sha256 (= hash))) hashes)
       (let [text (some-> (fetch-public config "data.json") String.)
             published (some-> text snapshot-time)]
         (and published (not (.isBefore published (instant generated-at))) (nil? (snapshot-problem config image text))))))

(defn observe-pages [config image generated-at since]
  (let [hashes (renderer-hashes image)]
    (if (:error hashes)
      {:status "pending" :detail (:error hashes)}
      (let [result (until (:pages config)
                          (fn []
                            (cond
                              (pages-match? config image (:hashes hashes) generated-at) {:done true}
                              :else (let [build (try (gh-json config (str "repos/" (:repo config) "/pages/builds/latest")) (catch Exception _ nil))]
                                      (if (and (= "errored" (:status build)) (some-> (:updated_at build) instant (as-> t (not (.isBefore t since)))))
                                        {:fatal true :failed true :detail "GitHub Pages build errored"}
                                        {:detail "public page does not match yet"}))))
                          config)]
        (cond (:done result) {:status "ok"}
              (:failed result) {:status "failed" :detail (:detail result)}
              :else {:status "pending" :detail (:detail result)})))))

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

(defn update-state! [config f]
  (write-state! config "state.json" (f (or (read-state config "state.json") {}))))

(defn rollback-override
  "The override that restores the previous image. A mutable tag may have
  moved since it was pinned, so when its reference no longer resolves to
  the recorded image id the id itself is pinned."
  [previous text]
  (let [recorded (:image_id previous)]
    (cond
      (nil? recorded) text
      (= recorded (image-id (:ref previous))) text
      (image-id recorded) (replace-image text recorded)
      :else (throw (ex-info "previous image is no longer present" {})))))

(defn rollback!
  "Restore the previous pinned override and require the restored collector
  to run and publish a fresh snapshot. Returns {:ok bool :detail text}; it
  never throws and keeps its recovery state unless it succeeded."
  [config reason]
  (try
    (let [previous (read-state config "previous.json")
          saved (state-path config "previous-override.yaml")
          text (when (fs/exists? saved) (slurp saved))]
      (if-not (and previous text)
        (do (record! config "rollback-unavailable" {:reason reason}) {:ok false :detail "no previous pinned image"})
        (let [started (Instant/now)
              override (rollback-override previous text)
              pin (parse-pin override)
              id (or (:image_id previous) (image-id (:ref pin)))]
          (record! config "rollback-start" {:reason reason :to (:ref pin)})
          (apply-override! config override)
          (let [startup (observe-startup config id)
                cycle (when (:ok startup) (observe-snapshot config id (.truncatedTo started java.time.temporal.ChronoUnit/SECONDS)))
                problem (or (when-not (:ok startup) (str "startup: " (:detail startup)))
                            (when-not (:ok cycle) (str "cycle: " (:detail cycle))))]
            (if problem
              (do (record! config "rollback-failed" {:reason problem :to (:ref pin)})
                  (update-state! config #(-> % (dissoc :pages) (assoc :ref (:ref pin) :collector {:status "unhealthy" :detail problem})))
                  {:ok false :detail problem})
              (do (record! config "rollback-ok" {:to (:ref pin)})
                  (update-state! config #(-> % (dissoc :digest :run :deployed_at :pages :collector)
                                             (assoc :revision (:revision previous) :ref (:ref pin) :digest (:digest pin) :image_id id
                                                    :rolled_back_at (now)
                                                    :collector {:status "healthy" :snapshot (:generated_at cycle)})))
                  (fs/delete-if-exists (state-path config "previous.json"))
                  (fs/delete-if-exists (state-path config "rollout.json"))
                  {:ok true}))))))
    (catch Throwable e
      (let [detail (str "rollback exception: " (ex-message e))]
        (try (record! config "rollback-failed" {:reason detail}) (catch Throwable _ nil))
        {:ok false :detail detail}))))

(defn suppress! [config revision reason]
  (update-state! config #(assoc % :suppressed {:revision revision :reason reason :at (now)})))

(defn fail-rollout!
  "A rollout failed after it may have mutated the stack: roll back, record
  the failure and suppress the revision. Returns :failed."
  [config revision problem]
  (let [back (rollback! config problem)]
    (record! config "rollout-failed" {:revision revision :reason problem :rolled-back (:ok back)})
    (update-state! config #(assoc % :last_failure {:at (now) :revision revision :reason problem :rolled_back (:ok back)}
                                  :suppressed {:revision revision :reason problem :at (now)}))
    :failed))

(defn rollout-phase
  "Everything after the first mutation. Returns the problem text, or nil
  with the observed snapshot time. Any exception is a problem."
  [config selection image started]
  (try (let [old-text (when (fs/exists? (override-file config)) (slurp (override-file config)))
             _ (apply-override! config (replace-image (or old-text (str "services:\n  " (:service config) ":\n    image: x\n")) (:ref image)))
             startup (observe-startup config (:id image))
             cycle (when (:ok startup) (observe-snapshot config (:id image) started))]
         (cond (not (:ok startup)) {:problem (str "startup: " (:detail startup))}
               (not (:ok cycle)) {:problem (str "cycle: " (:detail cycle))}
               :else {:generated-at (:generated_at cycle)}))
       (catch Throwable e {:problem (str "exception during rollout: " (ex-message e))})))

(declare observe-and-record-pages!)
(defn deploy! [config selection image]
  (let [started (.truncatedTo (Instant/now) java.time.temporal.ChronoUnit/SECONDS)
        old-text (when (fs/exists? (override-file config)) (slurp (override-file config)))
        old-pin (parse-pin old-text)
        previous-id (when old-pin (or (:image (container config)) (image-id (:ref old-pin))))]
    (when (and old-pin (nil? previous-id))
      (throw (ex-info "previous image identity cannot be established; refusing to replace it" {:discovery true})))
    (when old-text
      (atomic-write! (state-path config "previous-override.yaml") old-text)
      (write-state! config "previous.json" {:ref (:ref old-pin) :image_id previous-id :revision (revision-of (:ref old-pin)) :recorded_at (now)}))
    (write-state! config "rollout.json" {:revision (:revision selection) :ref (:ref image) :started_at (str started)})
    (record! config "rollout-start" {:revision (:revision selection) :ref (:ref image) :run (:run selection)})
    (let [{:keys [problem generated-at]} (rollout-phase config selection image started)]
      (if problem
        (fail-rollout! config (:revision selection) problem)
        (do (bind! config (:revision selection) (:digest image))
            (record! config "collector-healthy" {:revision (:revision selection) :snapshot generated-at})
            (update-state! config #(-> % (dissoc :suppressed :pages)
                                       (assoc :revision (:revision selection) :digest (:digest image) :ref (:ref image) :image_id (:id image)
                                              :run (:run selection) :deployed_at (now)
                                              :collector {:status "healthy" :snapshot generated-at})))
            (fs/delete-if-exists (state-path config "rollout.json"))
            (observe-and-record-pages! config image generated-at started))))))

(defn observe-and-record-pages! [config image generated-at since]
  (let [pages (observe-pages config (:id image) generated-at since)]
    (update-state! config #(assoc % :pages (assoc pages :checked_at (now) :snapshot generated-at)))
    (record! config (str "pages-" (:status pages)) {:detail (:detail pages)})
    (case (:status pages) "ok" :ok "pending" :pages-pending "failed" :pages-failed)))

(defn running-this? [config image]
  (let [c (container config) pin (read-pin config)]
    (and c (= "running" (:status c)) (= (:id image) (:image c)) (= (:digest image) (:digest pin)))))

(defn reconcile!
  "An earlier invocation died between mutation and its verdict. Restore the
  previous pin before anything else, keeping the original previous state."
  [config]
  (if-let [interrupted (read-state config "rollout.json")]
    (do (record! config "rollout-interrupted" {:revision (:revision interrupted) :reason "unfinished rollout found; restoring the previous pin"})
        (let [back (rollback! config "interrupted rollout")]
          (if (:ok back)
            (do (suppress! config (:revision interrupted) "interrupted rollout was rolled back") :reconciled)
            :failed)))
    :clear))

(defn update! [config requested retry]
  (if (= :failed (reconcile! config))
    :failed
    (try
      (let [selection (select-revision config requested)
            suppressed (:suppressed (read-state config "state.json"))]
        (cond
          (:refused selection)
          (do (record! config "refused" {:reason (:reason selection)}) (if (= :ci-pending (:refused selection)) :ci-pending :refused))
          (and (not retry) (= (:revision selection) (:revision suppressed)))
          (do (record! config "refused" {:reason (str (:revision selection) " was rolled back (" (:reason suppressed) "); update --retry to try again")}) :refused)
          :else
          (let [image (resolve-image config (:revision selection))]
            (cond
              (:refused image) (do (record! config "refused" {:reason (:reason image)}) :refused)
              (not= (:revision selection) (head-sha config))
              (do (record! config "refused" {:reason "superseded: main moved during selection"}) :refused)
              :else
              (let [competing (competing-publishers config)]
                (cond
                  (seq competing)
                  (do (record! config "refused" {:reason (str "competing publisher running: " (str/join "," competing))}) :refused)
                  (running-this? config image)
                  (let [state (read-state config "state.json")]
                    (if (= "ok" (get-in state [:pages :status]))
                      (do (record! config "noop" {:detail (str (:revision selection) " already deployed")}) :ok)
                      (observe-and-record-pages! config image (get-in state [:collector :snapshot])
                                                 (or (some-> (:deployed_at state) instant) (Instant/now)))))
                  :else (deploy! config selection image)))))))
      (catch clojure.lang.ExceptionInfo e
        (if (:discovery (ex-data e))
          (do (record! config "refused" {:reason (str "cannot establish the state of the host: " (ex-message e))}) :refused)
          (throw e))))))

(defn status [config]
  (let [state (read-state config "state.json")
        c (try (container config) (catch Exception e {:error (ex-message e)}))
        pin (read-pin config)]
    (say "pinned:" (or (:ref pin) "none"))
    (say "running:" (cond (:error c) (str "unknown (" (:error c) ")") c (str (:status c) " image " (:image c) " restarts " (:restarts c)) :else "no collector container"))
    (say "revision:" (or (:revision state) "unknown") "deployed_at:" (or (:deployed_at state) "unknown"))
    (say "collector:" (or (get-in state [:collector :status]) "unknown") "snapshot:" (or (get-in state [:collector :snapshot]) "none"))
    (say "pages:" (or (get-in state [:pages :status]) "unknown") (or (get-in state [:pages :detail]) ""))
    (say "previous:" (or (:ref (read-state config "previous.json")) "none"))
    (say "rollout in progress:" (if-let [r (read-state config "rollout.json")] (str (:revision r) " since " (:started_at r)) "no"))
    (if-let [s (:suppressed state)] (say "not redeployed:" (:revision s) (:reason s)) (say "not redeployed: none"))
    (if-let [f (:last_failure state)] (say "last failure:" (:at f) (:revision f) (:reason f) "rolled back:" (:rolled_back f)) (say "last failure: none"))
    :ok))

(defn manual-rollback! [config]
  (let [reverted (:revision (read-state config "state.json"))
        back (rollback! config "operator rollback")]
    (when (:ok back) (suppress! config reverted "operator rollback"))
    (if (:ok back) :ok :failed)))

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
