import * as cdk from "aws-cdk-lib/core";
import * as apigatewayv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as authorizers from "aws-cdk-lib/aws-apigatewayv2-authorizers";
import * as integrations from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import { Construct } from "constructs";
import * as path from "node:path";

const lambdaDirectory = path.join(__dirname, "..", "lambda");

export class InfraStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const geminiApiKey = new secretsmanager.Secret(this, "GeminiApiKey", {
      secretName: "echo-insights/gemini-api-key",
      description: "Permanent Gemini credential used only by server-side workloads",
    });
    geminiApiKey.applyRemovalPolicy(cdk.RemovalPolicy.RETAIN);

    const supabaseUrl = new cdk.CfnParameter(this, "SupabaseUrl", {
      type: "String",
      description: "Public URL of the Supabase project",
      allowedPattern: "https://[A-Za-z0-9.-]+\\.supabase\\.co/?",
    });
    const supabasePublishableKey = new cdk.CfnParameter(this, "SupabasePublishableKey", {
      type: "String",
      description: "Public Supabase key used with each user's access token",
      noEcho: true,
    });
    const webOrigin = new cdk.CfnParameter(this, "WebOrigin", {
      type: "String",
      description: "Exact Cloudflare-hosted web origin allowed to call the runtime",
      allowedPattern: "https?://[^/]+",
    });

    const sharedEnvironment = {
      SUPABASE_URL: supabaseUrl.valueAsString,
      SUPABASE_PUBLISHABLE_KEY: supabasePublishableKey.valueAsString,
    };
    const commonFunctionProperties = {
      runtime: lambda.Runtime.NODEJS_22_X,
      architecture: lambda.Architecture.ARM_64,
      memorySize: 256,
      timeout: cdk.Duration.seconds(10),
      loggingFormat: lambda.LoggingFormat.JSON,
    };

    const supabaseAuthorizer = new lambda.Function(this, "SupabaseAuthorizerFunction", {
      ...commonFunctionProperties,
      description: "Validates Supabase user access tokens for Echo Insights",
      handler: "index.handler",
      code: lambda.Code.fromAsset(path.join(lambdaDirectory, "supabase-authorizer")),
      environment: sharedEnvironment,
    });

    const liveSessionBroker = new lambda.Function(this, "LiveSessionBrokerFunction", {
      ...commonFunctionProperties,
      description: "Issues short-lived, constrained Gemini Live credentials",
      handler: "index.handler",
      code: lambda.Code.fromAsset(path.join(lambdaDirectory, "live-session")),
      environment: {
        ...sharedEnvironment,
        GEMINI_SECRET_ARN: geminiApiKey.secretArn,
        GEMINI_LIVE_MODEL: "gemini-3.1-flash-live-preview",
      },
      reservedConcurrentExecutions: 20,
    });
    geminiApiKey.grantRead(liveSessionBroker);

    const api = new apigatewayv2.HttpApi(this, "NotebookRuntimeApi", {
      apiName: "echo-insights-notebook-runtime",
      description: "Authenticated runtime routes for Echo Insights",
      createDefaultStage: false,
      corsPreflight: {
        allowOrigins: [webOrigin.valueAsString],
        allowHeaders: ["authorization", "content-type"],
        allowMethods: [apigatewayv2.CorsHttpMethod.OPTIONS, apigatewayv2.CorsHttpMethod.POST],
        maxAge: cdk.Duration.hours(1),
      },
    });

    const authorizer = new authorizers.HttpLambdaAuthorizer(
      "SupabaseAuthorizer",
      supabaseAuthorizer,
      {
        responseTypes: [authorizers.HttpLambdaResponseType.SIMPLE],
        resultsCacheTtl: cdk.Duration.seconds(0),
      },
    );

    api.addRoutes({
      path: "/v1/notebooks/{notebookId}/live-sessions",
      methods: [apigatewayv2.HttpMethod.POST],
      authorizer,
      integration: new integrations.HttpLambdaIntegration(
        "LiveSessionIntegration",
        liveSessionBroker,
      ),
    });

    const stage = new apigatewayv2.HttpStage(this, "DefaultStage", {
      httpApi: api,
      stageName: "$default",
      autoDeploy: true,
      detailedMetricsEnabled: true,
      throttle: {
        burstLimit: 20,
        rateLimit: 10,
      },
    });

    new cdk.CfnOutput(this, "NotebookRuntimeUrl", {
      description: "Base URL used by the web and mobile Notebook Runtime adapters",
      value: stage.url,
    });
  }
}
