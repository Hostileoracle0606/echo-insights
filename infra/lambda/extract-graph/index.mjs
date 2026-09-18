import { DynamoDBClient, GetItemCommand, PutItemCommand } from "@aws-sdk/client-dynamodb";
import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";

import { createExtractGraphHandler } from "./core.mjs";

function requiredEnvironment(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`Missing required environment value: ${name}`);
  return value;
}

const secrets = new SecretsManagerClient({});
const cache = new DynamoDBClient({});
const secretArn = requiredEnvironment("GEMINI_SECRET_ARN");
const cacheTableName = requiredEnvironment("EXTRACTION_CACHE_TABLE_NAME");

const handle = createExtractGraphHandler({
  supabaseUrl: requiredEnvironment("SUPABASE_URL"),
  publishableKey: requiredEnvironment("SUPABASE_PUBLISHABLE_KEY"),
  model: requiredEnvironment("GEMINI_EXTRACTION_MODEL"),
  fetchImpl: fetch,
  getPermanentCredential: async () => {
    const result = await secrets.send(new GetSecretValueCommand({ SecretId: secretArn }));
    if (!result.SecretString) throw new Error("Gemini credential is unavailable");
    return result.SecretString;
  },
  getCachedPatch: async (id) => {
    const result = await cache.send(
      new GetItemCommand({
        TableName: cacheTableName,
        Key: { id: { S: id } },
        ConsistentRead: true,
      }),
    );
    const value = result.Item?.patch?.S;
    return value ? JSON.parse(value) : null;
  },
  putCachedPatch: async (id, patch) => {
    const expiresAt = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60;
    await cache.send(
      new PutItemCommand({
        TableName: cacheTableName,
        Item: {
          id: { S: id },
          patch: { S: JSON.stringify(patch) },
          expiresAt: { N: String(expiresAt) },
        },
      }),
    );
  },
});

export const handler = (event) => handle(event);
