#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib/core';
import { InfraStack } from '../lib/infra-stack';
import { MemoryRerankerStack } from '../lib/memory-reranker-stack';

const app = new cdk.App();
// The memory reranker service, deployed on its own (`cdk deploy MemoryRerankerStagingStack`);
// retrieve-memory on the staging Supabase project calls it. Production has none yet.
new MemoryRerankerStack(app, 'MemoryRerankerStagingStack', {
  description: 'Memory reranker for the lumen-staging Supabase project',
});
new InfraStack(app, 'InfraStack', {
  /* If you don't specify 'env', this stack will be environment-agnostic.
   * Account/Region-dependent features and context lookups will not work,
   * but a single synthesized template can be deployed anywhere. */

  /* Uncomment the next line to specialize this stack for the AWS Account
   * and Region that are implied by the current CLI configuration. */
  // env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION },

  /* Uncomment the next line if you know exactly what Account and Region you
   * want to deploy the stack to. */
  // env: { account: '123456789012', region: 'us-east-1' },

  /* For more information, see https://docs.aws.amazon.com/cdk/latest/guide/environments.html */
});
