#!/usr/bin/env bash
# Regenerate the Fiserv-styled SUPERVISOR-SUMMARY.pdf from
# SUPERVISOR-SUMMARY.md using pandoc + weasyprint.
#
# Requires: pandoc, weasyprint, and the Fiserv CSS at
#   /Users/ben/Repos/fiserv/fiserv.css
#
# Usage:  ./build-pdf.sh  [input.md]  [output.pdf]
#
# NOTE: do NOT pass --metadata title=... to pandoc — that adds a
# pandoc-generated <h1 class="title"> on top of the markdown's own H1,
# producing a duplicate title at the top of the PDF.

set -euo pipefail

INPUT="${1:-SUPERVISOR-SUMMARY.md}"
OUTPUT="${2:-${INPUT%.md}.pdf}"
CSS="${FISERV_CSS:-/Users/ben/Repos/fiserv/fiserv.css}"

if [ ! -f "$INPUT" ];   then echo "missing input:   $INPUT"   >&2; exit 1; fi
if [ ! -f "$CSS" ];     then echo "missing CSS:     $CSS"     >&2; exit 1; fi
command -v pandoc      >/dev/null || { echo "install pandoc";      exit 1; }
command -v weasyprint  >/dev/null || { echo "install weasyprint";  exit 1; }

HTML=$(mktemp /tmp/sv-XXXXXX.html)
trap 'rm -f "$HTML"' EXIT

# Bare conversion: just include the CSS, no --metadata title to avoid
# duplicating the H1 that already exists in the markdown.
pandoc "$INPUT" \
  --standalone \
  --embed-resources \
  --resource-path="$(dirname "$INPUT")" \
  --css="$CSS" \
  --highlight-style=tango \
  -o "$HTML"

weasyprint --quiet "$HTML" "$OUTPUT"

echo "wrote $OUTPUT ($(stat -f '%z bytes' "$OUTPUT" 2>/dev/null || stat -c '%s bytes' "$OUTPUT"))"
