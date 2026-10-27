#!/usr/bin/env bash
# Elimina toda la infraestructura de la PoC.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/terraform"

terraform destroy -auto-approve
echo "==> Infraestructura de la PoC eliminada."
