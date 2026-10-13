(ns dashboard.main
  (:require [dashboard.io :as io]
            [dashboard.collector :as collector]
            [dashboard.publication :as publication]
            [dashboard.compose :as compose]
            [babashka.fs :as fs])
  (:import [java.nio.channels FileChannel]
           [java.nio.file StandardOpenOption]
           [sun.misc Signal SignalHandler]))

(def shutting-down (atom false))
(defn cycle! [config]
  (fs/create-dirs (:cache config))
  (with-open [channel (FileChannel/open (fs/path (:cache config) "cycle.lock")
                                        (into-array StandardOpenOption [StandardOpenOption/CREATE StandardOpenOption/WRITE]))]
    (let [lock (try (.tryLock channel) (catch Exception _ nil))]
      (if-not lock (println "previous cycle still running, skipping")
        (do (collector/collect! config) (publication/publish! config))))))
(defn loop! [config]
  (let [interval (Long/parseLong (io/env "DASHBOARD_INTERVAL" "600"))
        maximum (Long/parseLong (io/env "DASHBOARD_MAX_CYCLES" "0"))
        cycle-command (io/env "CYCLE_CMD" nil)
        main-thread (Thread/currentThread)
        handler (reify SignalHandler
                  (handle [_ _] (reset! shutting-down true)
                    (doseq [p @io/running] (.destroy p))
                    (.interrupt main-thread)))
        previous (mapv (fn [name] (let [signal (Signal. name)] [signal (Signal/handle signal handler)])) ["TERM" "INT"])]
    (when (or (neg? interval) (neg? maximum)) (io/fail! "Invalid loop configuration"))
    (reset! shutting-down false)
    (try (loop [cycles 0]
           (when-not @shutting-down
             (try (if cycle-command (io/run [cycle-command]) (cycle! config))
                  (catch Exception _ (binding [*out* *err*] (println "cycle failed at" (io/now) ", continuing"))))
             (when (and (not @shutting-down) (or (zero? maximum) (< (inc cycles) maximum)))
               (try (Thread/sleep (* interval 1000)) (catch InterruptedException _ (reset! shutting-down true)))
               (recur (inc cycles)))))
         (finally (doseq [[signal old] previous] (Signal/handle signal old))))))
(defn command [{:keys [action args]}]
  (try (let [config (io/config)]
         (case action
           "collect" (collector/collect! config)
           "publish" (publication/publish! config)
           "cycle" (cycle! config)
           "loop" (loop! config)
           "compose" (let [[run cache out] args] (println (io/encode (compose/asset (assoc config :cache cache :out out) (io/decode run)))))
           "credentials" (publication/credentials!)
           (io/fail! "Unknown collector command")))
       (catch Exception error
         (binding [*out* *err*] (println (io/public-message error "Collector command failed")))
         (System/exit (or (:exit (ex-data error)) 1)))))
(defn -main [action & args] (command {:action action :args args}))
