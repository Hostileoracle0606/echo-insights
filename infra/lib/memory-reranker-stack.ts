import * as cdk from "aws-cdk-lib/core";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as logs from "aws-cdk-lib/aws-logs";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
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
      logGroup: new logs.LogGroup(this, "MemoryRerankerFunctionLogs", {
        retention: logs.RetentionDays.TWO_WEEKS,
        removalPolicy: cdk.RemovalPolicy.DESTROY,
      }),
    });
    token.grantRead(reranker);

    // Server-to-server only (retrieve-memory), so no CORS; the bearer token is the gate.
    const url = reranker.addFunctionUrl({ authType: lambda.FunctionUrlAuthType.NONE });

    new cdk.CfnOutput(this, "RerankerUrl", { value: url.url });
    new cdk.CfnOutput(this, "RerankerTokenSecretArn", { value: token.secretArn });
  }
}
