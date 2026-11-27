#!/bin/bash
# Downloads the exact browser libraries the app loads from its CDNs, so the browser
# tests can serve them locally: supabase-js 2.45.4, SheetJS 0.18.5, jsPDF 2.5.1, jsPDF-AutoTable 3.8.2.
set -e
cd "$(dirname "$0")"
mkdir -p vendor && tmp=$(mktemp -d)
( cd "$tmp" && npm pack -q @supabase/supabase-js@2.45.4 xlsx@0.18.5 jspdf@2.5.1 jspdf-autotable@3.8.2 >/dev/null )
for t in "$tmp"/*.tgz; do mkdir -p "$tmp/x" && tar -xzf "$t" -C "$tmp/x" && 
  find "$tmp/x" \( -path "*umd/supabase.js" -o -name "xlsx.full.min.js" -o -name "jspdf.umd.min.js" -o -name "jspdf.plugin.autotable.min.js" \) -exec cp {} vendor/ \; ; rm -rf "$tmp/x"; done
rm -rf "$tmp"; ls vendor
