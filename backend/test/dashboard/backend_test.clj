(ns dashboard.backend-test
  (:require [clojure.test :refer [deftest is testing]]
            [babashka.fs :as fs]
            [clojure.string :as str]
            [dashboard.io :as io]
            [dashboard.antithesis :as anti]
            [dashboard.sources :as sources]
            [dashboard.collector :as collector]
            [dashboard.main :as main]
            [dashboard.publication :as publication]))

(defn temporary [f]
  (let [dir (fs/create-temp-dir)] (try (f (str dir)) (finally (fs/delete-tree dir)))))
(defn property [n] {:name (str "result-" n) :status "Passing" :is_group (even? n)})
(deftest top-level-json-arrays-are-eager
  (is (vector? (io/decode "[{\"balance\":\"9007199254740993\"}]")))
  (is (= "9007199254740993" (:balance (first (io/decode "[{\"balance\":\"9007199254740993\"}]"))))))
(deftest complete-pages-and-cache-generation
  (temporary
   (fn [dir]
     (let [config {:cache dir} seen (atom [])
           page (fn [_ path] (swap! seen conj path)
                  (if (str/includes? path "after=") {:data (mapv property (range 100 169)) :next_cursor nil}
                    {:data (mapv property (range 100)) :next_cursor "cursor/?+="}))]
       (io/write-json! (str dir "/props/v2-run.json") {:total 50 :passing 50 :failing []})
       (with-redefs [anti/get-json page]
         (let [rows (anti/property-set config "run" "completed")]
           (is (= 169 (:total (anti/summary rows))))
           (is (= 169 (:passing (anti/summary rows))))
           (is (str/includes? (last @seen) "after=cursor%2F%3F%2B%3D"))
           (is (true? (:complete (io/read-json (str dir "/props/v3-run.json")))))))
       (with-redefs [anti/get-json (fn [& _] (throw (Exception. "offline")))]
         (is (= 169 (count (anti/property-set config "run" "completed")))))
       (doseq [bad [nil {:data nil} {:data [{:name "bad" :status "Unknown"}]} {:data [] :next_cursor 1}]]
         (with-redefs [anti/get-json (constantly bad)]
           (is (thrown? Exception (anti/property-set config "invalid" "completed")))
           (is (not (fs/exists? (str dir "/props/v3-invalid.json"))))))
       (with-redefs [anti/get-json (constantly {:data [] :next_cursor "cycle"})]
         (is (thrown-with-msg? Exception #"did not terminate" (anti/property-set config "cyclic" "completed"))))
       (with-redefs [anti/get-json (fn [_ path] (if (str/includes? path "after=") (throw (Exception. "later page failed"))
                                                 {:data [(property 1)] :next_cursor "second"}))]
         (is (thrown? Exception (anti/property-set config "partial" "completed")))
         (is (not (fs/exists? (str dir "/props/v3-partial.json")))))
       (with-redefs [anti/get-json (fn [& _] (throw (Exception. "must not fetch running")))]
         (is (nil? (anti/property-set config "running" "in_progress"))))))))
(deftest summary-and-detail-share-the-complete-population
  (temporary
   (fn [dir]
     (let [config {:cache dir :out (str dir "/out") :root (io/root)}
           rows (mapv #(assoc (property %) :status (if (< % 30) "Failing" "Passing")) (range 169))
           raw {:run_id "run" :status "completed" :description "{}" :parameters {}}
           run (anti/normalize raw)]
       (io/write-json! (str dir "/details/run.json") (assoc raw :properties []))
       (with-redefs [anti/get-json (constantly raw)]
         (is (= rows (mapv #(select-keys % [:name :status :is_group]) (:properties (anti/detail config run rows nil [])))))
         (is (= 30 (count (:failing (anti/summary rows))))))))))

(def address-a (str "addr_test1" (apply str (repeat 30 "a"))))
(def address-b (str "addr_test1" (apply str (repeat 30 "b"))))
(def coordinates {:schema_version 1 :wallets [{:id "oracle" :role "oracle" :network "preprod"
                                              :addresses [address-a address-b] :scope_evidence "fixture"}]})
(def wallet-response [{:address address-a :balance "9007199254740993"} {:address address-b :balance "2"}])
(deftest exact-wallets-stale-recovery-and-invalid-inputs
  (temporary
   (fn [dir]
     (let [config {:cache dir}
           expected "9007199254740995"
           revision (apply str (repeat 40 "1"))]
       (with-redefs [sources/wallet-config (constantly [revision coordinates])
                     sources/wallet-query (constantly wallet-response)]
         (let [good (sources/source config :wallets #(sources/wallets config))
               at (get-in good [:source :last_success])]
           (is (= "ok" (get-in good [:source :status])))
           (is (= expected (get-in good [:value :accounts 0 :balance_lovelace])))
           (with-redefs [sources/wallet-query (fn [_] (throw (Exception. "provider response private material")))]
             (let [old (sources/source config :wallets #(sources/wallets config))]
               (is (= "stale" (get-in old [:source :status])))
               (is (= at (get-in old [:source :last_success])))
               (is (= expected (get-in old [:value :accounts 0 :balance_lovelace])))
               (is (not (str/includes? (get-in old [:source :error]) "private material")))))
           (is (= "ok" (get-in (sources/source config :wallets #(sources/wallets config)) [:source :status])))))
       (doseq [bad [(subvec wallet-response 0 1) [(first wallet-response) (first wallet-response)]
                   (assoc-in wallet-response [0 :balance] "-1") (assoc-in wallet-response [0 :balance] "1.5")
                   (update wallet-response 0 dissoc :balance)]]
         (with-redefs [sources/wallet-config (constantly [revision coordinates]) sources/wallet-query (constantly bad)]
           (is (thrown? Exception (sources/wallets config)))))
       (doseq [bad [(assoc-in coordinates [:wallets 0 :network] "preview")
                   (assoc-in coordinates [:wallets 0 :addresses] [address-a address-a])
                   (assoc-in coordinates [:wallets 0 :private_key] "planted")]]
         (is (not (sources/valid-wallet-config? bad))))
       (with-redefs [sources/wallet-config (constantly [revision coordinates]) sources/wallet-query (fn [_] (io/fail! "wallets: Koios unavailable"))]
         (let [result (sources/source {:cache (str dir "/empty")} :wallets #(sources/wallets config))]
           (is (= "error" (get-in result [:source :status]))) (is (nil? (:value result)))))))))
(deftest cycle-lock-is-held-through-collection-and-publication
  (temporary
   (fn [dir]
     (let [events (atom []) config {:cache dir}]
       (with-redefs [collector/collect! (fn [_] (swap! events conj :collect)
                                        (main/cycle! config))
                     publication/publish! (fn [_] (swap! events conj :publish))]
         (main/cycle! config))
       (is (= [:collect :publish] @events))
       (with-redefs [collector/collect! (fn [_] (io/fail! "failed"))
                     publication/publish! (fn [_] (swap! events conj :bad-publish))]
         (is (thrown? Exception (main/cycle! config))))
       (with-redefs [collector/collect! (fn [_] (swap! events conj :recovered))
                     publication/publish! (fn [_] nil)] (main/cycle! config))
       (is (= [:collect :publish :recovered] @events))))))

(deftest credential-helper-executes-without-project-cwd
  (temporary
   (fn [dir]
     (let [key (str dir "/push-key")]
       (spit key "synthetic-push-value")
       (let [output (io/run ["git" "-c" "credential.helper=" "-c" "credential.helper=!bb --main dashboard.main credentials" "credential" "fill"]
                            {:dir dir :in "protocol=https\nhost=github.com\n\n"
                             :extra-env {"PAGES_PUSH_TOKEN_FILE" key "GIT_TERMINAL_PROMPT" "0"
                                         "GIT_CONFIG_NOSYSTEM" "1" "GIT_CONFIG_GLOBAL" "/dev/null"
                                         "BABASHKA_CLASSPATH" (str (io/root) "/backend/src")}})
             username-ok? (str/includes? output "username=x-access-token")
             password-ok? (str/includes? output "password=synthetic-push-value")]
         (is username-ok?)
         (is password-ok?))))))
