#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# init.sh — One-command SOAR stack startup
# Usage: bash init.sh
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       SOAR Stack — Initialising              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Step 1: Check .env ───────────────────────────────────────────────────────
info "Checking .env file..."
if [[ ! -f ".env" ]]; then
    error ".env file not found."
    echo ""
    echo "  To get started:"
    echo "    cp .env.example .env"
    echo "    nano .env          # set your VM_IP, passwords, etc."
    echo "    bash init.sh"
    echo ""
    exit 1
fi

# Source .env to check required vars
set -a; source .env; set +a

MISSING=()
for var in CORTEX_ES_PASSWORD THEHIVE_ES_PASSWORD MISP_ADMIN_PASS MISP_BASEURL; do
    if [[ -z "${!var:-}" || "${!var}" == "changeme"* ]]; then
        MISSING+=("$var")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    error "The following required variables are unset or still set to 'changeme' in .env:"
    for v in "${MISSING[@]}"; do echo "    - $v"; done
    echo ""
    echo "  Edit .env and re-run: bash init.sh"
    exit 1
fi
success ".env loaded and validated"

# ── Step 2: Generate certificates if needed ──────────────────────────────────
info "Checking PKI..."
if [[ ! -f "pki/ca/ca.crt" ]]; then
    warn "No CA found at pki/ca/ca.crt — running generate-certs.sh"
    if [[ -z "${VM_IP:-}" ]]; then
        error "VM_IP is not set in .env — needed for cert SANs."
        echo "  Set VM_IP=<your-vm-ip> in .env and re-run."
        exit 1
    fi
    bash generate-certs.sh "$VM_IP"
else
    success "PKI already present (pki/ca/ca.crt exists)"
fi

# ── Step 3: Ensure Shuffle data dirs exist ───────────────────────────────────
info "Creating Shuffle data directories..."
mkdir -p "${DB_LOCATION:-./Shuffle/shuffle-database}"
mkdir -p "${SHUFFLE_APP_HOTLOAD_LOCATION:-./Shuffle/shuffle-apps}"
mkdir -p "${SHUFFLE_FILE_LOCATION:-./Shuffle/shuffle-files}"
success "Shuffle data directories ready"

# ── Step 4: Create soar-shared network if not present ───────────────────────
info "Ensuring soar-shared Docker network exists..."
if ! docker network inspect soar-shared >/dev/null 2>&1; then
    docker network create soar-shared
    success "Created soar-shared network"
else
    success "soar-shared network already exists"
fi

# ── Step 5: Pull / build images ──────────────────────────────────────────────
info "Pulling Docker images (this may take a few minutes on first run)..."
docker compose pull --ignore-pull-failures 2>&1 | grep -E "Pull|Pulling|pulled|error" || true

info "Building MISP images..."
docker compose build misp-core misp-modules 2>&1 | tail -5

# ── Step 6: Bring the stack up ───────────────────────────────────────────────
info "Starting SOAR stack..."
docker compose up -d

# ── Step 7: Wait for core services ───────────────────────────────────────────
echo ""
info "Waiting for TheHive to become healthy (this can take 2-4 minutes)..."
TIMEOUT=300
ELAPSED=0
until docker inspect --format='{{.State.Health.Status}}' thehive 2>/dev/null | grep -q "healthy"; do
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        warn "TheHive did not become healthy within ${TIMEOUT}s — check: docker compose logs thehive"
        break
    fi
    printf "."
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done
echo ""

# ── Step 8: Print service URLs ───────────────────────────────────────────────
IP="${VM_IP:-<your-vm-ip>}"
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           SOAR Stack is UP                           ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  MISP       https://${IP}              port 443  ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  TheHive    https://${IP}:5443          port 5443 ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Cortex     https://${IP}:8443          port 8443 ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Shuffle    https://${IP}:3443          port 3443 ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Shuffle    http://${IP}:3001           port 3001 ${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  Import pki/ca/ca.crt into your browser to trust  ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  all HTTPS services without warnings.             ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
info "Check status:  docker compose ps"
info "Follow logs:   docker compose logs -f <service>"
info "Stop stack:    docker compose down"
echo ""
