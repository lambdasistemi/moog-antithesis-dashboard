(ns dashboard.sources
  (:require [dashboard.io :as io]
            [dashboard.identity :as identity]
            [babashka.fs :as fs]
            [clojure.string :as str]))

(def repository "cardano-foundation/cardano-node-antithesis")
(defn exact? [m fields] (and (map? m) (= (set (keys m)) (set fields))))
(defn text? [s] (and (string? s) (<= (count s) 200)))
(defn count? [n] (and (number? n) (<= 0 n) (== n (Math/floor (double n)))))
(defn status-valid? [role value at]
  (and (exact? value (case role "monitor" [:role :verdict :ok :reported_at]
                                          "agent" [:role :containers :errors_6h :published_24h :reported_at]
                                          [:role :containers :reported_at]))
       (= role (:role value))
       (text? (:reported_at value))
       (re-matches #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z" (:reported_at value))
       (<= (io/epoch (:reported_at value)) at)
       (if (= role "monitor")
         (and (text? (:verdict value)) (seq (:verdict value))
              (not (re-find #"https?://" (:verdict value)))
              (boolean? (:ok value)) (= (:ok value) (str/starts-with? (:verdict value) "OK")))
         (and (vector? (:containers value)) (<= (count (:containers value)) 50)
              (every? #(and (exact? % [:name :image :status])
                            (every? text? (map % [:name :image :status]))) (:containers value))
              (or (not= role "agent") (and (count? (:errors_6h value)) (count? (:published_24h value))))))))
(defn issue-body [config source]
  (let [upper (str/upper-case (name source))
        seam (io/env (str "STATUS_BODY_CMD_" upper) (when (= source :oracle) (io/env "STATUS_BODY_CMD" nil)))
        issue (io/env (str "STATUS_ISSUE_" upper) nil)]
    (if (seq seam)
      (try (io/run ["bash" "-c" seam]) (catch Exception _ (io/fail! (str (name source) " status: fetch failed"))))
      (do (when-not (seq issue) (io/fail! (str (name source) " status: no issue number")))
          (try (io/gh config "api" (str "repos/" (:status-repo config) "/issues/" issue) "--jq" ".body")
               (catch Exception _ (io/fail! (str (name source) " status: fetch failed"))))))))
(defn host [config role]
  (let [value (try (io/decode (issue-body config (keyword role)))
                   (catch Exception _ (io/fail! (str role " status: invalid payload"))))
        at (io/epoch (io/now))]
    (when-not (try (status-valid? role value at) (catch Exception _ false))
      (io/fail! (str role " status: invalid payload")))
    (when (< (io/epoch (:reported_at value)) (- at 900))
      (io/fail! (str role " status: stale payload")))
    value))
(defn monitor [config]
  (let [payload (host config "monitor")]
    {:last (:verdict payload) :ok (:ok payload) :reported_at (:reported_at payload)}))
(defn mpfs [config source service]
  (try (let [body (issue-body config source)]
         (when (> (count body) 32768) (io/fail! "MPFS status: invalid or expired payload"))
         (io/decode (io/run ["jq" "-ec" "--arg" "service" service "--argjson" "now" (str (io/epoch (io/now)))
                            "-f" (str (:root config) "/schema/mpfs.jq")] {:in body})))
       (catch Exception _ (io/fail! "MPFS status: invalid or expired payload"))))
(defn moog [config & args]
  (when-not (io/file? (:moog-env config)) (io/fail! "Moog read environment unavailable"))
  (io/decode (io/run (into [(str (:moog-dir config) "/moog")] args)
                    {:extra-env (assoc (io/parse-env (slurp (:moog-env config)))
                                       "PATH" (str (:moog-dir config) ":" (io/env "PATH" "/bin")))})))
(defn chain [config]
  (let [raw (moog config "facts" "test-runs" "--no-pretty")]
    (when-not (vector? raw) (io/fail! "Invalid Moog facts"))
    (let [facts (mapv #(merge (identity/coordinates (:key %))
                              {:phase (get-in % [:value :phase])
                               :outcome (get-in % [:value :outcome]) :duration (get-in % [:value :duration])
                               :slot (:slot %)}) raw)
          key identity/run-key
          ordered (reverse (sort-by :slot facts))
          retained (into (set (map key (take 30 ordered))) (map key (:visible-runs config)))]
      (when-not (every? identity/complete? facts)
        (io/fail! "Invalid test-run identity"))
      {:scope "all_requesters" :phases (frequencies (map :phase facts))
       :recent (vec (filter #(contains? retained (key %)) ordered))})))
(defn token [config] {:pending_requests (count (:requests (moog config "token" "--no-pretty")))})
(defn proxy [config]
  (let [code (try (io/run ["curl" "-s" "-o" "/dev/null" "-w" "%{http_code}" "--max-time" "20" (:proxy config)])
                  (catch Exception _ "000"))]
    {:ready (= code "200") :http_code (try (Integer/parseInt code) (catch Exception _ 0))}))
(defn receipt [config id conclusion]
  (let [path (str (:cache config) "/nightly/" id ".json")]
    (or (io/read-json path)
        (try (when-let [url (first (str/split-lines
                                   (io/gh config "api" (str "repos/" repository "/actions/runs/" id "/artifacts")
                                          "--jq" ".artifacts[] | select(.name | startswith(\"daily-amaru-receipt\")) | .archive_download_url")))]
               (let [dir (fs/create-temp-dir)]
                 (try (io/gh-download config url (str dir "/r.zip"))
                      (io/run ["unzip" "-q" "-o" (str dir "/r.zip") "-d" (str dir)])
                      (let [result (select-keys (io/parse-env (slurp (str dir "/receipt")))
                                                ["day" "stage" "outcome" "error" "upstream_sha" "bootstrap_candidate_sha"])
                            value (into {} (map (fn [[k v]] [(keyword k) v]) result))]
                        (when (seq conclusion) (io/write-json! path value)) value)
                      (finally (fs/delete-tree dir)))))
             (catch Exception _ nil)))))
(defn nightly [config]
  (let [runs (io/decode (io/gh config "run" "list" "-R" repository "-w" "daily-amaru.yaml" "-e" "schedule"
                              "-L" "14" "--json" "databaseId,conclusion,status,event,createdAt,url"))]
    (when-not (vector? runs) (io/fail! "Invalid nightly run list"))
    (mapv #(assoc % :receipt (receipt config (:databaseId %) (:conclusion %))) runs)))
(defn wallet-config [config]
  (let [revision (str/trim (io/gh config "api" (str "repos/" (:status-repo config) "/commits/" (io/env "WALLET_CONFIG_REF" "main")) "--jq" ".sha"))]
    (when-not (re-matches #"[0-9a-f]{40}" revision) (io/fail! "wallets: GitHub coordinates unavailable"))
    [revision (io/decode (String. (.decode (java.util.Base64/getMimeDecoder)
                                         (io/gh config "api" (str "repos/" (:status-repo config) "/contents/config/wallets.json?ref=" revision) "--jq" ".content")) "UTF-8"))]))
(defn valid-wallet-config? [value]
  (let [wallets (:wallets value)]
    (and (exact? value [:schema_version :wallets]) (= (:schema_version value) 1)
         (vector? wallets) (<= 1 (count wallets) 20) (= (count wallets) (count (set (map :id wallets))))
         (every? #(and (exact? % [:addresses :id :network :role :scope_evidence])
                       (string? (:id %)) (re-matches #"[a-z][a-z0-9_-]{0,39}" (:id %))
                       (contains? #{"oracle" "agent" "requester"} (:role %)) (= "preprod" (:network %))
                       (string? (:scope_evidence %)) (<= (count (:scope_evidence %)) 300)
                       (vector? (:addresses %)) (<= 1 (count (:addresses %)) 20)
                       (= (count (:addresses %)) (count (set (:addresses %)))))
                 wallets)
         (every? #(and (string? %) (re-matches #"addr_test1[0-9a-z]{20,120}" %)) (mapcat :addresses wallets)))))
(defn wallet-query [addresses]
  (io/decode (io/http "https://preprod.koios.rest/api/v1/address_info"
                      {:body (io/encode {:_addresses addresses}) :timeout 45 :max-size 5242880})))
(defn wallets [config]
  (let [[revision coordinates] (try (wallet-config config)
                                    (catch Exception _ (io/fail! "wallets: GitHub coordinates unavailable")))
        _ (when-not (valid-wallet-config? coordinates) (io/fail! "wallets: invalid coordinates"))
        addresses (vec (sort (set (mapcat :addresses (:wallets coordinates)))))
        response (try (wallet-query addresses) (catch Exception _ (io/fail! "wallets: Koios unavailable")))
        _ (when-not (and (vector? response) (= (sort (map :address response)) addresses)
                         (every? #(and (string? (:balance %)) (re-matches #"(?:0|[1-9][0-9]{0,17})" (:balance %))) response))
            (io/fail! "wallets: invalid or incomplete Koios response"))
        balances (into {} (map (juxt :address #(bigint (:balance %))) response))
        observed (io/now)]
    {:config_revision revision :provider "Koios" :network "preprod" :reported_at observed
     :chain_point nil :history_status "not_collected"
     :accounts (mapv (fn [wallet]
                       (let [amount (reduce +' 0 (map balances (:addresses wallet)))]
                         (when (> amount Long/MAX_VALUE) (io/fail! "wallets: balance exceeds supported integer range"))
                         (assoc (select-keys wallet [:id :role :network :addresses])
                                :balance_lovelace (str amount) :observed_at observed))) (:wallets coordinates))}))
(defn last-good [path]
  (try
    (let [record (io/read-json (str path ".v3.json"))]
      (if (and (exact? record [:value :last_success]) (string? (:last_success record)))
        (do (io/epoch (:last_success record)) record)
        (when (io/file? (str path ".json"))
          {:value (io/read-json (str path ".json"))
           :last_success (when (io/file? (str path ".at")) (str/trim (slurp (str path ".at"))))})))
    (catch Exception _ nil)))
(defn source [config name f]
  (let [path (str (:cache config) "/last/" (clojure.core/name name))]
    (try (let [value (f) at (or (:reported_at value) (io/now))]
           (io/write-json! (str path ".v3.json") {:value value :last_success at})
           {:value value :source {:status "ok" :error nil :last_success at}})
         (catch Exception error
           (let [previous (last-good path)]
             {:value (:value previous)
              :source {:status (if previous "stale" "error")
                       :error (io/public-message error (str (clojure.core/name name) ": source unavailable"))
                       :last_success (:last_success previous)}})))))
