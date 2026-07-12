#!/bin/bash
# CE-5 orchestrator: steady window -> kill primary -> watch promotion -> post window.
# All timestamps in epoch ms (UTC), logged to ce5-timeline.log
D="$(dirname "$0")"
TL="$D/ce5-timeline.log"
NS=eurotransit
CL=eurotransit-orders-db
ms() { echo $(($(date +%s%N)/1000000)); }
log() { echo "$(ms) $(date -u +%T.%3N) $*" | tee -a "$TL"; }

: > "$TL"
log "RUN-START steady-state window 90s under load"
sleep 90

PRIMARY=$(kubectl get cluster $CL -n $NS -o jsonpath='{.status.currentPrimary}')
log "PRE-KILL primary=$PRIMARY ready=$(kubectl get cluster $CL -n $NS -o jsonpath='{.status.readyInstances}')"
kubectl cnpg status $CL -n $NS > "$D/ce5-cnpg-pre.txt" 2>&1

log "T0-KILL deleting $PRIMARY"
kubectl delete pod "$PRIMARY" -n $NS --wait=false >> "$TL" 2>&1
log "T0-KILL-ISSUED"

# Watch: currentPrimary flip + readyInstances, 500ms cadence, log only transitions
LASTP="$PRIMARY"; LASTR="2"; FLIPPED=""
for i in $(seq 1 600); do
  P=$(kubectl get cluster $CL -n $NS -o jsonpath='{.status.currentPrimary}' 2>/dev/null)
  R=$(kubectl get cluster $CL -n $NS -o jsonpath='{.status.readyInstances}' 2>/dev/null)
  PH=$(kubectl get cluster $CL -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$P" != "$LASTP" ] || [ "$R" != "$LASTR" ]; then
    log "TRANSITION primary=$P ready=$R phase=$PH"
    LASTP="$P"; LASTR="$R"
    [ "$P" != "$PRIMARY" ] && [ -z "$FLIPPED" ] && { FLIPPED=1; log "PRIMARY-FLIPPED to $P"; }
  fi
  # recovered: primary flipped AND 2 ready instances again
  if [ -n "$FLIPPED" ] && [ "$R" = "2" ]; then log "RECOVERED 2/2 with primary=$P"; break; fi
  sleep 0.5
done

log "POST-RECOVERY window 60s under load"
sleep 60
touch "$D/ce5-stop"
log "RUN-END harness stopped"
kubectl cnpg status $CL -n $NS > "$D/ce5-cnpg-post.txt" 2>&1
kubectl get events -n $NS --field-selector involvedObject.name=$CL --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,REASON:.reason,MSG:.message > "$D/ce5-events.txt" 2>&1
log "DONE"
