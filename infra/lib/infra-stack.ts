import * as cdk from "aws-cdk-lib/core";
import * as apigatewayv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as authorizers from "aws-cdk-lib/aws-apigatewayv2-authorizers";
import * as integrations from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
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
      description: "Optional web origin; leave empty for a native-only deployment",
      allowedPattern: "^$|https?://[^/]+",
      default: "",
    });
    const hasWebOrigin = new cdk.CfnCondition(this, "HasWebOrigin", {
      expression: cdk.Fn.conditionNot(cdk.Fn.conditionEquals(webOrigin.valueAsString, "")),
    });
    // Accounts with a low Lambda concurrency quota cannot reserve capacity,
    // so the reservation is opt-in.
    const workerReservedConcurrency = new cdk.CfnParameter(this, "WorkerReservedConcurrency", {
      type: "Number",
      description: "Reservation per worker; zero uses account shared concurrency",
      default: 0,
      minValue: 0,
    });
    const hasWorkerReservation = new cdk.CfnCondition(this, "HasWorkerReservation", {
      expression: cdk.Fn.conditionNot(
        cdk.Fn.conditionEquals(workerReservedConcurrency.valueAsNumber, 0),
      ),
    });
    const reserveConcurrency = (fn: lambda.Function) => {
      (fn.node.defaultChild as lambda.CfnFunction).reservedConcurrentExecutions =
        cdk.Token.asNumber(
          cdk.Fn.conditionIf(
            hasWorkerReservation.logicalId,
            workerReservedConcurrency.valueAsNumber,
            cdk.Aws.NO_VALUE,
          ),
        );
    };

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
        LIVE_SESSION_START_WINDOW_SECONDS: "600",
      },
    });
    reserveConcurrency(liveSessionBroker);
    geminiApiKey.grantRead(liveSessionBroker);

    const extractionCache = new dynamodb.Table(this, "GraphExtractionCache", {
      partitionKey: { name: "id", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      encryption: dynamodb.TableEncryption.AWS_MANAGED,
      timeToLiveAttribute: "expiresAt",
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    const graphExtractor = new lambda.Function(this, "GraphExtractorFunction", {
      ...commonFunctionProperties,
      description: "Extracts validated graph patches without exposing Gemini credentials",
      handler: "index.handler",
      code: lambda.Code.fromAsset(path.join(lambdaDirectory, "extract-graph")),
      timeout: cdk.Duration.seconds(30),
      environment: {
        ...sharedEnvironment,
        GEMINI_SECRET_ARN: geminiApiKey.secretArn,
        GEMINI_EXTRACTION_MODEL: "gemini-2.5-flash",
        EXTRACTION_CACHE_TABLE_NAME: extractionCache.tableName,
      },
    });
    reserveConcurrency(graphExtractor);
    geminiApiKey.grantRead(graphExtractor);
    extractionCache.grantReadWriteData(graphExtractor);

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
    // CORS only for a web deployment; the native app doesn't need it.
    (api.node.defaultChild as apigatewayv2.CfnApi).addPropertyOverride("CorsConfiguration", {
      "Fn::If": [
        hasWebOrigin.logicalId,
        {
          AllowHeaders: ["authorization", "content-type"],
          AllowMethods: ["OPTIONS", "POST"],
          AllowOrigins: [webOrigin.valueAsString],
          MaxAge: 3600,
        },
        { Ref: "AWS::NoValue" },
      ],
    });

    const authorizer = new authorizers.HttpLambdaAuthorizer(
      "SupabaseAuthorizer",
      supabaseAuthorizer,
      {
        responseTypes: [authorizers.HttpLambdaResponseType.SIMPLE],
        resultsCacheTtl: cdk.Duration.seconds(0),
      },
    );

    const liveSessionIntegration = new integrations.HttpLambdaIntegration(
      "LiveSessionIntegration",
      liveSessionBroker,
    );

    api.addRoutes({
      path: "/v1/notebooks/{notebookId}/live-sessions",
      methods: [apigatewayv2.HttpMethod.POST],
      authorizer,
      integration: liveSessionIntegration,
    });

    // User-scoped: lets a signed-in client hold a token before any notebook opens.
    api.addRoutes({
      path: "/v1/live-sessions",
      methods: [apigatewayv2.HttpMethod.POST],
      authorizer,
      integration: liveSessionIntegration,
    });

    api.addRoutes({
      path: "/v1/notebooks/{notebookId}/extractions",
      methods: [apigatewayv2.HttpMethod.POST],
      authorizer,
      integration: new integrations.HttpLambdaIntegration(
        "GraphExtractionIntegration",
        graphExtractor,
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
