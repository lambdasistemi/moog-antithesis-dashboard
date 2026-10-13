(ns dashboard.publication
  (:require [dashboard.io :as io]
            [dashboard.compose :as compose]
            [babashka.fs :as fs]
            [clojure.string :as str]))

(defn secret-values [config]
  (let [dir (io/env "DASHBOARD_SECRETS_DIR" "/run/secrets")
        files (concat (when (fs/directory? dir) (filter fs/regular-file? (fs/list-dir dir)))
                      [(:anti-key config)])
        values (mapcat #(when (io/file? %) (remove str/blank? (str/split-lines (slurp (str %))))) files)
        moog-values (when (io/file? (:moog-env config))
                      (filter #(>= (count %) 8) (vals (io/parse-env (slurp (:moog-env config))))))]
    (set (concat values moog-values))))
(defn refuse! [message paths]
  (binding [*out* *err*] (println message) (doseq [path paths] (println path)))
  (throw (ex-info "Publication refused" {:exit 2 :public true})))
(defn gate! [stage config]
  (let [files (filter fs/regular-file? (fs/glob stage "**" {:hidden true}))
        text (into {} (map (fn [path] [(str (fs/relativize stage path)) (slurp (str path))]) files))
        values (secret-values config)
        generic (keep (fn [[path value]] (when (re-find compose/secret-pattern value) path)) text)
        literals (keep (fn [[path value]] (when (some #(str/includes? value %) values) path)) text)
        urls (keep (fn [[path value]] (when (and (str/starts-with? path "status/") (re-find #"https?://" value)) path)) text)]
    (when (seq generic) (refuse! "secrets gate: refusing to publish" generic))
    (when (seq literals) (refuse! "secrets gate: mounted secret found, refusing to publish" literals))
    (when (seq urls) (refuse! "secrets gate: URL in status payload, refusing to publish" urls))
    (when (some #(and (string? %) (re-find #"https?://" %))
                (tree-seq coll? seq (:monitor (io/read-json (str stage "/data.json")))))
      (refuse! "secrets gate: URL in monitor payload, refusing to publish" ["data.json"]))))
(defn stage! [config stage]
  (doseq [file (filter fs/regular-file? (fs/list-dir (str (:root config) "/site")))]
    (fs/copy file (fs/path stage (fs/file-name file))))
  (doseq [file (concat [(fs/path (:out config) "data.json") (fs/path (:out config) "property-descriptions.json")]
                      (fs/glob (:out config) "runs/*.json") (fs/glob (:out config) "status/*.json")
                      (fs/glob (:out config) "runs/*/docker-compose.yaml")) :when (io/file? file)]
    (let [relative (fs/relativize (:out config) file) destination (fs/path stage relative)]
      (fs/create-dirs (fs/parent destination)) (fs/copy file destination)))
  (spit (str (fs/path stage ".nojekyll")) ""))
(defn credentials! []
  (print (format "username=x-access-token\npassword=%s\n" (io/read-key (io/env "PAGES_PUSH_TOKEN_FILE" "/run/secrets/pages-push")))))
(defn publish! [config]
  (when-not (io/file? (str (:out config) "/data.json")) (io/fail! "No data.json to publish"))
  (let [dry (= "1" (io/env "DASHBOARD_DRY_RUN" "0"))
        token-file (io/env "PAGES_PUSH_TOKEN_FILE" "/run/secrets/pages-push")
        _ (when (and (not dry) (not (io/file? token-file))) (io/fail! "Push token file unavailable"))
        stage (fs/create-temp-dir)]
    (try (stage! config stage) (gate! stage config)
         (let [git #(io/run (into ["git"] %) {:dir (str stage)})
               generated (:generated_at (io/read-json (str stage "/data.json")))]
           (git ["init" "-q" "-b" "gh-pages"])
           (git ["add" "-A"])
           (git ["-c" "user.name=moog-antithesis-dashboard" "-c" "user.email=noreply@lambdasistemi.net" "commit" "-q" "-m" (str "data " generated)])
           (if dry
             (let [files (git ["ls-files"])]
               (println (str "dry run: would publish " (count (str/split-lines files)) " files, generated_at " generated))
               (print files))
             (do (io/run ["git" "-c" "credential.helper=" "-c" "credential.helper=!bb --main dashboard.main credentials"
                          "push" "-q" "-f" (io/env "DASHBOARD_REMOTE" "https://github.com/lambdasistemi/moog-antithesis-dashboard.git") "gh-pages"]
                         {:dir (str stage) :extra-env {"PAGES_PUSH_TOKEN_FILE" token-file "GIT_TERMINAL_PROMPT" "0"
                                                      "BABASHKA_CLASSPATH" (str (:root config) "/backend/src")}})
                 (println "published" generated))))
         (finally (fs/delete-tree stage)))))
