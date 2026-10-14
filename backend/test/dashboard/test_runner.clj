(ns dashboard.test-runner
  (:require [clojure.test :as t]
            [dashboard.backend-test]))
(def groups
  {"chain" [#'dashboard.backend-test/public-chain-coverage-and-visible-records
             #'dashboard.backend-test/detail-chain-match-preserves-requester]
   "wallets" [#'dashboard.backend-test/top-level-json-arrays-are-eager
              #'dashboard.backend-test/exact-wallets-stale-recovery-and-invalid-inputs]
   "properties" [#'dashboard.backend-test/complete-pages-and-cache-generation
                  #'dashboard.backend-test/summary-and-detail-share-the-complete-population]
   "loop" [#'dashboard.backend-test/cycle-lock-is-held-through-collection-and-publication]
   "publication" [#'dashboard.backend-test/credential-helper-executes-without-project-cwd]})
(defn run
  ([] (let [result (t/run-tests 'dashboard.backend-test)]
        (when (pos? (+ (:fail result) (:error result))) (System/exit 1))))
  ([group]
   (when-not (contains? groups group) (throw (ex-info "Unknown test group" {})))
   (binding [t/*report-counters* (ref t/*initial-report-counters*)]
     (t/test-vars (get groups group))
     (let [result @t/*report-counters*]
       (println group result)
       (when (pos? (+ (:fail result) (:error result))) (System/exit 1))))))
(defn -main [& [group]] (if group (run group) (run)))
