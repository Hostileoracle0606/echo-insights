# Source me: exports what eval/privacy/run.mjs needs from the running local
# Supabase stack. Prints nothing; never point it at a hosted project.
eval "$(supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY|SERVICE_ROLE_KEY|JWT_SECRET)=')"
export SUPABASE_URL="$API_URL" SUPABASE_ANON_KEY="$ANON_KEY" \
  SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY" SUPABASE_JWT_SECRET="$JWT_SECRET"
# Stacks configured with an asymmetric signing key reject HS256 at the auth
# server; hand the runner that key so admin and expired tokens are real.
auth_container=$(docker ps --format '{{.Names}}' | grep '^supabase_auth_' | head -1)
if [ -n "$auth_container" ]; then
  SUPABASE_JWT_SIGNING_JWK=$(docker exec "$auth_container" printenv GOTRUE_JWT_KEYS 2>/dev/null |
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const k=JSON.parse(s).find(k=>k.d&&k.alg==="ES256");if(k)process.stdout.write(JSON.stringify(k))}catch{}})')
  [ -n "$SUPABASE_JWT_SIGNING_JWK" ] && export SUPABASE_JWT_SIGNING_JWK
fi
