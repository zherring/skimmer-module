#!/usr/bin/env node
// Glider two-stage enrollment for a Splits SmartVault owner (accountType "ERC1271").
//
//   Stage 1  POST {api}/enroll/signature  -> data.message.typedData, flowId, accountIndex, agentAccountId
//   sign     typedData signed AS the vault with sign-as-account.mjs's signAsAccount() (same code path)
//   Stage 2  POST {api}/enroll            -> data.portfolioId, data.smartAccounts[]
//
// Shapes follow Glider's OpenAPI (CreateEnrollSignatureRequest / CreateEnrollRequest) and
// guides/two-stage-enrollment: stage-1 round-trip fields (flowId, accountIndex as a *string*,
// agentAccountId) go back to stage 2 byte-for-byte; flowId is the idempotency anchor, so retries
// reuse the same flowId and the same body.
//
// Usage:
//   GLIDER_API_KEY=... node glider-enroll.mjs --owner 0xVault --strategy <id> --rpc <base rpc> \
//     --key 0:env:SIGNER0_KEY [--key 1:env:SIGNER1_KEY] [--chain 8453] [--api <base url>] \
//     [--portfolio-name <name>] [--dry-run] [--typed-data <file>]

import { parseArgs } from 'node:util';
import { getAddress, isAddress } from 'viem';
import {
  SignError,
  extractTypedData,
  parseKeySpec,
  parseThresholdOverride,
  readJsonFile,
  runCli,
  signAsAccount,
  stderrLog,
} from './sign-as-account.mjs';

export const DEFAULT_API = 'https://staging-api.glider.fi/v2';

const USAGE = `Usage: glider-enroll.mjs --owner <vault> --strategy <id> --rpc <url> --key <index>:<key|env:VAR> [...]
         [--chain 8453] [--api ${DEFAULT_API}] [--portfolio-name <name>]
         [--threshold-override <n>] [--dry-run] [--typed-data <file>]
         [--flow-id <id>] [--account-index <n>] [--agent-account-id <caip10>]

Env: GLIDER_API_KEY (not needed with --dry-run)

--dry-run         print the exact curl commands and the signed payload; never calls the Glider API
--typed-data FILE skip stage 1 and sign FILE instead (raw EIP-712 payload, or a saved stage-1
                  response; --flow-id/--account-index/--agent-account-id fill what FILE lacks)
`;

const sq = (s) => `'${String(s).replaceAll("'", `'\\''`)}'`;

function curlCommand(url, body) {
  return [
    `curl -sS -X POST ${sq(url)}`,
    `-H "x-api-key: $GLIDER_API_KEY"`,
    `-H 'Content-Type: application/json'`,
    `-d ${sq(JSON.stringify(body, null, 2))}`,
  ].join(' \\\n  ');
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function postJson({ url, body, apiKey, label, retries }) {
  let delay = 1000;
  for (let attempt = 0; ; attempt++) {
    let res;
    let text;
    try {
      res = await fetch(url, {
        method: 'POST',
        headers: { 'x-api-key': apiKey, 'content-type': 'application/json' },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(30_000),
      });
      text = await res.text();
    } catch (err) {
      if (attempt < retries) {
        await sleep(delay);
        delay = Math.min(delay * 2, 30_000);
        continue;
      }
      throw new SignError(`${label}: network error (${err.cause?.code ?? err.message})`);
    }
    let json;
    try {
      json = JSON.parse(text);
    } catch {
      json = undefined;
    }
    if (res.ok) return { status: res.status, json };

    const code = json?.error?.code;
    // Documented as safe to retry with the same anchor and body: 5xx, 429, API_007 (in progress).
    const retryable = res.status >= 500 || res.status === 429 || code === 'API_007';
    if (retryable && attempt < retries) {
      const retryAfter = Number(res.headers.get('retry-after'));
      await sleep(Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : delay);
      delay = Math.min(delay * 2, 30_000);
      continue;
    }
    const detail = [json?.error?.message ?? text.slice(0, 300), ...(json?.error?.details ?? [])].join('; ');
    throw new SignError(`${label}: HTTP ${res.status}${code ? ` ${code}` : ''}: ${detail}`);
  }
}

function requireString(value, what) {
  if (typeof value !== 'string' || value.length === 0) {
    throw new SignError(`${what} must be a non-empty string`);
  }
  return value;
}

function parseStage1(json, chain) {
  const data = json?.data;
  if (!json?.success || !data) throw new SignError('stage 1: response has no data');
  if (data.message?.kind !== 'typed-data' || !data.message.typedData) {
    throw new SignError(
      `stage 1: expected message.kind "typed-data" for accountType ERC1271, got "${data.message?.kind}"`,
    );
  }
  if (data.accountType !== undefined && data.accountType !== 'ERC1271') {
    throw new SignError(`stage 1: accountType came back as ${data.accountType}, expected ERC1271`);
  }
  if (typeof data.accountIndex !== 'string' || !/^\d+$/.test(data.accountIndex)) {
    throw new SignError('stage 1: accountIndex must be a decimal string');
  }
  const domainChain = data.message.typedData.domain?.chainId;
  if (domainChain !== undefined && Number(domainChain) !== chain) {
    stderrLog(`warning: typed-data domain.chainId=${domainChain} but --chain is ${chain}`);
  }
  return {
    typedData: data.message.typedData,
    flowId: requireString(data.flowId, 'stage 1: flowId'),
    accountIndex: data.accountIndex,
    agentAccountId: requireString(data.agentAccountId, 'stage 1: agentAccountId'),
  };
}

/** --typed-data FILE: a raw payload, or a saved stage-1 response (envelope or `data`). */
function stage1FromFile(path, flags) {
  const json = readJsonFile(path, '--typed-data');
  const typedData = extractTypedData(json);
  const root = json?.data && !json.types ? json.data : json;
  const accountIndex = root.accountIndex ?? flags['account-index'];
  if (accountIndex !== undefined && (typeof accountIndex !== 'string' || !/^\d+$/.test(accountIndex))) {
    throw new SignError('accountIndex must be a decimal string (Glider rejects numbers)');
  }
  return {
    typedData,
    flowId: root.flowId ?? flags['flow-id'],
    accountIndex,
    agentAccountId: root.agentAccountId ?? flags['agent-account-id'],
  };
}

function describeTypedData(td) {
  const d = td.domain ?? {};
  return `domain={name:${d.name}, version:${d.version}, chainId:${d.chainId}, verifyingContract:${d.verifyingContract}} primaryType=${td.primaryType} message=${JSON.stringify(td.message)}`;
}

async function main(argv) {
  const { values } = parseArgs({
    args: argv,
    options: {
      api: { type: 'string', default: DEFAULT_API },
      owner: { type: 'string' },
      vault: { type: 'string' },
      chain: { type: 'string', default: '8453' },
      strategy: { type: 'string' },
      rpc: { type: 'string' },
      key: { type: 'string', multiple: true },
      'threshold-override': { type: 'string' },
      'typed-data': { type: 'string' },
      'flow-id': { type: 'string' },
      'account-index': { type: 'string' },
      'agent-account-id': { type: 'string' },
      'portfolio-name': { type: 'string' },
      'dry-run': { type: 'boolean', default: false },
      help: { type: 'boolean', short: 'h' },
    },
    strict: true,
  });
  if (values.help) {
    process.stdout.write(USAGE);
    return;
  }

  const ownerArg = values.owner ?? values.vault;
  if (values.owner && values.vault && values.owner.toLowerCase() !== values.vault.toLowerCase()) {
    throw new SignError('--owner and --vault must be the same address');
  }
  if (!ownerArg) throw new SignError(`--owner <vault> is required\n\n${USAGE}`);
  if (!isAddress(ownerArg, { strict: false })) throw new SignError(`--owner: "${ownerArg}" is not an address`);
  const vault = getAddress(ownerArg);
  if (!/^\d+$/.test(values.chain) || Number(values.chain) < 1) throw new SignError('--chain must be a positive integer');
  const chain = Number(values.chain);
  const dryRun = values['dry-run'];
  const api = values.api.replace(/\/+$/, '');
  const fromFile = values['typed-data'];
  if (!values.strategy) throw new SignError(`--strategy <id> is required\n\n${USAGE}`);

  // Chain-agnostic CAIP-10 owner, same string in both stages. Glider lower-cases addresses.
  const ownerAccountId = `eip155:0:${vault.toLowerCase()}`;
  const chainIds = [chain];
  const stage1Body = { ownerAccountId, strategyId: values.strategy, chainIds, accountType: 'ERC1271' };

  const apiKey = process.env.GLIDER_API_KEY;
  if (!dryRun && !apiKey) throw new SignError('GLIDER_API_KEY is not set');

  // Signing inputs are only needed once there is typed data to sign.
  const willSign = Boolean(fromFile) || !dryRun;
  const keys = (values.key ?? []).map((spec) => parseKeySpec(spec));
  if (willSign) {
    if (!values.rpc) throw new SignError('--rpc is required to sign');
    if (keys.length === 0) throw new SignError('at least one --key is required to sign');
  }

  // ---- stage 1 -------------------------------------------------------------------------------
  let stage1;
  if (fromFile) {
    stage1 = stage1FromFile(fromFile, values);
    stderrLog(`stage 1 skipped: using typed data from ${fromFile}`);
  } else if (!dryRun) {
    stderrLog(`stage 1: POST ${api}/enroll/signature`);
    const { json } = await postJson({
      url: `${api}/enroll/signature`,
      body: stage1Body,
      apiKey,
      label: 'stage 1',
      retries: 2,
    });
    stage1 = parseStage1(json, chain);
    stderrLog(`stage 1: flowId=${stage1.flowId} accountIndex=${stage1.accountIndex} agent=${stage1.agentAccountId}`);
  }

  // ---- sign ----------------------------------------------------------------------------------
  let signed;
  if (stage1?.typedData) {
    stderrLog(`signing as ${vault}: ${describeTypedData(stage1.typedData)}`);
    signed = await signAsAccount({
      vault,
      rpc: values.rpc,
      typedData: stage1.typedData,
      keys,
      thresholdOverride: parseThresholdOverride(values['threshold-override']),
      expectedChainId: chain,
      log: stderrLog,
    });
  }

  // ---- stage 2 body --------------------------------------------------------------------------
  // Round-trip fields are copied from stage 1 unchanged. Placeholders only appear in --dry-run.
  const placeholder = (what) => `<${what}>`;
  if (!dryRun) {
    for (const [field, flag] of [
      ['flowId', '--flow-id'],
      ['accountIndex', '--account-index'],
      ['agentAccountId', '--agent-account-id'],
    ]) {
      if (!stage1[field]) throw new SignError(`${field} is missing: pass ${flag} (or use a stage-1 response file)`);
    }
  }
  const stage2Body = {
    ownerAccountId,
    strategyId: values.strategy,
    chainIds,
    accountType: 'ERC1271',
    accountIndex: stage1?.accountIndex ?? placeholder('accountIndex from stage 1'),
    agentAccountId: stage1?.agentAccountId ?? placeholder('agentAccountId from stage 1'),
    signature: signed?.signature ?? placeholder('signature from sign-as-account.mjs'),
    flowId: stage1?.flowId ?? placeholder('flowId from stage 1'),
    ...(values['portfolio-name'] ? { portfolioName: values['portfolio-name'] } : {}),
  };

  if (dryRun) {
    const out = [];
    out.push(`# DRY RUN: nothing below was sent. Set GLIDER_API_KEY before running the curls.`);
    out.push(`# Stage 1${fromFile ? ' (skipped in this run: --typed-data supplied)' : ''}: request the signable typed data`);
    out.push(curlCommand(`${api}/enroll/signature`, stage1Body));
    if (signed) {
      out.push(`# Signed payload (vault ${vault}, signed by EOA signers ${signed.signers.map((s) => `#${s.index}`).join(', ')})`);
      out.push(JSON.stringify(signed, null, 2));
    } else {
      out.push(
        `# Next: save data.message.typedData from the stage-1 response and run`,
        `#   node sign-as-account.mjs --vault ${vault} --rpc <rpc> --typed-data typed-data.json --key <index>:env:<VAR> ...`,
        `# then put its "signature" into the stage-2 body below.`,
      );
    }
    out.push(`# Stage 2: submit the signature with the unchanged stage-1 round-trip fields`);
    out.push(curlCommand(`${api}/enroll`, stage2Body));
    process.stdout.write(`${out.join('\n')}\n`);
    return;
  }

  // ---- stage 2 -------------------------------------------------------------------------------
  stderrLog(`stage 2: POST ${api}/enroll (flowId ${stage1.flowId})`);
  const { json } = await postJson({
    url: `${api}/enroll`,
    body: stage2Body,
    apiKey,
    label: 'stage 2',
    retries: 4,
  });
  const data = json?.data;
  if (!json?.success || !Array.isArray(data?.smartAccounts)) {
    throw new SignError('stage 2: unexpected response shape (no data.smartAccounts)');
  }
  const prefix = `eip155:${chain}:`;
  const account = data.smartAccounts.find((a) => a.accountId?.toLowerCase().startsWith(prefix));
  if (!account) stderrLog(`warning: no smartAccounts entry for ${prefix}`);
  process.stdout.write(
    `${JSON.stringify(
      {
        portfolioId: data.portfolioId,
        strategyId: data.strategyId,
        flowId: stage1.flowId,
        smartAccounts: data.smartAccounts,
        smartAccount: account?.accountId,
        address: account?.accountId.slice(prefix.length),
      },
      null,
      2,
    )}\n`,
  );
}

await runCli(main);
