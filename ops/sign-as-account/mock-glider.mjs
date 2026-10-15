#!/usr/bin/env node
// Local stand-in for the two Glider enrollment endpoints, used only by test.sh so the live
// code path of glider-enroll.mjs (stage 1 -> sign -> stage 2) can be exercised without a Glider
// key or any network access to Glider.
//
// Mirrors the documented contract: ERC1271 stage 1 returns message.kind "typed-data"; stage 2 must
// echo flowId/accountIndex (string)/agentAccountId/ownerAccountId/strategyId/chainIds unchanged,
// and the signature is checked the way Glider says it is: ERC-1271 isValidSignature on the owner
// account over hashTypedData(typedData). Same flowId + same body replays the cached response;
// same flowId + different body is 409 API_008.
//
// Usage: node mock-glider.mjs --port 18546 --rpc http://127.0.0.1:18545

import { createServer } from 'node:http';
import { parseArgs } from 'node:util';
import { createPublicClient, getAddress, hashTypedData, http, keccak256, parseAbi, stringToHex } from 'viem';

const { values } = parseArgs({
  options: { port: { type: 'string', default: '18546' }, rpc: { type: 'string' } },
  strict: true,
});
if (!values.rpc) throw new Error('--rpc is required');

const client = createPublicClient({ transport: http(values.rpc) });
const abi = parseAbi(['function isValidSignature(bytes32 hash, bytes signature) view returns (bytes4)']);
const AGENT = 'eip155:0:0x1111111111111111111111111111111111111111';
const ROUND_TRIP = ['ownerAccountId', 'strategyId', 'chainIds', 'accountType', 'accountIndex', 'agentAccountId'];

const flows = new Map(); // flowId -> { stage1 request, typedData }
const done = new Map(); // flowId -> { body, response }
let counter = 0;

const send = (res, status, body) => {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
};
const fail = (res, status, code, message) => send(res, status, { success: false, error: { code, message } });

async function stage1(body, res) {
  if (body.accountType !== 'ERC1271') return fail(res, 400, 'API_400', 'mock expects accountType ERC1271');
  if (!/^eip155:0:0x[0-9a-fA-F]{40}$/.test(body.ownerAccountId ?? '')) {
    return fail(res, 400, 'API_400', 'malformed ownerAccountId');
  }
  if (!Array.isArray(body.chainIds) || body.chainIds.length !== 1) {
    return fail(res, 400, 'API_400', 'ERC1271 requires exactly one chainId');
  }
  const flowId = `flow_mock_${++counter}`;
  const typedData = {
    domain: {
      name: 'ERC1271Validator',
      version: '0.0.1',
      chainId: body.chainIds[0],
      verifyingContract: '0x9999999999999999999999999999999999999999',
    },
    types: { MessageHash: [{ name: 'hash', type: 'bytes32' }] },
    primaryType: 'MessageHash',
    message: { hash: keccak256(stringToHex(`${flowId}:${body.ownerAccountId}:${body.strategyId}`)) },
  };
  flows.set(flowId, { body, typedData });
  return send(res, 200, {
    success: true,
    data: {
      message: { kind: 'typed-data', typedData },
      agentAccountId: AGENT,
      accountIndex: '7',
      accountType: 'ERC1271',
      flowId,
    },
  });
}

async function stage2(body, res) {
  const cached = done.get(body.flowId);
  if (cached) {
    if (cached.body !== JSON.stringify(body)) {
      return fail(res, 409, 'API_008', 'Idempotency key conflict: a previous request with this key used a different body');
    }
    return send(res, 201, cached.response);
  }
  const flow = flows.get(body.flowId);
  if (!flow) return fail(res, 400, 'API_400', 'unknown or expired flowId');
  if (body.accountIndex !== '7') return fail(res, 400, 'API_400', 'accountIndex must round-trip as the string "7"');
  if (body.agentAccountId !== AGENT) return fail(res, 400, 'API_400', 'agentAccountId changed between stages');
  for (const field of ROUND_TRIP) {
    if (field in flow.body && JSON.stringify(flow.body[field]) !== JSON.stringify(body[field])) {
      return fail(res, 400, 'API_400', `${field} changed between stages`);
    }
  }
  const owner = getAddress(body.ownerAccountId.split(':')[2]);
  let magic;
  try {
    magic = await client.readContract({
      address: owner,
      abi,
      functionName: 'isValidSignature',
      args: [hashTypedData({ ...flow.typedData, domain: { ...flow.typedData.domain, chainId: BigInt(flow.typedData.domain.chainId) } }), body.signature],
    });
  } catch {
    return fail(res, 400, 'API_400', 'invalid signature (isValidSignature reverted)');
  }
  if (magic !== '0x1626ba7e') return fail(res, 400, 'API_400', 'invalid signature');

  const chainId = body.chainIds[0];
  const response = {
    success: true,
    data: {
      portfolioId: `mock_pf_${body.flowId}`,
      portfolioName: body.portfolioName ?? null,
      strategyId: body.strategyId,
      smartAccounts: [{ accountId: `eip155:${chainId}:0x${keccak256(stringToHex(body.flowId)).slice(26)}` }],
    },
  };
  done.set(body.flowId, { body: JSON.stringify(body), response });
  return send(res, 201, response);
}

const server = createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', async () => {
    try {
      if (!req.headers['x-api-key']) return fail(res, 401, 'API_100', 'missing x-api-key');
      if (req.method !== 'POST') return fail(res, 404, 'API_404', 'not found');
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (req.url === '/v2/enroll/signature') return await stage1(body, res);
      if (req.url === '/v2/enroll') return await stage2(body, res);
      return fail(res, 404, 'API_404', 'not found');
    } catch (err) {
      return fail(res, 500, 'API_600', String(err.message));
    }
  });
});

server.listen(Number(values.port), '127.0.0.1', () => {
  process.stdout.write(`mock-glider listening on 127.0.0.1:${values.port}\n`);
});
