#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC}  $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC}  $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_section() {
    echo -e "\n${BLUE}══════════════════════════════════════${NC}"
    echo -e "${BLUE} $*${NC}"
    echo -e "${BLUE}══════════════════════════════════════${NC}"
}
