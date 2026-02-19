# Subscription Control

OpenShift CronJob that daily collects CPU and node information from managed clusters via ACM (Advanced Cluster Management) and stores it in a PostgreSQL database.

## Prerequisites

- Red Hat Advanced Cluster Management (ACM) installed with all OpenShift clusters registered as ManagedClusters
- Namespace `subscription-control` created on the ACM hub cluster
- Each managed cluster must have a Secret containing the authentication token in its corresponding namespace on the ACM hub (e.g., namespace `cluster-01` for cluster `cluster-01`). The default Secret name is `application-manager`, configurable via the `TOKENSECRET` environment variable.
- Optionally, each ManagedCluster can have a label indicating its subscription type (default label: `subscription-type`). The label name is configurable via the `SUBSTYPELABEL` environment variable. Example values: `ocp`, `oke`, `ove`, `ibmcp`, etc. Clusters without this label will be tagged as `no-label`.
- PostgreSQL instance accessible from the cluster
- Grafana Operator installed on the cluster via OperatorHub

## Architecture

The CronJob runs two containers in parallel, coordinated through files on a shared `emptyDir` volume (`/tmp`):

1. **run-subscription-cpu** — queries each managed cluster's API, collects worker node data, and generates a CSV.
2. **run-subscription-db-insert** — waits for the first container to finish and imports the CSV into PostgreSQL.

```
┌─────────────────────────────────────────────────────┐
│ CronJob Pod                                         │
│                                                     │
│  ┌───────────────────┐  ┌────────────────────────┐  │
│  │  subscription-cpu │  │ subscription-db-insert │  │
│  │    (ose-cli)      │  │    (postgresql-16)     │  │
│  │                   │  │                        │  │
│  │  oc get nodes ──► │  │  waits for done.txt ─► │  │
│  │  writes data.csv  │  │  \copy CSV → table     │  │
│  │  writes done.txt  │  │                        │  │
│  └─────────┬─────────┘  └────────────┬───────────┘  │
│            │      /tmp (emptyDir)    │              │
│            └─────────────────────────┘              │
└─────────────────────────────────────────────────────┘
```

## Deploy

```bash
oc new-project subscription-control

# Permissions
oc apply -f serviceaccount-subscription-control-sa.yaml

# Database credentials (adjust before applying)
oc apply -f secret-subscription-db-credentials.yaml

# ConfigMaps with scripts
oc apply -f configmap-subscription-cpu.yaml
oc apply -f configmap-subscription-db-insert.yaml

# CronJob
oc apply -f cronjob-subscription-control-cj.yaml

# Grafana (requires Grafana Operator installed)
oc apply -f grafana-subscription-control-grafana.yaml
oc apply -f grafanadatasource-subscription-postgresql.yaml
oc apply -f grafanadashboard-subscription-control-dashboard.yaml
```

## Files

| File | Description |
|---|---|
| `resources/subscription-cpu.sh` | Script that collects CPU/node data from clusters in parallel |
| `resources/subscription-db-insert.sh` | Script that imports the generated CSV into PostgreSQL |
| `resources/grafana-dashboard.json` | Grafana dashboard JSON (standalone import) |
| `configmap-subscription-cpu.yaml` | ConfigMap containing the `subscription-cpu.sh` script |
| `configmap-subscription-db-insert.yaml` | ConfigMap containing the `subscription-db-insert.sh` script |
| `cronjob-subscription-control-cj.yaml` | CronJob manifest (runs daily at 23:00) |
| `serviceaccount-subscription-control-sa.yaml` | ServiceAccount, ClusterRole, and ClusterRoleBinding |
| `secret-subscription-db-credentials.yaml` | Secret template with PostgreSQL credentials |
| `grafana-subscription-control-grafana.yaml` | Grafana instance (Grafana Operator CR) |
| `grafanadatasource-subscription-postgresql.yaml` | PostgreSQL datasource (Grafana Operator CR) |
| `grafanadashboard-subscription-control-dashboard.yaml` | GrafanaDashboard CR (contains the `grafana-dashboard.json` embedded) |

## Execution Flow

### subscription-cpu.sh

1. Lists all managed clusters in ACM (excluding `local-cluster`)
2. For each cluster, in parallel (`PARALLEL=8`):
   - Retrieves metadata: `clusterID`, `apiserverurl`
   - Retrieves label defined by `SUBSTYPELABEL` (default: `subscription-type`)
   - Extracts the token from the Secret defined by `TOKENSECRET` (default: `application-manager`) in the cluster's namespace
   - Queries worker nodes (excluding infra nodes) via remote API
   - Writes one line per node in the format: `acm,cluster,clusterid,subtype,node,cpu,providerid`
3. Merges partial CSVs into `/tmp/data.csv`
4. Creates `/tmp/done.txt` (success) or `/tmp/fail.txt` (failure)

### subscription-db-insert.sh

1. Validates environment variables and `psql` availability
2. Waits for `/tmp/done.txt` or `/tmp/fail.txt` (polling every 5s)
3. Tests database connectivity
4. Creates the `subscription` table if it does not exist
5. Imports the CSV via a temporary table with `\copy`

## Environment Variables

All variables below can be customized via `env` in the CronJob manifest (`cronjob-subscription-control-cj.yaml`).

### subscription-cpu.sh (container `run-subscription-cpu`)

| Variable | Default | Description | CronJob |
|---|---|---|---|
| `ACMNAME` | `acm` | ACM hub identifier used to tag collected data | `env` value (`acm-01`) |
| `PARALLEL` | `8` | Number of clusters processed in parallel | not set (uses default) |
| `SUBSTYPELABEL` | `subscription-type` | ManagedCluster label name used to read the subscription type | not set (uses default) |
| `TOKENSECRET` | `application-manager` | Name of the Secret in each cluster's namespace containing the authentication token | not set (uses default) |

### subscription-db-insert.sh (container `run-subscription-db-insert`)

| Variable | Default | Description | CronJob |
|---|---|---|---|
| `PGHOST` | *(required)* | PostgreSQL host | `env` value |
| `PGPORT` | `5432` | PostgreSQL port | `env` value |
| `PGDATABASE` | *(required)* | Database name | `env` value |
| `PGUSER` | *(required)* | Database user | `secretKeyRef` (`subscription-db-credentials`) |
| `PGPASSWORD` | *(required)* | Database password | `secretKeyRef` (`subscription-db-credentials`) |
| `WAIT_INTERVAL_SECONDS` | `5` | Polling interval while waiting for the CPU container to finish (seconds) | not set (uses default) |
| `WAIT_MAX_SECONDS` | `0` | Maximum wait time for the CPU container (0 = infinite) | not set (uses default) |
| `RETENTION_DAYS` | `730` | Data retention period in days (~2 years) | not set (uses default) |

## PostgreSQL Table

```sql
CREATE TABLE IF NOT EXISTS subscription (
  id         BIGSERIAL PRIMARY KEY,
  acm        VARCHAR,
  cluster    VARCHAR,
  clusterid  VARCHAR,
  type       VARCHAR,
  node       VARCHAR,
  cpu        INTEGER,
  providerid VARCHAR,
  date       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

## RBAC

The CronJob runs under a dedicated ServiceAccount (`subscription-control-sa`) with a ClusterRole that grants **read-only** access to the following resources:

| Resource | Scope | Reason |
|---|---|---|
| `secrets` | Cluster-wide | Read the `application-manager` token in each managed cluster namespace to authenticate against remote cluster APIs |
| `namespaces` | Cluster-wide | Enumerate namespaces when resolving cluster resources |
| `configmaps` | Cluster-wide | Read ConfigMaps mounted as scripts |
| `projects` | Cluster-wide | OpenShift equivalent of namespaces; required for project-based access |
| `managedclusters` | Cluster-wide | List and inspect ACM ManagedCluster objects (clusterID, apiserver URL, subscription-type label) |

> **Note:** Cluster-wide secret read access is required because each managed cluster has its own namespace containing the `application-manager` secret. There is no way to restrict this to specific namespaces ahead of time, as clusters are added dynamically.

## Grafana Dashboard

The **Subscription Control** dashboard provides visibility into cluster count, node count, and vCPU usage over time. It includes four cascading filter variables:

| Variable | Label | Description |
|---|---|---|
| `acm` | ACM | Filters by ACM hub name |
| `type` | Type | Filters by subscription type (depends on ACM selection) |
| `provider` | Provider | Filters by infrastructure provider extracted from `providerid` (depends on ACM and Type) |
| `cluster` | Cluster | Filters by cluster name (depends on all above) |

All variables support **multi-select** and **"All"** option. The Provider variable displays `EMPTY` for clusters without a defined `providerid`.

### Panels

| Panel | Type | Description |
|---|---|---|
| Clusters | stat | Total distinct clusters |
| Nodes | stat | Total distinct worker nodes |
| Total vCPUs | stat | Sum of vCPUs across all nodes |
| Cluster Count | timeseries | Daily cluster count |
| Total vCPU | timeseries | Daily total vCPU |
| vCPU per Type | timeseries | Daily vCPU breakdown per subscription type |
| vCPU per Cluster | timeseries | Daily vCPU breakdown per cluster |
| Workers per Cluster | timeseries | Daily node count breakdown per cluster |
