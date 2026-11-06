import * as cdk from "aws-cdk-lib/core";
import * as apigatewayv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as authorizers from "aws-cdk-lib/aws-apigatewayv2-authorizers";
import * as integrations from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as cloudtrail from "aws-cdk-lib/aws-cloudtrail";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as cloudwatchActions from "aws-cdk-lib/aws-cloudwatch-actions";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as logs from "aws-cdk-lib/aws-logs";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import * as sns from "aws-cdk-lib/aws-sns";
import * as subscriptions from "aws-cdk-lib/aws-sns-subscriptions";
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

    // Every function writes to a log group we own, kept 14 days (LM-44).
    // Without one, Lambda makes a group that never expires.
    const logGroupFor = (name: string) =>
      new logs.LogGroup(this, `${name}Logs`, {
        retention: logs.RetentionDays.TWO_WEEKS,
        removalPolicy: cdk.RemovalPolicy.DESTROY,
      });

    const supabaseAuthorizer = new lambda.Function(this, "SupabaseAuthorizerFunction", {
      ...commonFunctionProperties,
      logGroup: logGroupFor("SupabaseAuthorizerFunction"),
      description: "Validates Supabase user access tokens for Echo Insights",
      handler: "index.handler",
      code: lambda.Code.fromAsset(path.join(lambdaDirectory, "supabase-authorizer")),
      environment: sharedEnvironment,
    });

    const liveSessionBroker = new lambda.Function(this, "LiveSessionBrokerFunction", {
      ...commonFunctionProperties,
      logGroup: logGroupFor("LiveSessionBrokerFunction"),
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
      logGroup: logGroupFor("GraphExtractorFunction"),
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

    // Writes the card a conversation ends with (session_cards). Reads and
    // writes Supabase only with the caller's token, so it needs no table.
    const sessionCloser = new lambda.Function(this, "SessionCloserFunction", {
      ...commonFunctionProperties,
      logGroup: logGroupFor("SessionCloserFunction"),
      description: "Writes the closing card for a conversation without exposing Gemini credentials",
      handler: "index.handler",
      code: lambda.Code.fromAsset(path.join(lambdaDirectory, "close-session")),
      timeout: cdk.Duration.seconds(30),
      environment: {
        ...sharedEnvironment,
        GEMINI_SECRET_ARN: geminiApiKey.secretArn,
        GEMINI_CARD_MODEL: "gemini-2.5-flash",
      },
    });
    reserveConcurrency(sessionCloser);
    geminiApiKey.grantRead(sessionCloser);

    // Writes the next session's opening (a brief and its spoken line) into
    // session_briefs. Same code directory as the closer; separate function so
    // the closing card never waits on text-to-speech.
    const sessionBriefWriter = new lambda.Function(this, "SessionBriefFunction", {
      ...commonFunctionProperties,
      logGroup: logGroupFor("SessionBriefFunction"),
      description: "Writes the next session's opening brief and audio without exposing Gemini credentials",
      handler: "brief-index.handler",
      code: lambda.Code.fromAsset(path.join(lambdaDirectory, "close-session")),
      timeout: cdk.Duration.seconds(30),
      environment: {
        ...sharedEnvironment,
        GEMINI_SECRET_ARN: geminiApiKey.secretArn,
        GEMINI_BRIEF_MODEL: "gemini-2.5-flash",
        GEMINI_TTS_MODEL: "gemini-2.5-flash-preview-tts",
      },
    });
    reserveConcurrency(sessionBriefWriter);
    geminiApiKey.grantRead(sessionBriefWriter);

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

    api.addRoutes({
      path: "/v1/notebooks/{notebookId}/close",
      methods: [apigatewayv2.HttpMethod.POST],
      authorizer,
      integration: new integrations.HttpLambdaIntegration(
        "SessionCloseIntegration",
        sessionCloser,
      ),
    });

    api.addRoutes({
      path: "/v1/notebooks/{notebookId}/brief",
      methods: [apigatewayv2.HttpMethod.POST],
      authorizer,
      integration: new integrations.HttpLambdaIntegration(
        "SessionBriefIntegration",
        sessionBriefWriter,
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

    // Alerts (LM-54). Thresholds are per 5 minutes and sized so one failed
    // request never pages; see docs/security/incident-response.md.
    // The address is never in the repo: pass `-c alertEmail=you@example.com`
    // at deploy time. Without it the topic exists but has no subscriber.
    const alerts = new sns.Topic(this, "AlertsTopic", {
      displayName: "Lumen security and reliability alerts",
    });
    const alertEmail = this.node.tryGetContext("alertEmail");
    if (typeof alertEmail === "string" && alertEmail.trim() !== "") {
      alerts.addSubscription(new subscriptions.EmailSubscription(alertEmail.trim()));
    }
    const alertAction = new cloudwatchActions.SnsAction(alerts);
    const addAlarm = (
      id: string,
      description: string,
      metric: cloudwatch.IMetric,
      threshold: number,
    ) => {
      const alarm = new cloudwatch.Alarm(this, id, {
        alarmDescription: description,
        metric,
        threshold,
        evaluationPeriods: 1,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      });
      alarm.addAlarmAction(alertAction);
    };
    const fiveMinutes = cdk.Duration.minutes(5);

    // 3 or more errors from one function in 5 minutes.
    const functionsToWatch: Array<[string, lambda.Function]> = [
      ["SupabaseAuthorizer", supabaseAuthorizer],
      ["LiveSessionBroker", liveSessionBroker],
      ["GraphExtractor", graphExtractor],
      ["SessionCloser", sessionCloser],
      ["SessionBriefWriter", sessionBriefWriter],
    ];
    for (const [name, fn] of functionsToWatch) {
      addAlarm(
        `${name}ErrorsAlarm`,
        `${name} had 3 or more Lambda errors in 5 minutes`,
        fn.metricErrors({ period: fiveMinutes, statistic: "Sum" }),
        3,
      );
    }
    // The authorizer logs no denials (an unauthorized token is a normal
    // answer), so a spike in sign-in failures shows as client errors at the
    // API: 30 or more 4xx in 5 minutes (includes throttling and bad input).
    addAlarm(
      "ApiClientErrorSpikeAlarm",
      "30 or more API 4xx responses in 5 minutes: failed sign-ins, probing or throttling",
      stage.metricClientError({ period: fiveMinutes, statistic: "Sum" }),
      30,
    );
    addAlarm(
      "ApiServerErrorsAlarm",
      "3 or more API 5xx responses in 5 minutes",
      stage.metricServerError({ period: fiveMinutes, statistic: "Sum" }),
      3,
    );

    // Management events (console sign-ins, IAM changes, GetSecretValue) kept
    // for a year; Event history alone keeps 90 days. Private, TLS-only bucket.
    const trailBucket = new s3.Bucket(this, "AuditTrailBucket", {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      lifecycleRules: [{ expiration: cdk.Duration.days(365) }],
    });
    new cloudtrail.Trail(this, "AuditTrail", {
      bucket: trailBucket,
      isMultiRegionTrail: true,
      includeGlobalServiceEvents: true,
      enableFileValidation: true,
      managementEvents: cloudtrail.ReadWriteType.ALL,
    });

    new cdk.CfnOutput(this, "NotebookRuntimeUrl", {
      description: "Base URL used by the web and mobile Notebook Runtime adapters",
      value: stage.url,
    });
  }
}
