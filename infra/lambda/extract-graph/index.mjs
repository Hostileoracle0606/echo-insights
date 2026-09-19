import { DynamoDBClient, GetItemCommand, UpdateItemCommand } from "@aws-sdk/client-dynamodb";
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

async function readExtraction(id) {
  const result = await cache.send(
    new GetItemCommand({
      TableName: cacheTableName,
      Key: { id: { S: id } },
      ConsistentRead: true,
    }),
  );
  const item = result.Item;
  if (!item) return null;
  return {
    status: item.status?.S,
    inputHash: item.inputHash?.S,
    ownerToken: item.ownerToken?.S,
    leaseExpiresAt: Number(item.leaseExpiresAt?.N ?? 0),
    patch: item.patch?.S ? JSON.parse(item.patch.S) : null,
  };
}

function isConditionalFailure(error) {
  return error?.name === "ConditionalCheckFailedException";
}

function observedExtraction(record, inputHash, now) {
  if (!record || !record.status || !record.inputHash) {
    throw new Error("Extraction claim disappeared or is malformed");
  }
  if (record.inputHash !== inputHash) return { status: "mismatch" };
  if (record.status === "completed") {
    return { status: "completed", patch: record.patch };
  }
  if (record.status === "pending") {
    return {
      status: "pending",
      retryAfterMs: Math.max(250, Math.min(2_000, record.leaseExpiresAt - now)),
    };
  }
  throw new Error("Unsupported extraction claim status");
}

async function acquireExtraction({
  id,
  inputHash,
  ownerToken,
  now,
  leaseExpiresAt,
  expiresAt,
}) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      await cache.send(
        new UpdateItemCommand({
          TableName: cacheTableName,
          Key: { id: { S: id } },
          UpdateExpression:
            "SET #status = :pending, #inputHash = :inputHash, #ownerToken = :ownerToken, " +
            "#leaseExpiresAt = :leaseExpiresAt, #expiresAt = :expiresAt REMOVE #patch",
          ConditionExpression:
            "attribute_not_exists(#status) OR " +
            "(#status = :pending AND #inputHash = :inputHash AND #leaseExpiresAt <= :now)",
          ExpressionAttributeNames: {
            "#status": "status",
            "#inputHash": "inputHash",
            "#ownerToken": "ownerToken",
            "#leaseExpiresAt": "leaseExpiresAt",
            "#expiresAt": "expiresAt",
            "#patch": "patch",
          },
          ExpressionAttributeValues: {
            ":pending": { S: "pending" },
            ":inputHash": { S: inputHash },
            ":ownerToken": { S: ownerToken },
            ":now": { N: String(now) },
            ":leaseExpiresAt": { N: String(leaseExpiresAt) },
            ":expiresAt": { N: String(expiresAt) },
          },
        }),
      );
      return { status: "acquired" };
    } catch (error) {
      if (!isConditionalFailure(error)) throw error;
      const observed = await readExtraction(id);
      if (!observed && attempt === 0) continue;
      return observedExtraction(observed, inputHash, now);
    }
  }
  throw new Error("Unable to acquire extraction claim");
}

async function completeExtraction({ id, inputHash, ownerToken, patch, expiresAt }) {
  try {
    await cache.send(
      new UpdateItemCommand({
        TableName: cacheTableName,
        Key: { id: { S: id } },
        UpdateExpression:
          "SET #status = :completed, #patch = :patch, #expiresAt = :expiresAt " +
          "REMOVE #ownerToken, #leaseExpiresAt",
        ConditionExpression:
          "#status = :pending AND #inputHash = :inputHash AND #ownerToken = :ownerToken",
        ExpressionAttributeNames: {
          "#status": "status",
          "#inputHash": "inputHash",
          "#ownerToken": "ownerToken",
          "#leaseExpiresAt": "leaseExpiresAt",
          "#expiresAt": "expiresAt",
          "#patch": "patch",
        },
        ExpressionAttributeValues: {
          ":pending": { S: "pending" },
          ":completed": { S: "completed" },
          ":inputHash": { S: inputHash },
          ":ownerToken": { S: ownerToken },
          ":patch": { S: JSON.stringify(patch) },
          ":expiresAt": { N: String(expiresAt) },
        },
      }),
    );
    return { status: "completed", patch };
  } catch (error) {
    if (!isConditionalFailure(error)) throw error;
    return observedExtraction(await readExtraction(id), inputHash, Date.now());
  }
}

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
  acquireExtraction,
  completeExtraction,
});

export const handler = (event) => handle(event);
