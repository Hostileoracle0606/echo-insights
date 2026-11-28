import * as cdk from "aws-cdk-lib/core";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as cloudwatchActions from "aws-cdk-lib/aws-cloudwatch-actions";
import * as events from "aws-cdk-lib/aws-events";
import * as targets from "aws-cdk-lib/aws-events-targets";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as logs from "aws-cdk-lib/aws-logs";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import * as sns from "aws-cdk-lib/aws-sns";
import * as subscriptions from "aws-cdk-lib/aws-sns-subscriptions";
import { Construct } from "constructs";
import { execFileSync } from "node:child_process";
import * as path from "node:path";

/**
 * The memory reranker (pool-trained 2-layer MiniLM, int8 ONNX) on native
 * onnxruntime, for retrieve-memory's v2 path (RERANKER_SERVICE_URL). It is its
 * own stack so deploying it never touches InfraStack's functions. An edge
 * worker is retired after about a second of CPU and loading the model costs
 * about half of that, so scoring moved here.
 *
 * Auth: a Function URL with a bearer token generated into Secrets Manager;
 * retrieve-memory holds the same value as a Supabase secret.
 */
export class MemoryRerankerStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const token = new secretsmanager.Secret(this, "RerankerToken", {
      description: "Bearer token retrieve-memory sends to the memory reranker",
      generateSecretString: { passwordLength: 48, excludePunctuation: true },
    });

    const logGroup = new logs.LogGroup(this, "MemoryRerankerFunctionLogs", {
      retention: logs.RetentionDays.TWO_WEEKS,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });
    const lambdaDirectory = path.join(__dirname, "..", "lambda", "memory-reranker");
    const buildScript = path.join(__dirname, "..", "scripts", "build-memory-reranker.mjs");
    const reranker = new lambda.Function(this, "MemoryRerankerFunction", {
      runtime: lambda.Runtime.NODEJS_22_X,
      architecture: lambda.Architecture.ARM_64,
      // 1,769 MB is one full vCPU: scoring is single-threaded CPU work.
      memorySize: 1769,
      timeout: cdk.Duration.seconds(10),
      loggingFormat: lambda.LoggingFormat.JSON,
      description: "Scores memory candidates with the pool-trained reranker",
      handler: "index.handler",
      // The package is built locally (no Docker): the handler bundled with the
      // edge build's tokenizer, the pinned model and the arm64 onnxruntime binary.
      code: lambda.Code.fromAsset(lambdaDirectory, {
        assetHashType: cdk.AssetHashType.OUTPUT,
        bundling: {
          image: cdk.DockerImage.fromRegistry("public.ecr.aws/lambda/nodejs:22-arm64"),
          command: ["sh", "-c", "echo 'memory-reranker builds locally only' && exit 1"],
          local: {
            tryBundle(outputDir: string) {
              execFileSync(process.execPath, [buildScript, outputDir, "linux-arm64"], { stdio: "inherit" });
              return true;
            },
          },
        },
      }),
      environment: { RERANKER_TOKEN_SECRET_ARN: token.secretArn },
      logGroup,
    });
    token.grantRead(reranker);

    // Keep one container loaded: a cold start (~0.75 s) is longer than
    // retrieve-memory's rerank timeout, so after a quiet spell the next recall
    // would fall back to plain search. A direct invoke every 5 minutes costs
    // almost nothing; provisioned concurrency would also cover bursts.
    new events.Rule(this, "MemoryRerankerWarmer", {
      description: "Keeps a memory reranker container loaded",
      schedule: events.Schedule.rate(cdk.Duration.minutes(5)),
      targets: [new targets.LambdaFunction(reranker, { event: events.RuleTargetInput.fromObject({ warm: true }) })],
    });

    // Alerts, as InfraStack's (LM-54): the address is never in the repo
    // (`-c alertEmail=...` at deploy time). retrieve-memory falls back to plain
    // search on any failure, so these say the reranker is off, not that recall is.
    const alerts = new sns.Topic(this, "RerankerAlertsTopic", { displayName: "Lumen memory reranker alerts" });
    const alertEmail = this.node.tryGetContext("alertEmail");
    if (typeof alertEmail === "string" && alertEmail.trim() !== "") {
      alerts.addSubscription(new subscriptions.EmailSubscription(alertEmail.trim()));
    }
    const fiveMinutes = cdk.Duration.minutes(5);
    // guardHandler answers a crash with a 500, so Lambda's Errors metric misses
    // it; the content-free log events count it instead.
    const failures = new logs.MetricFilter(this, "RerankerFailures", {
      logGroup,
      filterPattern: logs.FilterPattern.anyTerm("unhandled", "model_load_failed"),
      metricNamespace: "Lumen/MemoryReranker",
      metricName: "Failures",
      metricValue: "1",
      defaultValue: 0,
    }).metric({ period: fiveMinutes, statistic: "Sum" });
    const alarms: Array<[string, string, cloudwatch.IMetric, number, number]> = [
      ["RerankerFailuresAlarm", "Memory reranker failed 3 or more requests in 5 minutes", failures, 3, 1],
      ["RerankerErrorsAlarm", "Memory reranker had 3 or more Lambda errors in 5 minutes",
        reranker.metricErrors({ period: fiveMinutes, statistic: "Sum" }), 3, 1],
      ["RerankerThrottlesAlarm", "Memory reranker was throttled in 5 minutes",
        reranker.metricThrottles({ period: fiveMinutes, statistic: "Sum" }), 1, 1],
      // Scoring is ~50 ms; retrieve-memory gives up at its timeout (300 ms on staging).
      ["RerankerSlowAlarm", "Memory reranker p95 duration of 250 ms or more for 15 minutes",
        reranker.metricDuration({ period: fiveMinutes, statistic: "p95" }), 250, 3],
    ];
    for (const [id, description, metric, threshold, periods] of alarms) {
      new cloudwatch.Alarm(this, id, {
        alarmDescription: description,
        metric,
        threshold,
        evaluationPeriods: periods,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      }).addAlarmAction(new cloudwatchActions.SnsAction(alerts));
    }

    // Server-to-server only (retrieve-memory), so no CORS; the bearer token is the gate.
    const url = reranker.addFunctionUrl({ authType: lambda.FunctionUrlAuthType.NONE });

    new cdk.CfnOutput(this, "RerankerUrl", { value: url.url });
    new cdk.CfnOutput(this, "RerankerTokenSecretArn", { value: token.secretArn });
  }
}
