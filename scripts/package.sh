#!/usr/bin/env bash
# Empaqueta el código de las Lambdas. En realidad Terraform ya lo empaqueta con
# el provider archive_file; este script existe para validar el código localmente
# y como paso explícito si se prefiere empaquetar fuera de Terraform.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/terraform/build"
mkdir -p "$BUILD"

echo "==> Validando sintaxis de las Lambdas (python3 -m py_compile)"
# Nota: requiere un python3 funcional. Si falla por la licencia de Xcode en macOS,
# ejecuta primero: sudo xcodebuild -license accept
python3 -m py_compile "$ROOT/lambda/consumer/handler.py" "$ROOT/lambda/stub_backend/handler.py"

echo "==> Empaquetando consumer.zip"
( cd "$ROOT/lambda/consumer" && zip -q -r "$BUILD/consumer.zip" . -x "*.pyc" "__pycache__/*" )

echo "==> Empaquetando stub_backend.zip"
( cd "$ROOT/lambda/stub_backend" && zip -q -r "$BUILD/stub_backend.zip" . -x "*.pyc" "__pycache__/*" )

echo "==> Listo. Artefactos en $BUILD"
ls -lh "$BUILD"
