#!/bin/bash
set -euo pipefail

ACM="${ACMNAME:-acm}"
CSVFILE="/tmp/data.csv"
WORKDIR="/tmp/acm_nodes_$$"
CLUSTERSFILE="/tmp/clusters_$$.txt"
LOGFILE="/tmp/acm_nodes.log"
DONEFILE="/tmp/done.txt"
FAILFILE="/tmp/fail.txt"
PARALLEL="${PARALLEL:-8}"
SUBSTYPELABEL="${SUBSTYPELABEL:-subscription-type}"
TOKENSECRET="${TOKENSECRET:-application-manager}"

rm -f "${CSVFILE}" "${LOGFILE}" "${DONEFILE}" "${FAILFILE}"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}" "${CLUSTERSFILE}"' EXIT

LOG() {
  TS="$(date '+%F %T')"
  CLUSTER="${1:-}"
  shift || true
  if [ -n "${CLUSTER}" ]; then
    MSG="${TS} [${CLUSTER}] $*"
  else
    MSG="${TS} $*"
  fi
  echo "${MSG}"
  echo "${MSG}" >> "${LOGFILE}"
}

EXPORT_CLUSTER() {
  CLUSTER="$1"
  OUTFILE="$2"

  LOG "${CLUSTER}" "starting"

  META="$(oc get managedcluster "${CLUSTER}" -o jsonpath="{.metadata.labels.${SUBSTYPELABEL}}{\"|\"}{.metadata.labels.clusterID}{\"|\"}{range .status.clusterClaims[*]}{.name}{\"=\"}{.value}{\"\n\"}{end}")"

  SUBTYPE="${META%%|*}"
  META="${META#*|}"
  CLUSTERID="${META%%|*}"
  CLAIMS="${META#*|}"

  [ -n "${SUBTYPE}" ] || SUBTYPE="no-label"

  APIURL="$(printf '%s\n' "${CLAIMS}" | awk -F= '$1=="apiserverurl.openshift.io"{print $2; exit}')"
  if [ -z "${APIURL}" ]; then
    LOG "${CLUSTER}" "ERROR: missing apiserverurl"
    return 2
  fi

  TOKEN64="$(oc get secret -n "${CLUSTER}" "${TOKENSECRET}" -o jsonpath='{.data.token}' 2>/dev/null || true)"
  if [ -z "${TOKEN64}" ]; then
    LOG "${CLUSTER}" "ERROR: missing token"
    return 3
  fi
  TOKEN="$(printf '%s' "${TOKEN64}" | base64 -d)"

  NODESFILE="/tmp/nodes_${CLUSTER}_$$.txt"

  LOG "${CLUSTER}" "fetching nodes"

  if ! oc get nodes \
    --token="${TOKEN}" \
    --server="${APIURL}" \
    --insecure-skip-tls-verify \
    --selector='node-role.kubernetes.io/worker,!node-role.kubernetes.io/infra' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.capacity.cpu}{"|"}{.spec.providerID}{"\n"}{end}' \
    > "${NODESFILE}"; then
    LOG "${CLUSTER}" "ERROR: oc get nodes failed"
    rm -f "${NODESFILE}"
    return 4
  fi

  : > "${OUTFILE}"

  while IFS='|' read -r NODENAME NODECPU PROVIDERID; do
    [ -n "${NODENAME}" ] || continue
    printf '%s,%s,%s,%s,%s,%s,%s\n' \
      "${ACM}" "${CLUSTER}" "${CLUSTERID}" "${SUBTYPE}" "${NODENAME}" "${NODECPU}" "${PROVIDERID}" \
      >> "${OUTFILE}"
  done < "${NODESFILE}"

  rm -f "${NODESFILE}"

  ROWS="$(wc -l < "${OUTFILE}" | tr -d ' ')"
  LOG "${CLUSTER}" "done rows=${ROWS}"
}

export ACM WORKDIR LOGFILE SUBSTYPELABEL TOKENSECRET
export -f LOG EXPORT_CLUSTER

LOG "" "listing managedclusters"

oc get managedclusters -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
  | grep -v '^local-cluster$' \
  > "${CLUSTERSFILE}"

TOTAL="$(wc -l < "${CLUSTERSFILE}" | tr -d ' ')"
LOG "" "clusters=${TOTAL} parallel=${PARALLEL}"

xargs -r -P "${PARALLEL}" -I{} bash -c '
  : "${ACM:?}" "${WORKDIR:?}" "${LOGFILE:?}"
  CLUSTER="{}"
  OUTFILE="${WORKDIR}/${CLUSTER}.csv"
  if EXPORT_CLUSTER "${CLUSTER}" "${OUTFILE}"; then
    touch "${WORKDIR}/${CLUSTER}.ok"
  else
    RC=$?
    case ${RC} in
      2) REASON="missing apiserverurl claim" ;;
      3) REASON="missing ${TOKENSECRET} token" ;;
      4) REASON="oc get nodes failed" ;;
      *) REASON="unknown error (exit=${RC})" ;;
    esac
    LOG "${CLUSTER}" "WARN: skipped — ${REASON}"
    echo "${REASON}" > "${WORKDIR}/${CLUSTER}.fail"
  fi
' < "${CLUSTERSFILE}"

OK_COUNT="$(find "${WORKDIR}" -maxdepth 1 -name '*.ok' | wc -l | tr -d ' ')"
FAIL_COUNT="$(find "${WORKDIR}" -maxdepth 1 -name '*.fail' | wc -l | tr -d ' ')"

LOG "" "results: ok=${OK_COUNT} failed=${FAIL_COUNT} total=${TOTAL}"

if [ "${OK_COUNT}" -eq 0 ]; then
  LOG "" "all clusters failed"
  LOG "" "--- failed clusters ---"
  for F in "${WORKDIR}"/*.fail; do
    [ -f "${F}" ] || continue
    CNAME="$(basename "${F}" .fail)"
    CREASON="$(cat "${F}")"
    LOG "" "  ${CNAME}: ${CREASON}"
  done
  LOG "" "---"
  echo "FAILED $(date '+%F %T')" > "${FAILFILE}"
  exit 1
fi

if [ "${FAIL_COUNT}" -gt 0 ]; then
  LOG "" "WARNING: ${FAIL_COUNT} cluster(s) failed, continuing with partial results"
  LOG "" "--- failed clusters ---"
  for F in "${WORKDIR}"/*.fail; do
    [ -f "${F}" ] || continue
    CNAME="$(basename "${F}" .fail)"
    CREASON="$(cat "${F}")"
    LOG "" "  ${CNAME}: ${CREASON}"
  done
  LOG "" "---"
fi

LOG "" "merging results"

cat "${WORKDIR}"/*.csv > "${CSVFILE}" 2>/dev/null || : > "${CSVFILE}"

FINAL_ROWS="$(wc -l < "${CSVFILE}" | tr -d " ")"
LOG "" "finished rows=${FINAL_ROWS}"

echo "SUCCESS $(date '+%F %T') ok=${OK_COUNT} failed=${FAIL_COUNT}" > "${DONEFILE}"
exit 0
