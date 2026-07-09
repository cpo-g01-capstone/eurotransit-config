#!/usr/bin/env bash
# Schema-validate the rendered eurotransit chart with kubeconform.
#
# Compensating control for the Argo CD SkipDryRunOnMissingResource decision
# (ADR 0003): a typo'd `kind`/`apiVersion` should fail here, offline, instead of
# being silently treated as a "missing CRD" that Argo retries forever.
#
# Validates built-in kinds against upstream schemas and known CRDs (cert-manager,
# monitoring.coreos.com, traefik.io, kafka.strimzi.io, postgresql.cnpg.io) against
# the datreeio CRDs-catalog. Unknown kinds are skipped (-ignore-missing-schemas) so
# a catalog gap can't produce a false failure — see ADR 0003 for the limitation.
#
# Requires: helm, kubeconform (brew install kubeconform). Needs network for the catalog.
set -euo pipefail

CHART="${1:-deploy/charts/eurotransit}"
CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

if ! command -v kubeconform >/dev/null 2>&1; then
  echo "ERROR: kubeconform not found. Install it: brew install kubeconform" >&2
  exit 127
fi

echo "Schema-validating rendered manifests..."
helm template eurotransit "$CHART" --namespace eurotransit -f "${CHART}/values.yaml" \
  | kubeconform -strict -summary -ignore-missing-schemas \
      -schema-location default \
      -schema-location "$CATALOG"
echo "OK: kubeconform schema validation passed."
