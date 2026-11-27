import * as cdk from "aws-cdk-lib/core";
import { Match, Template } from "aws-cdk-lib/assertions";

import { MemoryRerankerStack } from "../lib/memory-reranker-stack";

function synthesizeTemplate(): Template {
  // No bundling in tests: the package build is covered by memory-reranker.test.mjs.
  const app = new cdk.App({ context: { "aws:cdk:bundling-stacks": [] } });
  return Template.fromStack(new MemoryRerankerStack(app, "RerankerTestStack"));
}

test("serves the reranker from one arm64 function with a full vCPU", () => {
  const template = synthesizeTemplate();
  template.resourceCountIs("AWS::Lambda::Function", 1);
  template.hasResourceProperties("AWS::Lambda::Function", {
    Runtime: "nodejs22.x",
    Architectures: ["arm64"],
    MemorySize: 1769,
    Handler: "index.handler",
    Environment: { Variables: { RERANKER_TOKEN_SECRET_ARN: Match.anyValue() } },
  });
});

test("its URL is gated by a generated bearer token the function alone can read", () => {
  const template = synthesizeTemplate();
  template.hasResourceProperties("AWS::Lambda::Url", { AuthType: "NONE" });
  template.hasResourceProperties("AWS::SecretsManager::Secret", {
    GenerateSecretString: { PasswordLength: 48, ExcludePunctuation: true },
  });
  const secrets = template.findResources("AWS::SecretsManager::Secret");
  expect(Object.values(secrets)[0]).not.toHaveProperty("Properties.SecretString");
  template.hasResourceProperties("AWS::IAM::Policy", {
    PolicyDocument: {
      Statement: Match.arrayWith([
        Match.objectLike({ Action: ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"] }),
      ]),
    },
  });
});

test("keeps its logs two weeks (LM-44)", () => {
  synthesizeTemplate().hasResourceProperties("AWS::Logs::LogGroup", { RetentionInDays: 14 });
});
