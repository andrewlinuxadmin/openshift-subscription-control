# Subscription Control

OpenShift CronJob that daily collects CPU and node information from managed clusters via ACM (Advanced Cluster Management) and stores it in a database. Four deployment variants are available:

| Variant | Directory | Database | Integration |
|---|---|---|---|
| Shell + PostgreSQL | `shell-postgresql/` | PostgreSQL | CronJob with 2 containers (CSV) |
| Shell + MySQL | `shell-mysql/` | MySQL | CronJob with 2 containers (CSV) |
| API + PostgreSQL | `api-postgresql/` | PostgreSQL | Python API pod + CronJob with 1 container (HTTP) |
| API + MySQL | `api-mysql/` | MySQL | Python API pod + CronJob with 1 container (HTTP) |

## Directory Structure

```
subscription-control/
  common/                            # Shared resources (always apply first)
  shell-postgresql/                  # Variant 1: Shell + PostgreSQL
  shell-mysql/                       # Variant 2: Shell + MySQL
  api-postgresql/                     # Variant 3: Python API + PostgreSQL
    api/                             #   API pod (Python + psql)
    get-acm-info/                    #   CronJob data collector (requires ACM)
    grafana/                         #   Grafana dashboards and datasource
    secret-postgresql-credentials.yaml
  api-mysql/                         # Variant 4: Python API + MySQL
    api/                             #   API pod (Python + MySQL)
    get-acm-info/                    #   CronJob data collector (requires ACM)
    grafana/                         #   Grafana dashboards and datasource
    secret-mysql-credentials.yaml
  database-server/                   # Optional: deploy database inside OpenShift
    mysql-server/                    #   MySQL server manifests
    postgresql-server/               #   PostgreSQL server manifests
```

## Design Premises

- **No custom container images**: all components use official Red Hat images available in the Red Hat Container Catalog (`registry.redhat.io`). Scripts and application code are injected at runtime via ConfigMaps, eliminating the need to build and maintain custom images.
  - `registry.redhat.io/openshift4/ose-cli:latest` — CronJob containers (provides `oc`, `curl`, `awk`)
  - `registry.redhat.io/rhel9/mysql-80:latest` — API pod for MySQL variant (provides `python3`, `mysql` CLI) and MySQL server
  - `registry.redhat.io/rhel9/postgresql-15:latest` — API pod for PostgreSQL variant (provides `python3`, `psql` CLI) and PostgreSQL server

## Prerequisites

- Red Hat Advanced Cluster Management (ACM) installed with all OpenShift clusters registered as ManagedClusters
- Namespace `subscription-control` created on the ACM hub cluster
- Each managed cluster must have a Secret containing the authentication token in its corresponding namespace on the ACM hub (e.g., namespace `cluster-01` for cluster `cluster-01`). The default Secret name is `application-manager`, configurable via the `TOKENSECRET` environment variable.
- Optionally, each ManagedCluster can have a label indicating its subscription type (default label: `subscription-type`). The label name is configurable via the `SUBSTYPELABEL` environment variable. Example values: `ocp`, `oke`, `ove`, `ibmcp`, etc. Clusters without this label will be tagged as `no-label`.
- MySQL or PostgreSQL database accessible from the cluster. The database server can be external or, if preferred, deployed inside OpenShift using the manifests in `database-server/mysql-server/`
- Grafana Operator installed on the cluster via OperatorHub

> **Warning:** All passwords and tokens present in the Secret manifests of this project are **placeholder values for illustration purposes only**. You **must** replace them with strong, unique credentials before deploying to any environment.

## Architecture

### Shell variants (PostgreSQL / MySQL)

The CronJob runs two containers in parallel, coordinated through files on a shared `emptyDir` volume (`/tmp`):

```
┌─────────────────────────────────────────────────────┐
│ CronJob Pod                                         │
│                                                     │
│  ┌───────────────────┐  ┌────────────────────────┐  │
│  │  subscription-cpu │  │ subscription-db-insert │  │
│  │    (ose-cli)      │  │ (postgresql or mysql)  │  │
│  │                   │  │                        │  │
│  │  oc get nodes ──► │  │  waits for done.txt ─► │  │
│  │  writes data.csv  │  │  imports CSV → table   │  │
│  │  writes done.txt  │  │                        │  │
│  └─────────┬─────────┘  └────────────┬───────────┘  │
│            │      /tmp (emptyDir)    │              │
│            └─────────────────────────┘              │
└─────────────────────────────────────────────────────┘
```

### API variant (Python + MySQL)

A persistent API pod receives data via HTTP. The CronJob has a single container that collects data and POSTs to the API.

```
  ACM Hub cluster(s)                   Any cluster (API + MySQL + Grafana)
 ┌────────────────────────────────┐   ┌──────────────────────────────────────┐
 │ CronJob Pod (get-acm-info/)    │   │                                      │
 │                                │   │  subscription-control-api Pod        │
 │  oc get nodes ──► merge CSV ──►├──►│  (python3 + psql/mysql CLI)          │
 │  POST /api/subscriptions       │   │  HTTP :8080 ──► subprocess db cli ──►│──► PostgreSQL / MySQL
 │                                │   │                                      │
 └────────────────────────────────┘   └──────────────────────────────────────┘
```

> **Important:** The components in `api/` and `grafana/` (within `api-postgresql/` or `api-mysql/`) do **not** need to run on a cluster with ACM. They can be deployed on any OpenShift cluster with network access to the database. Only the CronJob in `get-acm-info/` must be deployed on each ACM hub cluster from which you want to collect data.

## Deploy

### 1. Common resources (always apply first — on every cluster that will run any component)

```bash
oc new-project subscription-control
oc apply -f common/
```

### 2. Choose ONE variant

**Shell + PostgreSQL:**

```bash
oc apply -f shell-postgresql/
```

**Shell + MySQL:**

```bash
oc apply -f shell-mysql/
```

**API + PostgreSQL:**

The API variants have independent components that can be deployed on different clusters:

```bash
# --- On the cluster that will host the API, PostgreSQL and Grafana ---

# Database credentials (edit before applying)
oc apply -f api-postgresql/secret-postgresql-credentials.yaml

# API pod (Deployment + Service + Route + ConfigMap + Token Secret)
# Edit the token before applying
vi api-postgresql/api/secret-subscription-control-api-token.yaml
oc apply -R -f api-postgresql/api/

# Grafana dashboards (requires Grafana Operator)
oc apply -R -f api-postgresql/grafana/

# --- On EACH ACM hub cluster from which you want to collect data ---

# Common resources (if not already applied)
oc apply -f common/

# CronJob data collector
oc apply -R -f api-postgresql/get-acm-info/
```

**API + MySQL:**

```bash
# --- On the cluster that will host the API, MySQL and Grafana ---

# Database credentials (edit before applying)
oc apply -f api-mysql/secret-mysql-credentials.yaml

# API pod (Deployment + Service + Route + ConfigMap + Token Secret)
# Edit the token before applying
vi api-mysql/api/secret-subscription-control-api-token.yaml
oc apply -R -f api-mysql/api/

# Grafana dashboards (requires Grafana Operator)
oc apply -R -f api-mysql/grafana/

# --- On EACH ACM hub cluster from which you want to collect data ---

# Common resources (if not already applied)
oc apply -f common/

# CronJob data collector
oc apply -R -f api-mysql/get-acm-info/
```

> **Note:** Use `-R` (recursive) flag because the API variant directories contain subdirectories. To deploy everything on a single cluster: `oc apply -f common/ && oc apply -R -f api-postgresql/` (or `api-mysql/`)

### 3. Database server

The database server can run **externally** (dedicated VM, RDS, managed service, etc.) or **inside OpenShift**. If you already have an external database, just ensure it is reachable from the cluster and skip to step 4.

To deploy a database inside OpenShift, choose one:

**MySQL:**

```bash
# Edit credentials before applying
vi database-server/mysql-server/secret-mysql-credentials.yaml
oc apply -f database-server/mysql-server/
```

```bash
mysql -h mysql.subscription-control.svc -P 3306 -u subscription -p -D subscription
```

**PostgreSQL:**

```bash
# Edit credentials before applying
vi database-server/postgresql-server/secret-postgresql-credentials.yaml
oc apply -f database-server/postgresql-server/
```

```bash
psql -h postgresql.subscription-control.svc -p 5432 -U subscription -d subscription
```

### API endpoints

The API variant requires a `Bearer` token in the `Authorization` header for all POST requests. The same token must be shared between the API Deployment and the CronJob via the `subscription-control-api-token` Secret.

| Endpoint | Method | Auth | Description |
|---|---|---|---|
| `/healthz` | GET | No | Liveness probe (always 200) |
| `/readyz` | GET | No | Readiness probe (checks MySQL connectivity) |
| `/api/subscriptions` | POST | Bearer token | Inserts records into MySQL and purges old data (retention policy) |

## Files

### `common/`

| File | Description |
|---|---|
| `serviceaccount-subscription-control-sa.yaml` | ServiceAccount, ClusterRole, and ClusterRoleBinding |
| `grafana-subscription-control-grafana.yaml` | Grafana instance (Grafana Operator CR) |

### `shell-postgresql/`

| File | Description |
|---|---|
| `cronjob-subscription-control-cj-postgresql.yaml` | CronJob manifest (runs daily at 23:00) |
| `configmap-subscription-cpu.yaml` | ConfigMap with the CPU collection script |
| `configmap-subscription-db-insert-postgresql.yaml` | ConfigMap with the PostgreSQL db-insert script |
| `secret-postgresql-credentials.yaml` | Secret template (`PGUSER`, `PGPASSWORD`) |
| `grafanadatasource-subscription-postgresql.yaml` | PostgreSQL datasource (Grafana Operator CR) |
| `grafanadashboard-subscription-control-dashboard-postgresql.yaml` | GrafanaDashboard CR |
| `resources/subscription-cpu.sh` | Source: CPU/node collection script |
| `resources/subscription-db-insert-postgresql.sh` | Source: PostgreSQL import script |
| `resources/grafana-dashboard-postgresql.json` | Source: Grafana dashboard JSON |

### `shell-mysql/`

| File | Description |
|---|---|
| `cronjob-subscription-control-cj-mysql.yaml` | CronJob manifest (runs daily at 23:00) |
| `configmap-subscription-cpu.yaml` | ConfigMap with the CPU collection script |
| `configmap-subscription-db-insert-mysql.yaml` | ConfigMap with the MySQL db-insert script |
| `secret-mysql-credentials.yaml` | Secret template (`MYSQL_USER`, `MYSQL_PASSWORD`) |
| `grafanadatasource-subscription-mysql.yaml` | MySQL datasource (Grafana Operator CR) |
| `grafanadashboard-subscription-control-dashboard-mysql.yaml` | GrafanaDashboard CR |
| `resources/subscription-cpu.sh` | Source: CPU/node collection script |
| `resources/subscription-db-insert-mysql.sh` | Source: MySQL import script |
| `resources/grafana-dashboard-mysql.json` | Source: Grafana dashboard JSON |

### `api-postgresql/`

Shared credential at the root level:

| File | Description |
|---|---|
| `secret-postgresql-credentials.yaml` | Secret template (`PGUSER`, `PGPASSWORD`) — used by API and CronJob |

#### `api-postgresql/api/` — API pod (does NOT require ACM)

| File | Description |
|---|---|
| `deployment-subscription-control-api.yaml` | Deployment `subscription-control-api` (image `rhel9/postgresql-15`, runs `python3`) |
| `service-subscription-control-api.yaml` | ClusterIP Service `subscription-control-api` (port 8080) |
| `route-subscription-control-api.yaml` | Route (TLS edge) for external access |
| `configmap-subscription-control-api.yaml` | ConfigMap `subscription-control-api` with the Python API script |
| `secret-subscription-control-api-token.yaml` | Secret `subscription-control-api-token` with Bearer token |
| `resources/subscription-control-api.py` | Source: Python HTTP API (uses `psql`) |

#### `api-postgresql/get-acm-info/` — CronJob data collector (REQUIRES ACM)

| File | Description |
|---|---|
| `cronjob-subscription-control-cj-api.yaml` | CronJob with single container (runs daily at 23:00) |
| `configmap-subscription-cpu-api.yaml` | ConfigMap with the collection script |
| `resources/subscription-cpu-api.sh` | Source: collection script (collects cluster data and sends to API) |

#### `api-postgresql/grafana/` — Grafana dashboards (does NOT require ACM)

| File | Description |
|---|---|
| `grafanadatasource-subscription-postgresql.yaml` | PostgreSQL datasource (Grafana Operator CR) |
| `grafanadashboard-subscription-control-dashboard-postgresql.yaml` | GrafanaDashboard CR |
| `resources/grafana-dashboard-postgresql.json` | Source: Grafana dashboard JSON |

### `api-mysql/`

Shared credential at the root level:

| File | Description |
|---|---|
| `secret-mysql-credentials.yaml` | Secret template (`MYSQL_USER`, `MYSQL_PASSWORD`) — used by API and CronJob |

#### `api-mysql/api/` — API pod (does NOT require ACM)

| File | Description |
|---|---|
| `deployment-subscription-control-api.yaml` | Deployment `subscription-control-api` (image `rhel9/mysql-80`, runs `python3`) |
| `service-subscription-control-api.yaml` | ClusterIP Service `subscription-control-api` (port 8080) |
| `route-subscription-control-api.yaml` | Route (TLS edge) for external access |
| `configmap-subscription-control-api.yaml` | ConfigMap `subscription-control-api` with the Python API script |
| `secret-subscription-control-api-token.yaml` | Secret `subscription-control-api-token` with Bearer token |
| `resources/subscription-control-api.py` | Source: Python HTTP API |

#### `api-mysql/get-acm-info/` — CronJob data collector (REQUIRES ACM)

| File | Description |
|---|---|
| `cronjob-subscription-control-cj-api.yaml` | CronJob with single container (runs daily at 23:00) |
| `configmap-subscription-cpu-api.yaml` | ConfigMap with the collection script |
| `resources/subscription-cpu-api.sh` | Source: collection script (collects cluster data and sends to API) |

#### `api-mysql/grafana/` — Grafana dashboards (does NOT require ACM)

| File | Description |
|---|---|
| `grafanadatasource-subscription-mysql.yaml` | MySQL datasource (Grafana Operator CR) |
| `grafanadashboard-subscription-control-dashboard-mysql.yaml` | GrafanaDashboard CR |
| `resources/grafana-dashboard-mysql.json` | Source: Grafana dashboard JSON |

### `database-server/mysql-server/`

| File | Description |
|---|---|
| `deployment-mysql.yaml` | MySQL Deployment (image `rhel9/mysql-80`) |
| `service-mysql.yaml` | ClusterIP Service (port 3306) |
| `secret-mysql-credentials.yaml` | Secret with MySQL root and user credentials |
| `persistentvolumeclaim-mysql-data.yaml` | PVC for MySQL data (10Gi) |

### `database-server/postgresql-server/`

| File | Description |
|---|---|
| `deployment-postgresql.yaml` | PostgreSQL Deployment (image `rhel9/postgresql-15`) |
| `service-postgresql.yaml` | ClusterIP Service (port 5432) |
| `secret-postgresql-credentials.yaml` | Secret with PostgreSQL admin and user credentials |
| `persistentvolumeclaim-postgresql-data.yaml` | PVC for PostgreSQL data (10Gi) |

## Execution Flow

### subscription-cpu.sh (shell variants)

1. Lists all managed clusters in ACM (excluding `local-cluster`)
2. For each cluster, in parallel (`PARALLEL=8`):
   - Retrieves metadata: `clusterID`, `apiserverurl`
   - Retrieves label defined by `SUBSTYPELABEL` (default: `subscription-type`)
   - Extracts the token from the Secret in the cluster's namespace. First tries `TOKENSECRET` (default: `application-manager`). If not found and `TOKENSECRETSUFFIX` is set, falls back to `<cluster-name><suffix>` (e.g., `cluster-01-admin-token`)
   - Queries worker nodes (excluding infra nodes) via remote API
   - Writes one line per node in the format: `acm,cluster,clusterid,subtype,node,cpu,providerid`
3. Merges partial CSVs into `/tmp/data.csv`
4. Creates `/tmp/done.txt` (success) or `/tmp/fail.txt` (failure)

### subscription-db-insert-postgresql.sh / subscription-db-insert-mysql.sh

1. Validates environment variables and database client availability (`psql` or `mysql`)
2. Waits for `/tmp/done.txt` or `/tmp/fail.txt` (polling every 5s)
3. Tests database connectivity
4. Creates the `subscription` table if it does not exist
5. Imports the CSV via a temporary table (`\copy` for PostgreSQL, `LOAD DATA LOCAL INFILE` for MySQL)
6. Purges records older than `RETENTION_DAYS`

### subscription-cpu-api.sh (API variant — runs on ACM hub)

1. Same cluster collection logic as `subscription-cpu.sh` (steps 1-3)
2. Converts the merged CSV to JSON using `awk`
3. POSTs the JSON array to `POST /api/subscriptions` via `curl` with `Authorization: Bearer` header

### subscription-control-api.py (API variant — runs on any cluster)

1. On startup, waits for the database to be ready (up to 30 attempts)
2. Creates the `subscription` table if it does not exist
3. Listens on port 8080 (threaded HTTP server)
4. `POST /api/subscriptions` — validates Bearer token, batch-inserts records (chunks of 500), then purges records older than `RETENTION_DAYS`
5. Uses `psql` CLI (PostgreSQL variant) or `mysql` CLI (MySQL variant) via `subprocess`

## Environment Variables

All variables below can be customized via `env` in the CronJob or Deployment manifest.

### subscription-cpu.sh (container `run-subscription-cpu`)

| Variable | Default | Description |
|---|---|---|
| `ACMNAME` | `acm` | ACM hub identifier used to tag collected data |
| `PARALLEL` | `8` | Number of clusters processed in parallel |
| `SUBSTYPELABEL` | `subscription-type` | ManagedCluster label name used to read the subscription type |
| `TOKENSECRET` | `application-manager` | Name of the Secret to try first in each cluster's namespace |
| `TOKENSECRETSUFFIX` | *(empty)* | Fallback: when set and `TOKENSECRET` is not found, tries `<cluster-name><suffix>` |

### subscription-db-insert-postgresql.sh (container `run-subscription-db-insert`)

| Variable | Default | Description |
|---|---|---|
| `PGHOST` | *(required)* | PostgreSQL host |
| `PGPORT` | `5432` | PostgreSQL port |
| `PGDATABASE` | *(required)* | Database name |
| `PGUSER` | *(required)* | Database user (via `secretKeyRef`) |
| `PGPASSWORD` | *(required)* | Database password (via `secretKeyRef`) |
| `WAIT_INTERVAL_SECONDS` | `5` | Polling interval while waiting for the CPU container (seconds) |
| `WAIT_MAX_SECONDS` | `0` | Maximum wait time (0 = infinite) |
| `RETENTION_DAYS` | `730` | Data retention period in days (~2 years) |

### subscription-db-insert-mysql.sh (container `run-subscription-db-insert`)

| Variable | Default | Description |
|---|---|---|
| `MYSQL_HOST` | *(required)* | MySQL host |
| `MYSQL_PORT` | `3306` | MySQL port |
| `MYSQL_DATABASE` | *(required)* | Database name |
| `MYSQL_USER` | *(required)* | Database user (via `secretKeyRef`) |
| `MYSQL_PASSWORD` | *(required)* | Database password (via `secretKeyRef`) |
| `MYSQL_SSL_CA` | *(empty)* | Path to CA certificate for TLS connections |
| `MYSQL_SSL_MODE` | `REQUIRED` | MySQL TLS verification mode |
| `WAIT_INTERVAL_SECONDS` | `5` | Polling interval while waiting for the CPU container (seconds) |
| `WAIT_MAX_SECONDS` | `0` | Maximum wait time (0 = infinite) |
| `RETENTION_DAYS` | `730` | Data retention period in days (~2 years) |

### subscription-cpu-api.sh (CronJob API variant — runs on ACM hub)

| Variable | Default | Description |
|---|---|---|
| `ACMNAME` | `acm` | ACM hub identifier |
| `PARALLEL` | `8` | Clusters processed in parallel |
| `SUBSTYPELABEL` | `subscription-type` | ManagedCluster label for subscription type |
| `TOKENSECRET` | `application-manager` | Secret name to try first for authentication token |
| `TOKENSECRETSUFFIX` | *(empty)* | Fallback: when set and `TOKENSECRET` not found, tries `<cluster><suffix>` |
| `API_URL` | *(required)* | Base URL of the subscription API |
| `API_TOKEN` | *(required)* | Bearer token for API authentication (via `secretKeyRef`) |

### subscription-control-api.py — PostgreSQL variant (Deployment — runs on any cluster)

| Variable | Default | Description |
|---|---|---|
| `PGHOST` | `localhost` | PostgreSQL host |
| `PGPORT` | `5432` | PostgreSQL port |
| `PGDATABASE` | `subscription` | Database name |
| `PGUSER` | *(required)* | Database user (via `secretKeyRef`) |
| `PGPASSWORD` | *(required)* | Database password (via `secretKeyRef`) |
| `RETENTION_DAYS` | `730` | Retention period in days; purge runs after each insert |
| `API_PORT` | `8080` | HTTP listen port |
| `API_TOKEN` | *(required)* | Bearer token that clients must present (via `secretKeyRef`) |

### subscription-control-api.py — MySQL variant (Deployment — runs on any cluster)

| Variable | Default | Description |
|---|---|---|
| `MYSQL_HOST` | `localhost` | MySQL host |
| `MYSQL_PORT` | `3306` | MySQL port |
| `MYSQL_DATABASE` | `subscription` | Database name |
| `MYSQL_USER` | *(required)* | Database user (via `secretKeyRef`) |
| `MYSQL_PASSWORD` | *(required)* | Database password (via `secretKeyRef`) |
| `RETENTION_DAYS` | `730` | Retention period in days; purge runs after each insert |
| `API_PORT` | `8080` | HTTP listen port |
| `API_TOKEN` | *(required)* | Bearer token that clients must present (via `secretKeyRef`) |

## Database Table

### PostgreSQL

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

### MySQL

```sql
CREATE TABLE IF NOT EXISTS subscription (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  acm        VARCHAR(255),
  cluster    VARCHAR(255),
  clusterid  VARCHAR(255),
  type       VARCHAR(255),
  node       VARCHAR(255),
  cpu        INTEGER,
  providerid VARCHAR(512),
  date       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
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
