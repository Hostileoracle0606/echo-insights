#!/bin/sh
# Fetch the served memory reranker into supabase/functions/_shared/reranker/ at the
# revision pinned in its manifest, and refuse it unless the sha256 matches.
# Needs a Hugging Face login with read access to the private repo.
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DIR="$ROOT/supabase/functions/_shared/reranker"
eval "$(python3 -I -c "
import json; m=json.load(open('$DIR/manifest.json')); r=m['registry']
print(f\"REPO={r['repo']} REV={r['revision']} FILE={r['path']} SHA={m['sha256']}\")")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
uv run --no-project --with huggingface_hub==2.5.0 python -c "
from huggingface_hub import hf_hub_download
hf_hub_download('$REPO', '$FILE', revision='$REV', local_dir='$TMP')"
GOT="$(shasum -a 256 "$TMP/$FILE" | cut -d' ' -f1)"
[ "$GOT" = "$SHA" ] || { echo "fetch_model: sha256 mismatch ($GOT != $SHA)" >&2; exit 1; }
mv "$TMP/$FILE" "$DIR/model.int8.onnx"
echo "fetch_model: $REPO@$REV verified ($SHA)"
