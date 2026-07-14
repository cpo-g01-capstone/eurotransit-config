#!/bin/bash
# CE-5 Run 3: REVIEWER REPRODUCTION of run 2 (ADR 0019) — same method verbatim
# (SIGKILL of the current primary, 250ms status watch), pristine seeded state
# (`just seed-db ce-5`), run-3 output files. Run ce5-load.sh first with
# OUT=ce5-acks-run3.csv.
D="$(dirname "$0")"
TL="$D/ce5-timeline-run3.log"
NS=eurotransit
CL=eurotransit-orders-db
ms() { echo $(($(date +%s%N)/1000000)); }
log() { echo "$(ms) $(date -u +%T) $*" | tee -a "$TL"; }

: > "$TL"
log "RUN3-START steady-state window 45s under load"
sleep 45

PRIMARY=$(kubectl get cluster $CL -n $NS -o jsonpath='{.status.currentPrimary}')
log "PRE-KILL primary=$PRIMARY ready=$(kubectl get cluster $CL -n $NS -o jsonpath='{.status.readyInstances}')"

log "T0-KILL force-deleting $PRIMARY (SIGKILL, grace 0)"
kubectl delete pod "$PRIMARY" -n $NS --grace-period=0 --force --wait=false >> "$TL" 2>&1
log "T0-KILL-ISSUED"

LASTP="$PRIMARY"; LASTR="2"; FLIPPED=""
for i in $(seq 1 1200); do
  P=$(kubectl get cluster $CL -n $NS -o jsonpath='{.status.currentPrimary}' 2>/dev/null)
  R=$(kubectl get cluster $CL -n $NS -o jsonpath='{.status.readyInstances}' 2>/dev/null)
  PH=$(kubectl get cluster $CL -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$P" != "$LASTP" ] || [ "$R" != "$LASTR" ]; then
    log "TRANSITION primary=$P ready=$R phase=$PH"
    LASTP="$P"; LASTR="$R"
    [ "$P" != "$PRIMARY" ] && [ -z "$FLIPPED" ] && { FLIPPED=1; log "PRIMARY-FLIPPED to $P"; }
  fi
  if [ -n "$FLIPPED" ] && [ "$R" = "2" ]; then log "RECOVERED 2/2 with primary=$P"; break; fi
  sleep 0.25
done

log "POST-RECOVERY window 60s under load"
sleep 60
touch "$D/ce5-stop"
log "RUN3-END harness stopped"
kubectl cnpg status $CL -n $NS > "$D/ce5-cnpg-post-run3.txt" 2>&1
kubectl get events -n $NS --sort-by=.lastTimestamp 2>/dev/null | grep -i -E "orders-db|failover|promot" | tail -20 > "$D/ce5-events-run3.txt"
log "DONE"
