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

test("exposes authenticated live-session, graph-extraction and close-session routes", () => {
  const template = synthesizeTemplate();

  template.resourceCountIs("AWS::Lambda::Function", 5);
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
  template.hasResourceProperties("AWS::ApiGatewayV2::Route", {
    AuthorizationType: "CUSTOM",
    RouteKey: "POST /v1/notebooks/{notebookId}/close",
  });
  template.hasResourceProperties("AWS::ApiGatewayV2::Route", {
    AuthorizationType: "CUSTOM",
    RouteKey: "POST /v1/notebooks/{notebookId}/brief",
  });
  template.resourceCountIs("AWS::ApiGatewayV2::Authorizer", 1);
  template.resourceCountIs("AWS::ApiGatewayV2::Route", 5);
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

test("exposes a user-scoped live-session route on the same broker and authorizer", () => {
  const template = synthesizeTemplate();

  const routes = Object.values(template.findResources("AWS::ApiGatewayV2::Route")) as Array<{
    Properties: Record<string, unknown>;
  }>;
  const userRoute = routes.find(
    (route) => route.Properties.RouteKey === "POST /v1/live-sessions",
  );
  const notebookRoute = routes.find(
    (route) => route.Properties.RouteKey === "POST /v1/notebooks/{notebookId}/live-sessions",
  );

  expect(userRoute).toBeDefined();
  expect(userRoute!.Properties.AuthorizationType).toBe("CUSTOM");
  expect(userRoute!.Properties.AuthorizerId).toEqual(notebookRoute!.Properties.AuthorizerId);
  expect(userRoute!.Properties.Target).toEqual(notebookRoute!.Properties.Target);

  template.hasResourceProperties("AWS::Lambda::Function", {
    Description: "Issues short-lived, constrained Gemini Live credentials",
    Environment: {
      Variables: Match.objectLike({
        LIVE_SESSION_START_WINDOW_SECONDS: "600",
      }),
    },
  });
});

test("keeps the web origin and worker reservations optional", () => {
  const template = synthesizeTemplate();

  template.hasParameter("WebOrigin", { Default: "", AllowedPattern: "^$|https?://[^/]+" });
  template.hasParameter("WorkerReservedConcurrency", { Type: "Number", Default: 0, MinValue: 0 });
  template.hasCondition("HasWebOrigin", Match.anyValue());
  template.hasCondition("HasWorkerReservation", Match.anyValue());
  template.hasResourceProperties("AWS::ApiGatewayV2::Api", {
    CorsConfiguration: { "Fn::If": ["HasWebOrigin", Match.anyValue(), { Ref: "AWS::NoValue" }] },
  });
  const reservation = {
    "Fn::If": ["HasWorkerReservation", { Ref: "WorkerReservedConcurrency" }, { Ref: "AWS::NoValue" }],
  };
  template.hasResourceProperties("AWS::Lambda::Function", {
    Description: "Issues short-lived, constrained Gemini Live credentials",
    ReservedConcurrentExecutions: reservation,
  });
  template.hasResourceProperties("AWS::Lambda::Function", {
    Description: "Extracts validated graph patches without exposing Gemini credentials",
    ReservedConcurrentExecutions: reservation,
  });
  template.hasResourceProperties("AWS::Lambda::Function", {
    Description: "Writes the closing card for a conversation without exposing Gemini credentials",
    ReservedConcurrentExecutions: reservation,
  });
  template.hasResourceProperties("AWS::Lambda::Function", {
    Handler: "brief-index.handler",
    ReservedConcurrentExecutions: reservation,
  });
});

test("runs the session closer with its own card model and a 30 s timeout", () => {
  const template = synthesizeTemplate();

  template.hasResourceProperties("AWS::Lambda::Function", {
    Description: "Writes the closing card for a conversation without exposing Gemini credentials",
    Timeout: 30,
    Environment: {
      Variables: Match.objectLike({
        GEMINI_SECRET_ARN: Match.anyValue(),
        GEMINI_CARD_MODEL: "gemini-2.5-flash",
      }),
    },
  });

  const routes = Object.values(template.findResources("AWS::ApiGatewayV2::Route")) as Array<{
    Properties: Record<string, unknown>;
  }>;
  const closeRoute = routes.find(
    (route) => route.Properties.RouteKey === "POST /v1/notebooks/{notebookId}/close",
  );
  const extractionRoute = routes.find(
    (route) => route.Properties.RouteKey === "POST /v1/notebooks/{notebookId}/extractions",
  );
  expect(closeRoute!.Properties.AuthorizerId).toEqual(extractionRoute!.Properties.AuthorizerId);
  expect(closeRoute!.Properties.Target).not.toEqual(extractionRoute!.Properties.Target);
});

test("runs the session brief writer with its brief and TTS models and a 30 s timeout", () => {
  const template = synthesizeTemplate();

  template.hasResourceProperties("AWS::Lambda::Function", {
    Handler: "brief-index.handler",
    Timeout: 30,
    Environment: {
      Variables: Match.objectLike({
        GEMINI_SECRET_ARN: Match.anyValue(),
        GEMINI_BRIEF_MODEL: "gemini-2.5-flash",
        GEMINI_TTS_MODEL: "gemini-2.5-flash-preview-tts",
      }),
    },
  });

  const routes = Object.values(template.findResources("AWS::ApiGatewayV2::Route")) as Array<{
    Properties: Record<string, unknown>;
  }>;
  const find = (suffix: string) =>
    routes.find((route) => route.Properties.RouteKey === `POST /v1/notebooks/{notebookId}/${suffix}`);
  expect(find("brief")!.Properties.AuthorizerId).toEqual(find("close")!.Properties.AuthorizerId);
  expect(find("brief")!.Properties.Target).not.toEqual(find("close")!.Properties.Target);
});

test("keeps every log group for 14 days and points each function at its own", () => {
  const template = synthesizeTemplate();

  const groups = Object.entries(template.findResources("AWS::Logs::LogGroup"));
  const functions = Object.values(template.findResources("AWS::Lambda::Function")) as Array<{
    Properties: { LoggingConfig?: { LogGroup?: unknown } };
  }>;
  expect(functions).toHaveLength(5);
  expect(groups).toHaveLength(functions.length);
  for (const [, group] of groups) {
    expect((group as { Properties: { RetentionInDays: number } }).Properties.RetentionInDays).toBe(14);
  }
  const used = functions.map((fn) => JSON.stringify(fn.Properties.LoggingConfig?.LogGroup));
  expect(new Set(used).size).toBe(functions.length);
  for (const [id] of groups) expect(used.join()).toContain(id);
});

test("sends alarms to one topic and subscribes only when an alert email is given", () => {
  const without = synthesizeTemplate();
  without.resourceCountIs("AWS::SNS::Topic", 1);
  without.resourceCountIs("AWS::SNS::Subscription", 0);

  const app = new cdk.App({ context: { alertEmail: "ops@example.invalid" } });
  const withEmail = Template.fromStack(new InfraStack(app, "EmailStack"));
  withEmail.resourceCountIs("AWS::SNS::Subscription", 1);
  withEmail.hasResourceProperties("AWS::SNS::Subscription", {
    Protocol: "email",
    Endpoint: "ops@example.invalid",
  });
});

test("alarms on each function's errors, API 4xx and API 5xx, all to the alerts topic", () => {
  const template = synthesizeTemplate();

  const alarms = Object.values(template.findResources("AWS::CloudWatch::Alarm")) as Array<{
    Properties: Record<string, any>;
  }>;
  // five functions + 4xx + 5xx
  expect(alarms).toHaveLength(7);
  for (const alarm of alarms) {
    expect(alarm.Properties.AlarmActions).toHaveLength(1);
    expect(alarm.Properties.Period).toBe(300);
    expect(alarm.Properties.EvaluationPeriods).toBe(1);
    expect(alarm.Properties.TreatMissingData).toBe("notBreaching");
    // never fires on a single failed request
    expect(alarm.Properties.Threshold).toBeGreaterThan(1);
  }
  const lambdaAlarms = alarms.filter((a) => a.Properties.Namespace === "AWS/Lambda");
  expect(lambdaAlarms).toHaveLength(5);
  for (const a of lambdaAlarms) {
    expect(a.Properties.MetricName).toBe("Errors");
    expect(a.Properties.Threshold).toBe(3);
  }
  template.hasResourceProperties("AWS::CloudWatch::Alarm", {
    Namespace: "AWS/ApiGateway",
    MetricName: "4xx",
    Threshold: 30,
  });
  template.hasResourceProperties("AWS::CloudWatch::Alarm", {
    Namespace: "AWS/ApiGateway",
    MetricName: "5xx",
    Threshold: 3,
  });
});

test("keeps management events for a year in a private, TLS-only, retained bucket", () => {
  const template = synthesizeTemplate();

  template.hasResourceProperties("AWS::CloudTrail::Trail", {
    IsLogging: true,
    IsMultiRegionTrail: true,
    EnableLogFileValidation: true,
  });
  template.hasResource("AWS::S3::Bucket", {
    DeletionPolicy: "Retain",
    Properties: {
      PublicAccessBlockConfiguration: Match.objectLike({ BlockPublicAcls: true, RestrictPublicBuckets: true }),
      LifecycleConfiguration: { Rules: [Match.objectLike({ ExpirationInDays: 365, Status: "Enabled" })] },
    },
  });
  template.hasResourceProperties("AWS::S3::BucketPolicy", {
    PolicyDocument: {
      Statement: Match.arrayWith([
        Match.objectLike({ Effect: "Deny", Condition: { Bool: { "aws:SecureTransport": "false" } } }),
      ]),
    },
  });
});
