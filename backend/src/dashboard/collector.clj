(ns dashboard.collector
  (:require [dashboard.io :as io]
            [dashboard.antithesis :as anti]
            [dashboard.sources :as sources]
            [dashboard.compose :as compose]
            [babashka.fs :as fs]))

(def nightly-stages ["head-resolution" "runner-preflight" "day-claim" "resolve-upstream"
                     "launch-attempt" "bootstrap-proposal" "bootstrap-checks" "image-resolution"
                     "consumer-repin" "consumer-checks" "producer-check" "supervised-integration" "launch-cap" "launch"])
(defn collect! [config]
  (fs/create-dirs (str (:out config) "/runs"))
  (let [started (io/now)
        runs-source (sources/source config :runs #(anti/runs config))
        adapters [[:chain #(sources/chain (assoc config :visible-runs (:value runs-source)))] [:token #(sources/token config)]
                  [:oracle #(sources/host config "oracle")] [:agent #(sources/host config "agent")]
                  [:proxy #(sources/proxy config)] [:monitor #(sources/monitor config)] [:nightly #(sources/nightly config)]
                  [:wallets #(sources/wallets config)]
                  [:mpfs_collector #(sources/mpfs config :mpfs_collector "collector-legacy-mpfs")]
                  [:mpfs_roles #(sources/mpfs config :mpfs_roles "moog-role-legacy-mpfs")]]
        observations (assoc (into {} (map (fn [[name adapter]] [name (sources/source config name adapter)]) adapters)) :runs runs-source)
        value #(get-in observations [% :value])
        descriptions (atom {})
        runs (when (vector? (value :runs))
               (mapv (fn [run]
                       (let [rows (try (anti/property-set config (:run_id run) (:status run)) (catch Exception _ nil))
                             asset (compose/asset config run)
                             detail (if (nil? rows) (anti/unavailable run)
                                      (try (anti/detail config run rows (value :chain))
                                           (catch Exception _ (anti/unavailable run))))]
                         (doseq [property (:properties detail) :when (:description property)]
                           (swap! descriptions #(if (contains? % (:name property)) % (assoc % (:name property) (:description property)))))
                         (io/write-json! (str (:out config) "/runs/" (:run_id run) ".json")
                                         (assoc (update detail :properties (fn [ps] (mapv #(dissoc % :description) ps))) :compose asset))
                         (assoc run :properties (when rows (anti/summary rows)) :compose asset))) (value :runs)))
        oracle (value :oracle) agent (value :agent)
        snapshot {:schema_url "https://lambdasistemi.github.io/moog-antithesis-dashboard/openapi.json"
                  :generated_at (io/now) :started_at started :refresh_seconds 600 :tenant (:tenant config)
                  :repository sources/repository :sources (into {} (map (fn [[name result]] [name (:source result)]) observations))
                  :runs runs :chain (value :chain) :token (value :token)
                  :hosts {:oracle (or (:containers oracle) []) :agent (or (:containers agent) [])
                          :agent_errors_6h (:errors_6h agent) :agent_published_24h (:published_24h agent)}
                  :mpfs {:collector (value :mpfs_collector) :roles (value :mpfs_roles)}
                  :wallets (value :wallets) :proxy (value :proxy)
                  :monitor (when (value :monitor) (select-keys (value :monitor) [:last :ok]))
                  :nightly (value :nightly) :nightly_stages nightly-stages}]
    (io/write-json! (str (:out config) "/property-descriptions.json") @descriptions)
    (io/write-json! (str (:out config) "/data.json") snapshot)
    (println "collected:" (clojure.string/join " " (map (fn [[name result]] (str (clojure.core/name name) "=" (get-in result [:source :status]))) observations)))
    snapshot))
