#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# generate-certs.sh — Generate SOAR-Internal-CA and per-service certificates
#
# Usage:
#   bash generate-certs.sh <VM_IP>
#   bash generate-certs.sh 192.168.20.240
#
# Idempotent: skips any cert that already exists and is still valid (>30 days).
# Run with a new IP to regenerate SANs for a new machine.
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[CERT]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[SKIP]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Arguments ────────────────────────────────────────────────────────────────
VM_IP="${1:-}"
if [[ -z "$VM_IP" ]]; then
    # Try loading from .env
    if [[ -f ".env" ]]; then
        VM_IP="$(grep -E '^VM_IP=' .env | cut -d= -f2 | tr -d ' "')"
    fi
fi
if [[ -z "$VM_IP" || "$VM_IP" == "192.168.x.x" ]]; then
    error "VM_IP is required."
    echo "  Usage: bash generate-certs.sh <YOUR_VM_IP>"
    echo "  Or set VM_IP in your .env file."
    exit 1
fi
info "Generating certificates for VM_IP=${VM_IP}"

# ── Config ───────────────────────────────────────────────────────────────────
CA_DAYS=3650          # 10 years
CERT_DAYS=825         # ~2.25 years (browser max)
CA_SUBJ="/CN=SOAR-Internal-CA/O=SOAR-Lab"
CA_DIR="pki/ca"
CA_CRT="${CA_DIR}/ca.crt"
CA_KEY="${CA_DIR}/ca.key"

# ── Helper: check if cert is valid for more than 30 days ─────────────────────
cert_valid() {
    local crt="$1"
    [[ -f "$crt" ]] && openssl x509 -checkend $((30*86400)) -noout -in "$crt" 2>/dev/null
}

# ── Helper: sign a CSR with the CA ───────────────────────────────────────────
sign_cert() {
    local key="$1" crt="$2" subj="$3" sans="$4"
    local extfile
    extfile="$(mktemp /tmp/soar-ext-XXXXXX.cnf)"
    printf "subjectAltName=%s\nextendedKeyUsage=serverAuth\n" "$sans" > "$extfile"

    openssl genrsa -out "$key" 2048 2>/dev/null

    openssl req -new -key "$key" -subj "$subj" \
        | openssl x509 -req \
            -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
            -days "$CERT_DAYS" -sha256 \
            -extfile "$extfile" \
            -out "$crt" 2>/dev/null

    rm -f "$extfile"
}

# ── Helper: copy CA to destination, create parent dirs ───────────────────────
deploy_ca() {
    local dest="$1"
    mkdir -p "$(dirname "$dest")"
    cp "$CA_CRT" "$dest"
}

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       SOAR Certificate Generation            ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Step 1: Create PKI directory structure ───────────────────────────────────
info "Creating PKI directory structure..."
mkdir -p pki/ca pki/misp pki/thehive pki/cortex pki/shuffle
success "pki/ structure ready"

# ── Step 2: Generate CA (skip if valid) ──────────────────────────────────────
if cert_valid "$CA_CRT"; then
    warn "CA already valid — skipping CA generation (${CA_CRT})"
else
    info "Generating SOAR-Internal-CA..."
    openssl genrsa -out "$CA_KEY" 4096 2>/dev/null
    openssl req -new -x509 \
        -key "$CA_KEY" \
        -subj "$CA_SUBJ" \
        -days "$CA_DAYS" \
        -sha256 \
        -extensions v3_ca \
        -out "$CA_CRT" 2>/dev/null
    chmod 600 "$CA_KEY"
    success "CA generated: ${CA_CRT} (valid ${CA_DAYS} days)"
fi

# ── Step 3: Per-service certificates ─────────────────────────────────────────

# MISP
if cert_valid "pki/misp/cert.pem"; then
    warn "MISP cert already valid — skipping"
else
    info "Generating MISP certificate..."
    sign_cert \
        "pki/misp/key.pem" \
        "pki/misp/cert.pem" \
        "/CN=misp/O=SOAR-Lab" \
        "DNS:misp,DNS:localhost,DNS:misp.localhost,IP:${VM_IP}"
    success "MISP cert generated"
fi

# TheHive
if cert_valid "pki/thehive/server.crt"; then
    warn "TheHive cert already valid — skipping"
else
    info "Generating TheHive certificate..."
    sign_cert \
        "pki/thehive/server.key" \
        "pki/thehive/server.crt" \
        "/CN=thehive/O=SOAR-Lab" \
        "DNS:thehive,DNS:localhost,DNS:intelbroelk,IP:${VM_IP}"
    success "TheHive cert generated"
fi

# Cortex
if cert_valid "pki/cortex/server.crt"; then
    warn "Cortex cert already valid — skipping"
else
    info "Generating Cortex certificate..."
    sign_cert \
        "pki/cortex/server.key" \
        "pki/cortex/server.crt" \
        "/CN=cortex/O=SOAR-Lab" \
        "DNS:cortex,DNS:localhost,DNS:intelbroelk,IP:${VM_IP}"
    success "Cortex cert generated"
fi

# Shuffle
if cert_valid "pki/shuffle/fullchain.pem"; then
    warn "Shuffle cert already valid — skipping"
else
    info "Generating Shuffle certificate..."
    sign_cert \
        "pki/shuffle/privkey.pem" \
        "pki/shuffle/fullchain.pem" \
        "/CN=shuffle/O=SOAR-Lab" \
        "DNS:shuffle,DNS:localhost,DNS:shuffle-frontend,IP:${VM_IP}"
    success "Shuffle cert generated"
fi

# ── Step 4: Deploy certs to tool folders ─────────────────────────────────────
info "Deploying certificates to tool folders..."

# MISP
mkdir -p misp-docker/misp-docker/ssl
if [[ -f "misp-docker/misp-docker/ssl/cert.pem" ]]; then
    cp misp-docker/misp-docker/ssl/cert.pem misp-docker/misp-docker/ssl/cert.pem.bak 2>/dev/null || true
fi
cp pki/misp/cert.pem  misp-docker/misp-docker/ssl/cert.pem
cp pki/misp/key.pem   misp-docker/misp-docker/ssl/key.pem
cp "$CA_CRT"          misp-docker/misp-docker/ssl/ca.pem
success "MISP certs deployed"

# TheHive nginx
mkdir -p docker/prod1-thehive/nginx/certs
if [[ -f "docker/prod1-thehive/nginx/certs/server.crt" ]]; then
    cp docker/prod1-thehive/nginx/certs/server.crt docker/prod1-thehive/nginx/certs/server.crt.bak 2>/dev/null || true
fi
cp pki/thehive/server.crt docker/prod1-thehive/nginx/certs/server.crt
cp pki/thehive/server.key docker/prod1-thehive/nginx/certs/server.key
cp "$CA_CRT"              docker/prod1-thehive/nginx/certs/ca.pem
success "TheHive nginx certs deployed"

# Cortex nginx
mkdir -p docker/prod1-cortex/nginx/certs
cp pki/cortex/server.crt docker/prod1-cortex/nginx/certs/server.crt
cp pki/cortex/server.key docker/prod1-cortex/nginx/certs/server.key
cp "$CA_CRT"             docker/prod1-cortex/nginx/certs/ca.pem
success "Cortex nginx certs deployed"

# Shuffle frontend
mkdir -p Shuffle/frontend/certs
cp pki/shuffle/fullchain.pem Shuffle/frontend/certs/fullchain.pem
cp pki/shuffle/privkey.pem   Shuffle/frontend/certs/privkey.pem
success "Shuffle frontend certs deployed"

# ── Step 5: Sync CA to all ca.pem locations ───────────────────────────────────
info "Syncing CA to all tool CA trust stores..."
deploy_ca docker/prod1-cortex/certificates/ca.pem
deploy_ca docker/prod1-thehive/certificates/ca.pem
deploy_ca docker/prod1-thehive/thehive/config/tls/soar-ca.pem
deploy_ca docker/prod1-thehive/thehive/data/tls/soar-ca.pem
success "CA synced to all trust store locations"

# ── Step 6: Summary ──────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       Certificate Generation Complete                ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  CA cert:    pki/ca/ca.crt  (valid 10 years)        ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  MISP:       pki/misp/cert.pem                       ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  TheHive:    pki/thehive/server.crt                  ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Cortex:     pki/cortex/server.crt                   ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Shuffle:    pki/shuffle/fullchain.pem               ${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  Import pki/ca/ca.crt into your browser to          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  trust all services without certificate warnings.   ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# Quick verification
info "Verifying all generated certs against CA..."
ALL_OK=true
for crt in pki/misp/cert.pem pki/thehive/server.crt pki/cortex/server.crt pki/shuffle/fullchain.pem; do
    if openssl verify -CAfile "$CA_CRT" "$crt" >/dev/null 2>&1; then
        success "$crt — OK"
    else
        error "$crt — FAILED verification"
        ALL_OK=false
    fi
done

if [[ "$ALL_OK" == "true" ]]; then
    echo ""
    success "All certificates verified against SOAR-Internal-CA"
else
    echo ""
    error "Some certificates failed verification — check output above"
    exit 1
fi
echo ""
