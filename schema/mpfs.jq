def exact($ks): type == "object" and (keys | sort) == ($ks | sort);
def slot: type == "number" and . >= 0 and . <= 9007199254740991 and floor == .;
def fail: error("invalid MPFS observation");
if (exact(["role","service_id","used_by","network","container","api","synchronization","reported_at"]) | not) then fail
elif .role != "mpfs" or .service_id != $service or .network != "preprod" then fail
elif .used_by != (if $service == "collector-legacy-mpfs" then ["dashboard-collector"] else ["oracle","agent"] end) then fail
elif (.container | exact(["name","image","status"]) | not) then fail
elif .container.name != (if $service == "collector-legacy-mpfs" then "mpfs-compose-mpfs-1" else "mpfs-mpfs-1" end) then fail
elif (.container.status as $state | ["created","running","paused","restarting","removing","exited","dead","missing"] | index($state)) == null then fail
elif (if .container.status == "missing" then .container.image != null
      else (.container.image | type) != "string" or (.container.image | length) > 200
        or (.container.image | test("^ghcr\\.io/cardano-foundation/mpfs/mpfs:[A-Za-z0-9_.-]+(@sha256:[a-f0-9]{64})?\\z") | not) end) then fail
elif (.api | exact(["reachable","http_status"]) | not) then fail
elif (.api.reachable | type) != "boolean" then fail
elif (.api.http_status != null and ((.api.http_status | slot) | not)) then fail
elif .api.http_status != null and (.api.http_status < 100 or .api.http_status > 599) then fail
elif .api.reachable != (.api.http_status != null and .api.http_status >= 200 and .api.http_status < 300) then fail
elif (.synchronization | exact(["status","ready","network_tip_slot","indexer_tip_slot","lag_slots"]) | not) then fail
elif (if .synchronization.status == "unmeasured" then
         .synchronization != {status:"unmeasured",ready:null,network_tip_slot:null,indexer_tip_slot:null,lag_slots:null}
       elif .synchronization.status == "observed" then
         .api.reachable != true or (.synchronization.ready | type) != "boolean"
         or ([.synchronization.network_tip_slot,.synchronization.indexer_tip_slot,.synchronization.lag_slots] | all(slot) | not)
         or .synchronization.lag_slots != (.synchronization.network_tip_slot - .synchronization.indexer_tip_slot)
       else true end) then fail
elif (.reported_at | type) != "string" or (.reported_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") | not) then fail
else (.reported_at | fromdateiso8601) as $at
  | if ($at | todateiso8601) != .reported_at or $at > $now then fail
    elif $at < ($now - 900) then error("expired MPFS observation") else . end
end
