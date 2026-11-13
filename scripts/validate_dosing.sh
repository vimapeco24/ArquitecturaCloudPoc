#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Validación REPRODUCIBLE del dosificado 10–15 TPS / 20.000 pagos en ventana de
# 1 h (ASR-1) y de la idempotencia (ASR-2), SIN desplegar en AWS.
#
# Corre el simulador determinista (sim/simulate_dosing.py) para los tres
# escenarios de la PoC y las pruebas unitarias. Útil para regenerar las cifras
# que se citan en el documento (sección 17) de forma idéntica cada vez.
#
# Uso:  ./scripts/validate_dosing.sh
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PY="${PYTHON:-python3}"

echo "#############################################################################"
echo "#  PoC Bre-B — Validación de dosificado (banda 10–15 TPS, 20.000 pagos/1 h)  #"
echo "#############################################################################"
echo
echo ">>> Escenario NORMAL · 20.000 pagos · objetivo 15 TPS (borde superior)"
"$PY" sim/simulate_dosing.py --total 20000 --concurrency 3 --target-tps 15
echo
echo ">>> Escenario CONSERVADOR · 20.000 pagos · objetivo 10 TPS (borde inferior)"
"$PY" sim/simulate_dosing.py --total 20000 --concurrency 3 --target-tps 10
echo
echo ">>> Escenario FALLO+DUPLICADOS · 20.000 pagos · 1 de cada 50 duplicado (ASR-2)"
"$PY" sim/simulate_dosing.py --total 20000 --concurrency 3 --target-tps 15 --duplicate-every 50
echo
echo ">>> Pruebas unitarias del simulador"
"$PY" sim/test_dosing.py
echo
echo "Listo. Estas cifras son deterministas (semilla fija) y reproducibles."
echo "Para la ejecución EN VIVO sobre AWS usa ./scripts/run_sfn.sh (requiere credenciales)."
