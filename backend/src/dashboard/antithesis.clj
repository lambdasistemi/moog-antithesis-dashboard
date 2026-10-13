(ns dashboard.antithesis
  (:require [dashboard.io :as io])
  (:import [java.net URLEncoder]))

(defn get-json [config path]
  (when-not (re-matches #"[A-Za-z0-9-]+" (:tenant config)) (io/fail! "Invalid Antithesis tenant"))
  (io/decode (io/http (str "https://" (:tenant config) ".antithesis.com/api/v0/" path)
                      {:key (io/read-key (:anti-key config))})))
(defn safe-id! [id]
  (when-not (and (string? id) (re-matches #"[A-Za-z0-9_-]{1,200}" id))
    (io/fail! "Invalid run identifier"))
  id)
(defn properties [config id]
  (safe-id! id)
  (loop [cursor nil seen #{} result []]
    (let [page (get-json config (str "runs/" id "/properties?limit=100"
                                    (when cursor (str "&after=" (URLEncoder/encode cursor "UTF-8")))))
          rows (:data page) next (:next_cursor page)]
      (when-not (and (map? page) (vector? rows)
                     (every? #(and (map? %) (string? (:name %))
                                   (contains? #{"Passing" "Failing"} (:status %))) rows)
                     (or (nil? next) (and (string? next) (seq next))))
        (io/fail! "Invalid property page"))
      (when (or (contains? seen next) (>= (count seen) 10000))
        (io/fail! "Property pagination did not terminate"))
      (let [all (into result rows)]
        (if next (recur next (conj seen next) all) all)))))
(defn summary [rows]
  {:total (count rows) :passing (count (filter #(= "Passing" (:status %)) rows))
   :failing (mapv :name (remove #(= "Passing" (:status %)) rows))})
(defn property-set [config id status]
  (safe-id! id)
  (when (contains? #{"completed" "incomplete"} status)
    (let [path (str (:cache config) "/props/v3-" id ".json")
          cached (io/read-json path)]
      (if (and (= 3 (:schema_version cached)) (true? (:complete cached))
               (= id (:run_id cached)) (vector? (:data cached)))
        (:data cached)
        (let [rows (properties config id)]
          (when (and (= status "completed") (seq rows))
            (io/write-json! path {:schema_version 3 :complete true :run_id id :data rows}))
          rows)))))
(defn description [run]
  (try (or (:testRun (io/decode (:description run))) {}) (catch Exception _ {})))
(defn number-or-nil [value]
  (try (let [n (io/decode (str value))] (when (number? n) n)) (catch Exception _ nil)))
(defn normalize [run]
  (let [test (description run) repo (:repository test)]
    (merge {:run_id (:run_id run) :status (:status run) :created_at (:created_at run) :started_at (:started_at run)}
           {:test_name (get-in run [:parameters (keyword "antithesis.test_name")])
            :duration_minutes (number-or-nil (get-in run [:parameters (keyword "antithesis.duration")] "0"))
            :directory (:directory test) :commit (:commitId test) :try (:try test)
            :requester (:requester test)
            :repository (when repo (str (:organization repo) "/" (:repo repo)))})))
(defn runs [config]
  (let [page (get-json config "runs?limit=25")]
    (when-not (vector? (:data page)) (io/fail! "Invalid run list"))
    (mapv #(do (safe-id! (:run_id %)) (normalize %)) (:data page))))
(defn unavailable [run]
  {:run_id (:run_id run) :status (:status run) :unavailable true :properties [] :chain nil :nightly []})
(defn detail [config run rows chain nightly]
  (let [id (safe-id! (:run_id run)) path (str (:cache config) "/details/v3-" id ".json")
        cached (io/read-json path)
        base (or cached (let [raw (get-json config (str "runs/" id))]
                          (merge (normalize raw) {:status (or (:status raw) (:status run))
                                                  :completed_at (:completed_at raw) :parameters (or (:parameters raw) {})})))
        day #(subs (or % "") 0 (min 10 (count (or % ""))))
        match (first (filter #(and (= (:directory %) (:directory base))
                                   (= (:commit %) (:commit base)) (= (:try %) (:try base))) (:recent chain)))
        detail (assoc base :run_id id
                      :properties (mapv #(merge (select-keys % [:name :description :status :is_group])
                                                 {:is_event (:is_event %) :example_count (:example_count %)
                                                  :counterexample_count (:counterexample_count %)
                                                  :counterexamples (or (:counterexamples %) [])}) rows)
                      :chain (when (and (:commit base) match) (select-keys match [:phase :outcome :slot]))
                      :nightly (if (= (:directory base) "testnets/cardano_amaru")
                                 (mapv #(merge (select-keys % [:url :conclusion :status]) (select-keys (:receipt %) [:day :stage :error]))
                                       (filter #(= (day (:createdAt %)) (day (:created_at base))) nightly)) []))]
    (when (and (not cached) (seq rows) (contains? #{"completed" "incomplete"} (:status detail)))
      (io/write-json! path detail))
    detail))
