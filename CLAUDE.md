# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a production SOAR (Security Orchestration, Automation and Response) platform deployment. It contains:
- **Shuffle** — the core SOAR platform (frontend + backend + execution engine)
- **TheHive** — case management and incident response (Docker deployments in `docker/`)
- **Cortex** — analysis/enrichment engine (Docker deployments in `docker/`)
- **MISP** — malware information sharing (`misp-docker/`)
- **PKI** — internal certificate infrastructure (`pki/`)

## Shuffle Platform

### Backend (Go 1.24)
Location: `Shuffle/backend/go-app/`

```bash
# Run locally
go run main.go walkoff.go docker.go

# Build binary
CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o shufflebackend .

# Run tests
go test ./...

# Build Docker image
cd Shuffle/backend && bash build.sh
```

Required env vars: `SHUFFLE_OPENSEARCH_URL`, `SHUFFLE_ELASTIC`, `SHUFFLE_OPENSEARCH_USERNAME`, `SHUFFLE_OPENSEARCH_PASSWORD`

### Frontend (React 18)
Location: `Shuffle/frontend/`

```bash
npm install --legacy-peer-deps
npm run start      # Dev server at http://localhost:3000
npm run build      # Production build
npm test
```

### Orborus (Workflow Distributor, Go)
Location: `Shuffle/functions/onprem/orborus/`

```bash
go run orborus.go
```
Requires Docker socket access to spawn app containers.

### Full Stack
```bash
cd Shuffle && docker-compose up -d
```
Services: frontend (80/443), backend (5001), orborus, opensearch (9200/9600).

## Architecture

```
Shuffle/
├── frontend/          React UI — workflow editor (Cytoscape), app builder, dashboards
├── backend/
│   ├── go-app/        REST API — endpoints in main.go, workflow logic in walkoff.go, Docker ops in docker.go
│   ├── app_sdk/       Python SDK for building Shuffle apps
│   └── app_gen/       Code generation for apps
└── functions/
    ├── onprem/orborus/ Distributes workflow execution across workers
    ├── onprem/worker/  Executes individual workflow nodes inside containers
    └── kubernetes/     Helm charts for K8s deployment
```

**Data flow**: Frontend → Backend REST API → OpenSearch (state/data) → Orborus → Worker containers (apps)

**Storage**: OpenSearch 3.2.0 is the primary datastore (replaces Elasticsearch). All workflow state, app definitions, and execution logs live here.

**App execution**: Each workflow node runs as a short-lived Docker container. Orborus schedules them; Worker manages lifecycle.

## Docker / TheHive / Cortex

`docker/` contains multi-environment compose stacks:
- `prod1-thehive/`, `prod2-thehive/` — production TheHive instances
- `prod1-cortex/`, `prod2-cortex/` — production Cortex instances
- `testing/` — isolated test environment

Each directory has its own `.env` and `docker-compose.yml`. Bring up with `docker-compose up -d` inside the relevant directory.

## PKI

`pki/` holds the internal CA and per-service certificates for mTLS between Shuffle, TheHive, and Cortex. Run `check-certs.sh` from the repo root to validate cert expiry.

## CI/CD

GitHub Actions workflows live in `Shuffle/.github/workflows/`:
- `dockerbuild.yaml` — builds and pushes Docker images
- `quick-testing.yml` — runs quick validation tests
