#!/bin/sh
# Upload the served reranker model to a project's private `ml-models` bucket,
# keyed by its sha256, where retrieve-memory loads and verifies it.
#   ml/reranker/deploy/upload_model.sh <project-ref>
# Refuses production unless ALLOW_PRODUCTION=1. Run fetch_model.sh first. Never prints keys.
set -eu
REF="${1:?usage: upload_model.sh <project-ref>}"
[ "$REF" != "bjoevzvsdlhlcjywpyfx" ] || [ "${ALLOW_PRODUCTION:-}" = "1" ] || { echo "upload_model: refusing production without ALLOW_PRODUCTION=1" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DIR="$ROOT/supabase/functions/_shared/reranker"
SHA="$(python3 -I -c "import json; print(json.load(open('$DIR/manifest.json'))['sha256'])")"
GOT="$(shasum -a 256 "$DIR/model.int8.onnx" | cut -d' ' -f1)"
[ "$GOT" = "$SHA" ] || { echo "upload_model: local model is not the pinned one; run fetch_model.sh" >&2; exit 1; }
KEY="$(supabase projects api-keys --project-ref "$REF" -o env 2>/dev/null | sed -n 's/^SUPABASE_SERVICE_ROLE_KEY="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')"
[ -n "$KEY" ] || { echo "upload_model: no service role key for $REF" >&2; exit 1; }
URL="https://$REF.supabase.co/storage/v1"
curl -s -o /dev/null -X POST "$URL/bucket" -H "authorization: Bearer $KEY" -H "apikey: $KEY" -H 'content-type: application/json' \
  -d '{"id":"ml-models","name":"ml-models","public":false}' || true
PUBLIC="$(curl -s "$URL/bucket/ml-models" -H "authorization: Bearer $KEY" -H "apikey: $KEY" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("public"))')"
[ "$PUBLIC" = "False" ] || { echo "upload_model: bucket ml-models must be private (public=$PUBLIC)" >&2; exit 1; }
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/object/ml-models/reranker/$SHA.onnx" -H "authorization: Bearer $KEY" -H "apikey: $KEY" \
  -H 'content-type: application/octet-stream' -H 'x-upsert: true' --data-binary "@$DIR/model.int8.onnx")"
[ "$CODE" = "200" ] || { echo "upload_model: upload failed (HTTP $CODE)" >&2; exit 1; }
echo "upload_model: $REF ml-models/reranker/$SHA.onnx"
