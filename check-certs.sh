#!/bin/bash
# check-certs.sh
# Scans your SOAR stack and reports certificate status per tool
# Usage: bash check-certs.sh [VM_IP]

HOST=${1:-localhost}
TIMEOUT=3

# ANSI colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

echo ""
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}   SOAR Certificate Recon Report${NC}"
echo -e "${BLUE}======================================${NC}"
echo "  Target host : $HOST"
echo "  Scanned at  : $(date)"
echo ""

# ── Helper: check a cert on a live TCP port ──────────────────────────────────
check_live_cert() {
  local LABEL=$1
  local HOST=$2
  local PORT=$3

  echo -e "${BLUE}[$LABEL]${NC} → $HOST:$PORT"

  # Is the port even open?
  if ! timeout $TIMEOUT bash -c "echo > /dev/tcp/$HOST/$PORT" 2>/dev/null; then
    echo -e "  ${RED}✗ Port $PORT is not reachable (service down or not HTTPS)${NC}"
    echo ""
    return
  fi

  # Grab the cert via openssl
  CERT_INFO=$(echo | timeout $TIMEOUT openssl s_client \
    -connect "$HOST:$PORT" \
    -servername "$HOST" 2>/dev/null | openssl x509 -noout \
    -subject -issuer -dates -fingerprint -ext subjectAltName 2>/dev/null)

  if [ -z "$CERT_INFO" ]; then
    echo -e "  ${YELLOW}⚠ Port is open but no TLS certificate found (plain HTTP?)${NC}"
    echo ""
    return
  fi

  # Parse fields
  SUBJECT=$(echo "$CERT_INFO" | grep "subject=" | sed 's/subject=//')
  ISSUER=$(echo  "$CERT_INFO" | grep "issuer="  | sed 's/issuer=//')
  NOT_BEFORE=$(echo "$CERT_INFO" | grep "notBefore=" | sed 's/notBefore=//')
  NOT_AFTER=$(echo  "$CERT_INFO" | grep "notAfter="  | sed 's/notAfter=//')
  FINGERPRINT=$(echo "$CERT_INFO" | grep "SHA1 Fingerprint=" | sed 's/SHA1 Fingerprint=//')
  SAN=$(echo "$CERT_INFO" | grep -A1 "Subject Alternative Name" | tail -1)

  # Check expiry
  EXPIRY_EPOCH=$(date -d "$NOT_AFTER" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$NOT_AFTER" +%s 2>/dev/null)
  NOW_EPOCH=$(date +%s)
  DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

  if [ "$DAYS_LEFT" -lt 0 ]; then
    EXPIRY_STATUS="${RED}✗ EXPIRED ${DAYS_LEFT#-} days ago${NC}"
  elif [ "$DAYS_LEFT" -lt 30 ]; then
    EXPIRY_STATUS="${YELLOW}⚠ Expires in $DAYS_LEFT days (renew soon)${NC}"
  else
    EXPIRY_STATUS="${GREEN}✓ Valid — $DAYS_LEFT days remaining${NC}"
  fi

  # Self-signed detection
  if [ "$SUBJECT" = "$ISSUER" ]; then
    SIGN_TYPE="${YELLOW}⚠ Self-signed${NC}"
  else
    SIGN_TYPE="${GREEN}✓ CA-signed${NC}"
  fi

  echo -e "  Subject     : $SUBJECT"
  echo -e "  Issuer      : $ISSUER"
  echo -e "  Valid from  : $NOT_BEFORE"
  echo -e "  Expires     : $NOT_AFTER"
  echo -e "  Expiry      : $(echo -e $EXPIRY_STATUS)"
  echo -e "  Type        : $(echo -e $SIGN_TYPE)"
  [ -n "$SAN" ] && echo -e "  SAN         : $SAN"
  [ -n "$FINGERPRINT" ] && echo -e "  Fingerprint : $FINGERPRINT"
  echo ""
}

# ── Helper: check a cert FILE directly (no service needed) ───────────────────
check_cert_file() {
  local LABEL=$1
  local CERT_PATH=$2

  if [ ! -f "$CERT_PATH" ]; then
    return  # silently skip if no file found
  fi

  echo -e "${BLUE}[$LABEL — file]${NC} → $CERT_PATH"

  CERT_INFO=$(openssl x509 -noout -subject -issuer -dates -fingerprint \
    -ext subjectAltName -in "$CERT_PATH" 2>/dev/null)

  if [ -z "$CERT_INFO" ]; then
    echo -e "  ${RED}✗ Could not parse certificate file${NC}"
    echo ""
    return
  fi

  SUBJECT=$(echo "$CERT_INFO" | grep "subject=" | sed 's/subject=//')
  ISSUER=$(echo  "$CERT_INFO" | grep "issuer="  | sed 's/issuer=//')
  NOT_AFTER=$(echo  "$CERT_INFO" | grep "notAfter=" | sed 's/notAfter=//')
  FINGERPRINT=$(echo "$CERT_INFO" | grep "SHA1 Fingerprint=" | sed 's/SHA1 Fingerprint=//')

  EXPIRY_EPOCH=$(date -d "$NOT_AFTER" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$NOT_AFTER" +%s 2>/dev/null)
  NOW_EPOCH=$(date +%s)
  DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

  if [ "$DAYS_LEFT" -lt 0 ]; then
    EXPIRY_STATUS="${RED}✗ EXPIRED${NC}"
  elif [ "$DAYS_LEFT" -lt 30 ]; then
    EXPIRY_STATUS="${YELLOW}⚠ Expires in $DAYS_LEFT days${NC}"
  else
    EXPIRY_STATUS="${GREEN}✓ $DAYS_LEFT days remaining${NC}"
  fi

  [ "$SUBJECT" = "$ISSUER" ] && SIGN_TYPE="${YELLOW}⚠ Self-signed${NC}" || SIGN_TYPE="${GREEN}✓ CA-signed${NC}"

  echo -e "  Subject     : $SUBJECT"
  echo -e "  Expires     : $NOT_AFTER  $(echo -e $EXPIRY_STATUS)"
  echo -e "  Type        : $(echo -e $SIGN_TYPE)"
  [ -n "$FINGERPRINT" ] && echo -e "  Fingerprint : $FINGERPRINT"
  echo ""
}

# ── 1. Scan live services ─────────────────────────────────────────────────────
echo -e "${BLUE}━━━ LIVE SERVICE SCAN ━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

check_live_cert "MISP"     $HOST 443
check_live_cert "TheHive"  $HOST 9000
check_live_cert "Cortex"   $HOST 9001
check_live_cert "Shuffle"  $HOST 3001
check_live_cert "Shuffle"  $HOST 3000  # alternate port

# ── 2. Scan cert FILES on disk ────────────────────────────────────────────────
echo -e "${BLUE}━━━ CERT FILE SCAN (disk) ━━━━━━━━━━━━━━━${NC}"
echo ""

# Find all .crt and .pem files under current directory (skip node_modules etc.)
while IFS= read -r CERT_FILE; do
  # Derive a label from the path
  LABEL=$(echo "$CERT_FILE" | sed 's|^\./||' | cut -d'/' -f1-3)
  check_cert_file "$LABEL" "$CERT_FILE"
done < <(find . \
  -not \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/vendor/*' \) \
  \( -name "*.crt" -o -name "*.pem" -o -name "*.cer" \) 2>/dev/null | sort)

# ── 3. Also check inside running containers ───────────────────────────────────
echo -e "${BLUE}━━━ CONTAINER CERT SCAN (docker exec) ━━━${NC}"
echo ""

for CONTAINER in $(docker ps --format '{{.Names}}' 2>/dev/null); do
  # Common cert locations per tool
  for CERT_PATH in \
    /etc/ssl/certs/ssl-cert-snakeoil.pem \
    /etc/nginx/ssl/cert.pem \
    /etc/apache2/ssl/cert.pem \
    /opt/thehive/conf/thehive.crt \
    /opt/cortex/conf/cortex.crt \
    /var/www/MISP/app/Config/ssl/misp.crt \
    /etc/misp/certs/misp.crt
  do
    CERT_DATA=$(docker exec "$CONTAINER" \
      openssl x509 -noout -subject -issuer -dates \
      -in "$CERT_PATH" 2>/dev/null)

    if [ -n "$CERT_DATA" ]; then
      echo -e "${BLUE}[container: $CONTAINER]${NC} → $CERT_PATH"
      NOT_AFTER=$(echo "$CERT_DATA" | grep "notAfter=" | sed 's/notAfter=//')
      SUBJECT=$(echo "$CERT_DATA" | grep "subject=" | sed 's/subject=//')
      ISSUER=$(echo  "$CERT_DATA" | grep "issuer="  | sed 's/issuer=//')

      EXPIRY_EPOCH=$(date -d "$NOT_AFTER" +%s 2>/dev/null)
      DAYS_LEFT=$(( (EXPIRY_EPOCH - $(date +%s)) / 86400 ))
      [ "$DAYS_LEFT" -lt 0 ] && STATUS="${RED}✗ EXPIRED${NC}" \
        || STATUS="${GREEN}✓ $DAYS_LEFT days left${NC}"

      echo -e "  Subject  : $SUBJECT"
      echo -e "  Expires  : $NOT_AFTER  $(echo -e $STATUS)"
      [ "$SUBJECT" = "$ISSUER" ] \
        && echo -e "  Type     : ${YELLOW}⚠ Self-signed${NC}" \
        || echo -e "  Type     : ${GREEN}✓ CA-signed${NC}"
      echo ""
    fi
  done
done

echo -e "${BLUE}======================================${NC}"
echo -e "  Done. Fix any ${RED}RED${NC} or ${YELLOW}YELLOW${NC} items above."
echo -e "${BLUE}======================================${NC}"
echo ""
