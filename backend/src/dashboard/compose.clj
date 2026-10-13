(ns dashboard.compose
  (:require [dashboard.io :as io]
            [babashka.fs :as fs]
            [clojure.string :as str])
  (:import [java.net URLEncoder]
           [java.security MessageDigest]))
(def secret-pattern #"auth=|v2\.public|Bearer |Authorization|-u [^ ]+:[^ ]+|password")
(defn coordinates? [r]
  (and (string? (:run_id r)) (re-matches #"[A-Za-z0-9_-]{1,200}" (:run_id r))
       (string? (:repository r)) (re-matches #"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+" (:repository r))
       (every? #(not (contains? #{"." ".."} %)) (str/split (:repository r) #"/"))
       (string? (:commit r)) (re-matches #"[0-9a-fA-F]{40}" (:commit r))
       (string? (:directory r)) (seq (:directory r))
       (every? #(and (seq %) (not (contains? #{"." ".."} %)) (re-matches #"[A-Za-z0-9_. -]+" %))
               (str/split (:directory r) #"/" -1))))
(defn unavailable [reason] {:status "unavailable" :reason reason :url nil :source_url nil :commit nil :internal_network true})
(defn digest [text] (format "%064x" (BigInteger. 1 (.digest (MessageDigest/getInstance "SHA-256") (.getBytes text "UTF-8")))))
(defn asset [config run]
  (if-not (coordinates? run) (unavailable "missing_or_invalid_coordinates")
    (let [{:keys [run_id repository commit directory]} run
          dir (str/join "/" (map #(str/replace (URLEncoder/encode % "UTF-8") "+" "%20") (str/split directory #"/")))
          path (str (:cache config) "/compose/" (digest (str repository "\n" commit "\n" dir "\n")))
          output (str (:out config) "/runs/" run_id "/docker-compose.yaml")
          cached (when (io/file? (str path ".yaml")) (io/read-json (str path ".json")))
          value (or cached
                    (some (fn [filename]
                            (try (let [raw (io/run ["curl" "--fail" "--silent" "--show-error" "--proto" "=https"
                                                   "--connect-timeout" "5" "--max-time" "10" "--max-filesize" "1048576"
                                                   (str "https://raw.githubusercontent.com/" repository "/" commit "/" dir "/" filename)])
                                       local (str/replace raw "${INTERNAL_NETWORK}" "true")]
                                   (when (and (seq local) (<= (count (.getBytes local "UTF-8")) 1048576))
                                     (if (re-find secret-pattern local) (unavailable "publication_refused")
                                       (let [metadata {:status "available" :reason nil :internal_network true :commit commit
                                                       :source_url (str "https://github.com/" repository "/blob/" commit "/" dir "/" filename)}]
                                         (io/atomic-text! (str path ".yaml") local)
                                         (io/write-json! (str path ".json") metadata) metadata))))
                                 (catch Exception _ nil))) ["docker-compose.yaml" "docker-compose.yml"]))]
      (if (= "available" (:status value))
        (do (fs/create-dirs (fs/parent output)) (fs/copy (str path ".yaml") output {:replace-existing true})
            (assoc value :url (str "runs/" run_id "/docker-compose.yaml")))
        (do (fs/delete-if-exists output) (or value (unavailable "source_unavailable")))))))
