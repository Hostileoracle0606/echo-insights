import * as cdk from "aws-cdk-lib/core";
import { Match, Template } from "aws-cdk-lib/assertions";

import { InfraStack } from "../lib/infra-stack";

function synthesizeTemplate(): Template {
  const app = new cdk.App();
  const stack = new InfraStack(app, "TestStack");
  return Template.fromStack(stack);
}

test("keeps the Gemini credential in a retained secret without template plaintext", () => {
  const template = synthesizeTemplate();

  template.hasResource("AWS::SecretsManager::Secret", {
    DeletionPolicy: "Retain",
    UpdateReplacePolicy: "Retain",
    Properties: {
      Name: "echo-insights/gemini-api-key",
    },
  });

  const secrets = template.findResources("AWS::SecretsManager::Secret");
  expect(Object.values(secrets)).toHaveLength(1);
  expect(Object.values(secrets)[0]).not.toHaveProperty("Properties.SecretString");
});

test("exposes authenticated live-session and graph-extraction routes", () => {
  const template = synthesizeTemplate();

  template.resourceCountIs("AWS::Lambda::Function", 3);
  template.hasResourceProperties("AWS::ApiGatewayV2::Authorizer", {
    AuthorizerType: "REQUEST",
    EnableSimpleResponses: true,
    IdentitySource: ["$request.header.Authorization"],
    AuthorizerResultTtlInSeconds: 0,
  });
  template.hasResourceProperties("AWS::ApiGatewayV2::Route", {
    AuthorizationType: "CUSTOM",
    RouteKey: "POST /v1/notebooks/{notebookId}/live-sessions",
  });
  template.hasResourceProperties("AWS::ApiGatewayV2::Route", {
    AuthorizationType: "CUSTOM",
    RouteKey: "POST /v1/notebooks/{notebookId}/extractions",
  });
  template.hasResourceProperties("AWS::ApiGatewayV2::Stage", {
    StageName: "$default",
    AutoDeploy: true,
    DefaultRouteSettings: {
      ThrottlingBurstLimit: 20,
      ThrottlingRateLimit: 10,
    },
  });
  template.hasResourceProperties("AWS::IAM::Policy", {
    PolicyDocument: {
      Statement: Match.arrayWith([
        Match.objectLike({
          Action: Match.arrayWith(["secretsmanager:GetSecretValue"]),
          Effect: "Allow",
          Resource: Match.objectLike({ Ref: Match.anyValue() }),
        }),
      ]),
    },
  });
});

test("retains a server-side extraction retry cache", () => {
  const template = synthesizeTemplate();

  template.hasResource("AWS::DynamoDB::Table", {
    DeletionPolicy: "Retain",
    UpdateReplacePolicy: "Retain",
    Properties: {
      BillingMode: "PAY_PER_REQUEST",
      KeySchema: [{ AttributeName: "id", KeyType: "HASH" }],
      TimeToLiveSpecification: {
        AttributeName: "expiresAt",
        Enabled: true,
      },
    },
  });
});
