#!/usr/bin/env bash
# Despliega la PoC completa.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/terraform"

if [ ! -f terraform.tfvars ]; then
  echo "No existe terraform.tfvars; copiando desde el ejemplo."
  cp terraform.tfvars.example terraform.tfvars
fi

terraform init -input=false
terraform apply -auto-approve

echo
echo "==> Despliegue completo. Salidas:"
terraform output
