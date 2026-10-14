(ns dashboard.identity
  (:require [clojure.string :as str]))

(def fields [:requester :platform :repository :directory :commit :try])
(defn run-key [record] (mapv record fields))
(defn complete? [record]
  (and (integer? (:try record)) (not (neg? (:try record)))
       (every? #(and (string? %) (not (str/blank? %))) (butlast (run-key record)))))
(defn coordinates [test]
  (let [repo (:repository test)]
    {:requester (:requester test) :platform (:platform test)
     :repository (when (and (:organization repo) (:repo repo)) (str (:organization repo) "/" (:repo repo)))
     :directory (:directory test) :commit (:commitId test) :try (:try test)}))
