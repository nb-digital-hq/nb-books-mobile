#!/usr/bin/env bash
# Vuelve a exportar el motor de lectura desde NB Books a native/vendor/ y
# reescribe su MANIFIESTO de huellas. Es la única forma de cambiar el motor en
# este repositorio (ADR-008): a mano no se edita.
#
# Uso: tool/exportar_motor.sh <ruta al repositorio de NB Books>
set -euo pipefail
origen="${1:?ruta al repositorio de NB Books}/src-tauri/lector"
destino="$(dirname "$0")/../native/vendor/nb-books-lector"
rm -rf "$destino"
mkdir -p "$destino"
cp -r "$origen/Cargo.toml" "$origen/src" "$origen/tests" "$destino/"
(cd "$destino" && find . -type f ! -name MANIFIESTO | LC_ALL=C sort | sed 's#^\./##' | xargs sha256sum > MANIFIESTO)
echo "Motor exportado desde $origen."
