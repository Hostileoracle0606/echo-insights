import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";

import { createCloseSessionHandler } from "./core.mjs";

function requiredEnvironment(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`Missing required environment value: ${name}`);
  return value;
}

const secrets = new SecretsManagerClient({});
const secretArn = requiredEnvironment("GEMINI_SECRET_ARN");

const handle = createCloseSessionHandler({
  supabaseUrl: requiredEnvironment("SUPABASE_URL"),
  publishableKey: requiredEnvironment("SUPABASE_PUBLISHABLE_KEY"),
  model: requiredEnvironment("GEMINI_CARD_MODEL"),
  fetchImpl: fetch,
  getPermanentCredential: async () => {
    const result = await secrets.send(new GetSecretValueCommand({ SecretId: secretArn }));
    if (!result.SecretString) throw new Error("Gemini credential is unavailable");
    return result.SecretString;
  },
});

export const handler = (event) => handle(event);
