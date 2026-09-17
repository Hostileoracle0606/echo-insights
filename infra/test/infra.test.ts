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

test("exposes the live-session broker through an authenticated and throttled route", () => {
  const template = synthesizeTemplate();

  template.resourceCountIs("AWS::Lambda::Function", 2);
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
