# SOAR Stack

A self-hosted Security Orchestration, Automation and Response platform built on open-source tools.

## Stack

| Tool | Role |
|------|------|
| **MISP** | Threat intelligence platform — IOC sharing and enrichment |
| **TheHive** | Security incident response and case management |
| **Cortex** | Observable analysis and enrichment engine |
| **Shuffle** | SOAR automation workflows and playbooks |
| **ELK** | Log aggregation, indexing and search (Elasticsearch) |

---

## Prerequisites

- Ubuntu 22.04 / 24.04 (or Debian 12)
- 16 GB RAM minimum (32 GB recommended)
- 100 GB disk space minimum
- A static IP or hostname for the VM
- Internet access to pull Docker images

---

## Full Installation Guide (New Machine)

### Step 1 — Update the system

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget git ca-certificates gnupg lsb-release openssl
```

### Step 2 — Install Docker Engine

```bash
# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add the Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine + Compose plugin
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
                    docker-buildx-plugin docker-compose-plugin
```

### Step 3 — Add your user to the docker group

```bash
sudo usermod -aG docker $USER
newgrp docker
```

Verify Docker works without sudo:
```bash
docker run hello-world
docker compose version
```

### Step 4 — Tune kernel settings (required for Elasticsearch)

```bash
# Increase virtual memory for Elasticsearch
sudo sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf

# Increase file descriptor limits
echo "* soft nofile 65536" | sudo tee -a /etc/security/limits.conf
echo "* hard nofile 65536" | sudo tee -a /etc/security/limits.conf
```

### Step 5 — Clone the repository

```bash
git clone git@github.com:yassine-abid/Soar.git
cd Soar
```

Or via HTTPS:
```bash
git clone https://github.com/yassine-abid/Soar.git
cd Soar
```

### Step 6 — Configure environment variables

```bash
cp .env.example .env
nano .env
```

Fill in these required values:

```env
# Your VM's IP address
VM_IP=192.168.x.x
VM_HOSTNAME=your-hostname

# Your user IDs (run: id -u  and  id -g)
SOAR_UID=1000
SOAR_GID=1000

# MISP
MISP_BASEURL=https://192.168.x.x
MISP_ADMIN_EMAIL=admin@soar.local
MISP_ADMIN_PASS=YourStrongPassword

# Cortex Elasticsearch
CORTEX_ES_PASSWORD=YourStrongPassword

# TheHive Elasticsearch
THEHIVE_ES_PASSWORD=YourStrongPassword

# MISP database
MYSQL_PASSWORD=YourStrongPassword
MYSQL_ROOT_PASSWORD=YourStrongPassword
```

Also update `Shuffle/.env` with your Shuffle OpenSearch password:
```bash
nano Shuffle/.env
# Set: SHUFFLE_OPENSEARCH_PASSWORD=YourStrongPassword
#      OPENSEARCH_INITIAL_ADMIN_PASSWORD=YourStrongPassword (same value)
```

### Step 7 — Generate certificates

Certificates are generated automatically on first run. To generate manually:

```bash
bash generate-certs.sh <YOUR_VM_IP>
# Example:
bash generate-certs.sh 192.168.20.240
```

This creates:
- A 10-year internal CA at `pki/ca/ca.crt`
- Signed certs for MISP, TheHive, Cortex, Shuffle
- Deploys all certs to the correct tool folders
- Syncs the CA to all service trust stores

> **Import `pki/ca/ca.crt` into your browser** to trust all HTTPS services without warnings.

### Step 8 — Create required data directories

```bash
mkdir -p docker/prod1-cortex/elasticsearch/data
mkdir -p docker/prod1-cortex/elasticsearch/logs
mkdir -p docker/prod1-cortex/cortex/cortex-jobs
mkdir -p docker/prod1-cortex/cortex/logs
mkdir -p docker/prod1-cortex/cortex/neurons
mkdir -p docker/prod1-thehive/elasticsearch/data
mkdir -p docker/prod1-thehive/elasticsearch/logs
mkdir -p docker/prod1-thehive/cassandra/data
mkdir -p docker/prod1-thehive/cassandra/logs
mkdir -p docker/prod1-thehive/thehive/data/files
mkdir -p docker/prod1-thehive/thehive/data/tls
mkdir -p docker/prod1-thehive/thehive/logs
mkdir -p Shuffle/shuffle-database
mkdir -p Shuffle/shuffle-apps
mkdir -p Shuffle/shuffle-files

# Set correct ownership for Elasticsearch
sudo chown -R 1000:0 docker/prod1-cortex/elasticsearch/
sudo chown -R 1000:0 docker/prod1-thehive/elasticsearch/
```

### Step 9 — Start the stack

```bash
bash init.sh
```

`init.sh` will:
1. Validate your `.env`
2. Generate certificates if missing
3. Pull and build Docker images
4. Start all services in the correct order
5. Wait for TheHive to become healthy
6. Print all service URLs

> First run takes **10–20 minutes** to pull images and build MISP.

---

## Service URLs

| Service | URL | Default Port |
|---------|-----|-------------|
| MISP | `https://<VM_IP>` | 443 |
| TheHive | `https://<VM_IP>:5443` | 5443 |
| Cortex | `https://<VM_IP>:8443` | 8443 |
| Shuffle | `https://<VM_IP>:3443` | 3443 |
| Shuffle (HTTP) | `http://<VM_IP>:3001` | 3001 |
| Cortex API | `http://<VM_IP>:9001` | 9001 |

---

## Certificate Architecture

All services share a single internal CA (`SOAR-Internal-CA`).

```
pki/ca/ca.crt  ←  SOAR-Internal-CA (10 years)
      │
      ├── pki/misp/cert.pem          (CN=misp)
      ├── pki/thehive/server.crt     (CN=thehive)
      ├── pki/cortex/server.crt      (CN=cortex)
      └── pki/shuffle/fullchain.pem  (CN=shuffle)
```

The CA cert is mounted into every container so services trust each other over HTTPS.

To regenerate all certs (e.g. new VM or new IP):
```bash
# Certs with >30 days remaining are skipped automatically
bash generate-certs.sh <NEW_VM_IP>
```

---

## Project Structure

```
Soar/
├── docker-compose.yml        # Root compose — starts everything
├── init.sh                   # One-command startup
├── generate-certs.sh         # Certificate generation (idempotent)
├── .env.example              # Environment variable template
├── pki/                      # PKI — public certs committed, keys git-ignored
│   ├── ca/                   # Internal CA
│   ├── cortex/
│   ├── thehive/
│   ├── misp/
│   └── shuffle/
├── docker/
│   ├── prod1-cortex/         # Cortex config + nginx + compose
│   └── prod1-thehive/        # TheHive config + nginx + compose
├── misp-docker/              # MISP config + compose
└── Shuffle/                  # Shuffle config + compose
```

---

## Day-to-Day Operations

```bash
# Check status of all services
docker compose ps

# Follow logs for a specific service
docker compose logs -f thehive
docker compose logs -f misp-core
docker compose logs -f cortex

# Restart a single service
docker compose restart thehive

# Stop the whole stack (data is preserved in volumes)
docker compose down

# Start again
docker compose up -d
```

---

## Deploying on a New Machine

```bash
git clone git@github.com:yassine-abid/Soar.git
cd Soar
cp .env.example .env
nano .env                        # set new machine's IP and passwords
bash generate-certs.sh <NEW_IP>  # generates fresh certs for new IP
bash init.sh
```

---

## Troubleshooting

**Elasticsearch won't start**
```bash
# Check vm.max_map_count
sysctl vm.max_map_count
# Must be 262144 — if not:
sudo sysctl -w vm.max_map_count=262144
```

**Permissions error on data directories**
```bash
sudo chown -R 1000:0 docker/prod1-cortex/elasticsearch/
sudo chown -R 1000:0 docker/prod1-thehive/elasticsearch/
```

**TheHive or Cortex not healthy after 5 minutes**
```bash
docker compose logs thehive --tail=50
docker compose logs cortex --tail=50
```

**MISP taking too long to start**
> Normal — MISP builds its PHP image on first run. Can take 10–15 minutes.
```bash
docker compose logs misp-core -f
```

**Certificate not trusted in browser**
> Import `pki/ca/ca.crt` into your browser's trusted certificate store.
> - Chrome/Edge: Settings → Privacy → Manage certificates → Authorities → Import
> - Firefox: Settings → Privacy → View Certificates → Authorities → Import

---

## Security Notes

- Private keys are **never committed** (git-ignored via `.gitignore`)
- `.env` is **never committed** — only `.env.example` is tracked
- All inter-service communication uses TLS with the shared internal CA
- Change all default passwords in `.env` before deploying
- The `soar-shared` Docker network isolates SOAR traffic from the host
