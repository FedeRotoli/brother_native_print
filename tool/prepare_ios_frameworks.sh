#!/usr/bin/env bash
#
# Normalizes the bundled BRLMPrinterKit.xcframework before publishing.
#
# Two things are enforced:
#   1. every .swiftinterface file is LF-only, so the Swift compiler can parse
#      the module interface regardless of how the archive was unzipped;
#   2. no code signature is shipped: neither the .xcframework container nor the
#      per-slice frameworks. Xcode re-signs the framework with the app identity
#      when embedding it, and the ad-hoc seals baked into the vendor SDK only
#      become invalid there: Xcode strips Headers/ and Modules/ while embedding,
#      which breaks a seal that covers them.
#
# The script is idempotent: running it twice is a no-op.

set -euo pipefail

XCFW="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ios/brother_native_print/Frameworks/BRLMPrinterKit.xcframework"

if [ ! -d "$XCFW" ]; then
  echo "error: xcframework not found at $XCFW" >&2
  exit 1
fi

cr_count() {
  tr -cd '\r' < "$1" | wc -c | tr -d ' '
}

echo "==> Normalizing .swiftinterface line endings"
while IFS= read -r -d '' iface; do
  if [ "$(cr_count "$iface")" != "0" ]; then
    perl -pi -e 's/\r\n?/\n/g' "$iface"
    echo "    LF-normalized ${iface#"$XCFW"/}"
  fi
done < <(find "$XCFW" -name '*.swiftinterface' -print0)

echo "==> Removing container signature"
rm -rf "$XCFW/_CodeSignature"

echo "==> Removing per-slice signatures"
for fw in "$XCFW"/*/*.framework; do
  [ -d "$fw" ] || continue
  rm -rf "$fw/_CodeSignature"

  bin="$fw/$(basename "$fw" .framework)"
  if [ -f "$fw/Info.plist" ]; then
    exe="$(plutil -extract CFBundleExecutable raw -o - "$fw/Info.plist" 2>/dev/null || true)"
    if [ -n "$exe" ]; then
      bin="$fw/$exe"
    fi
  fi

  # `codesign --verify` on a binary inside a bundle also validates the bundle's
  # resources, so it fails once _CodeSignature is gone; `-d` only reports the
  # signature embedded in the Mach-O header.
  if [ -f "$bin" ] && codesign -dv "$bin" >/dev/null 2>&1; then
    codesign --remove-signature "$bin"
    echo "    unsigned ${fw#"$XCFW"/} ($(basename "$bin"))"
  fi
done

echo "==> Verifying"

failed=0

while IFS= read -r -d '' iface; do
  cr="$(cr_count "$iface")"
  if [ "$cr" != "0" ]; then
    echo "error: ${iface#"$XCFW"/} still contains $cr CR bytes" >&2
    failed=1
  fi
done < <(find "$XCFW" -name '*.swiftinterface' -print0)

while IFS= read -r -d '' sigdir; do
  echo "error: leftover signature directory ${sigdir#"$XCFW"/}" >&2
  failed=1
done < <(find "$XCFW" -name '_CodeSignature' -print0)

for fw in "$XCFW"/*/*.framework; do
  [ -d "$fw" ] || continue
  status=0
  out="$(codesign --verify --strict "$fw" 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    echo "error: ${fw#"$XCFW"/} is still signed" >&2
    failed=1
  elif ! printf '%s' "$out" | grep -q 'code object is not signed at all'; then
    echo "error: ${fw#"$XCFW"/} reported an unexpected verification error: $out" >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "error: verification failed" >&2
  exit 1
fi

echo "==> OK: LF-only module interfaces, no shipped code signature"
