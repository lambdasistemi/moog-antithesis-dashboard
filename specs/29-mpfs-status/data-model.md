# Observations

One MPFS payload contains role, service_id, used_by, network, container, api, synchronization and reported_at. The two fixed service identities bind their consumer list and container name. Container image is a bounded legacy MPFS image reference; status is a Docker state. API observation contains reachability and nullable HTTP status. Synchronization is observed with boolean readiness, safe integer network/indexer slots and their nonnegative difference, or unmeasured with all values null.

Two independent snapshot sources are mpfs_collector and mpfs_roles. The mpfs object holds nullable collector and roles observations. Source status and timestamp describe freshness, not service health. A valid negative health observation is fresh.
