(ns dashboard.io
  (:require [babashka.fs :as fs]
            [babashka.process :as process]
            [cheshire.core :as json]
            [clojure.string :as str])
  (:import [java.time Instant]
           [java.time.temporal ChronoUnit]))

(def ^:dynamic *env* nil)
(def running (atom #{}))
(defn env [key fallback] (or (get (or *env* (System/getenv)) key) fallback))
(defn now [] (str (.truncatedTo (Instant/now) ChronoUnit/SECONDS)))
(defn epoch [time] (.getEpochSecond (Instant/parse time)))
(defn decode [text] (json/parse-string-strict text true))
(defn encode [value] (json/generate-string value))
(defn file? [path] (and (fs/regular-file? path) (pos? (fs/size path))))
(defn read-json [path] (when (file? path) (decode (slurp (str path)))))
(defn atomic-text! [path text]
  (fs/create-dirs (fs/parent path))
  (let [tmp (fs/create-temp-file {:dir (fs/parent path) :prefix ".write-"})]
    (try (spit (str tmp) text)
         (fs/move tmp path {:replace-existing true :atomic-move true})
         (finally (fs/delete-if-exists tmp)))))
(defn write-json! [path value] (atomic-text! path (str (encode value) "\n")))
(defn root [] (str (fs/parent (or (System/getProperty "babashka.config") (str (fs/path (fs/cwd) "bb.edn"))))))
(defn config []
  (let [cache (env "DASHBOARD_CACHE" (str (env "HOME" "/home/collector") "/.cache/moog-antithesis-dashboard"))]
    {:root (root) :cache cache :out (env "DASHBOARD_OUT" (str cache "/out"))
     :tenant (env "ANTITHESIS_TENANT" "amaru-cardano")
     :anti-key (env "ANTITHESIS_API_KEY_FILE" "/run/secrets/antithesis-key")
     :gh-key (env "GH_READ_TOKEN_FILE" "/run/secrets/gh-read")
     :moog-env (env "MOOG_READ_ENV_FILE" "/run/secrets/moog-read-env")
     :moog-dir (env "MOOG_DIR" "/opt/moog")
     :status-repo (env "STATUS_REPOSITORY" "lambdasistemi/moog-antithesis-dashboard")
     :proxy (env "PROXY_URL" "https://antithesis-proxy.plutimus.com/readyz")}))
(defn fail! [message] (throw (ex-info message {:public true})))
(defn public-message [error fallback] (if (:public (ex-data error)) (ex-message error) fallback))
(defn run
  ([args] (run args {}))
  ([args opts]
   (let [p (process/process args (merge {:in "" :out :string :err :string :continue true} opts))]
     (swap! running conj (:proc p))
     (try (let [result @p]
            (when-not (zero? (:exit result)) (fail! "External command failed"))
            (:out result))
          (finally (swap! running disj (:proc p)))))))
(defn read-key [path] (if (file? path) (str/trim (slurp path)) (fail! "Credential file unavailable")))
(defn config-string [s]
  (when (re-find #"[\r\n]" s) (fail! "Invalid HTTP configuration"))
  (str/escape s {\\ "\\\\" \" "\\\""}))
(defn http [url {:keys [key body timeout max-size] :or {timeout 60}}]
  (run (cond-> ["curl" "-K" "-" "--max-time" (str timeout)]
         body (into ["--data-binary" body])
         max-size (into ["--max-filesize" (str max-size)]))
       {:in (str "url = \"" (config-string url) "\"\nsilent\nshow-error\nfail\n"
                 (when key (format "header = \"Authorization: Bearer %s\"\n" (config-string key)))
                 (when body "header = \"Content-Type: application/json\"\n"))}))
(defn parse-env [text]
  (into {} (keep (fn [line]
                   (when-let [[_ name value] (re-matches #"(?:export )?([A-Za-z_][A-Za-z0-9_]*)=(.*)" line)]
                     [name (if (and (>= (count value) 2)
                                    (or (and (str/starts-with? value "\"") (str/ends-with? value "\""))
                                        (and (str/starts-with? value "'") (str/ends-with? value "'"))))
                             (subs value 1 (dec (count value))) value)]))
                 (str/split-lines text))))
(defn gh [config & args]
  (run (into ["gh"] args) {:extra-env {"GH_TOKEN" (read-key (:gh-key config))}}))
(defn gh-download [config url path]
  (run ["gh" "api" url] {:out (fs/file path) :extra-env {"GH_TOKEN" (read-key (:gh-key config))}}))
