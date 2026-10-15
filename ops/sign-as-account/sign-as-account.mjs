#!/usr/bin/env node
// Sign EIP-712 typed data *as* a Splits SmartVault (ERC-1271, threshold-aware).
//
// The vault's isValidSignature(hash, sig) does not verify `hash` directly. It wraps it:
//   W = hashTypedDataV4(SplitMessage(bytes32 hash))
//       under domain { name: "splitsSmartVault", version: "1", chainId, verifyingContract: vault }
// and then requires `threshold` distinct signers to have signed W. EOA signers sign W as an
// EIP-191 personal message over the 32 raw bytes of W. `sig` is abi.encode(ERC1271Signature),
// i.e. abi.encode((uint8 signerIndex, bytes signatureData)[]) wrapped in a struct, no type byte.
//
// Usage: node sign-as-account.mjs --vault 0x.. --rpc https://.. --typed-data payload.json \
//          --key 0:env:SIGNER0_KEY [--key 1:0x<privkey>] [--threshold-override N]
//
// Importable: glider-enroll.mjs uses signAsAccount() so both tools share one signing path.

import { readFileSync, realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import {
  createPublicClient,
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  hashTypedData,
  http,
  isAddress,
  parseAbi,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

export const MAGIC_VALUE = '0x1626ba7e';
export const WRAP_DOMAIN = { name: 'splitsSmartVault', version: '1' };

const VAULT_ABI = parseAbi([
  'function isValidSignature(bytes32 hash, bytes signature) view returns (bytes4)',
  'function replaySafeHash(bytes32 hash) view returns (bytes32)',
  'function getThreshold() view returns (uint8)',
  'function getSignerCount() view returns (uint8)',
  'function getSigner(uint8 index) view returns ((bytes32 slot1, bytes32 slot2))',
]);

// struct ERC1271Signature { SignatureWrapper[] signatures; }
// struct SignatureWrapper { uint8 signerIndex; bytes signatureData; }
// abi.encode(ERC1271Signature) encodes the (dynamic) struct as one tuple parameter.
const ERC1271_SIGNATURE_PARAMS = [
  {
    type: 'tuple',
    components: [
      {
        name: 'signatures',
        type: 'tuple[]',
        components: [
          { name: 'signerIndex', type: 'uint8' },
          { name: 'signatureData', type: 'bytes' },
        ],
      },
    ],
  },
];

const UINT160_MAX = (1n << 160n) - 1n;
const ZERO_WORD = `0x${'0'.repeat(64)}`;

/** An expected, user-facing failure. The CLI prints the message and exits non-zero. */
export class SignError extends Error {
  constructor(message) {
    super(message);
    this.name = 'SignError';
  }
}

const noopLog = () => {};
export const stderrLog = (msg) => process.stderr.write(`${msg}\n`);

// ---------------------------------------------------------------------------------------------
// Typed data
// ---------------------------------------------------------------------------------------------

function toBigInt(value, where) {
  if (typeof value === 'bigint') return value;
  if (typeof value === 'number' && Number.isSafeInteger(value)) return BigInt(value);
  if (typeof value === 'string' && /^(0x[0-9a-fA-F]+|\d+)$/.test(value)) return BigInt(value);
  throw new SignError(`typed data: ${where} is not an integer (got ${typeof value})`);
}

function coerceValue(type, value, types, where) {
  const array = /^(.*)\[(\d*)\]$/.exec(type);
  if (array) {
    if (!Array.isArray(value)) throw new SignError(`typed data: ${where} should be an array`);
    return value.map((v, i) => coerceValue(array[1], v, types, `${where}[${i}]`));
  }
  if (types[type]) return coerceStruct(type, value, types, where);
  if (/^u?int\d*$/.test(type)) return toBigInt(value, where);
  return value;
}

function coerceStruct(typeName, value, types, where) {
  if (value === null || typeof value !== 'object') {
    throw new SignError(`typed data: ${where} should be an object of type ${typeName}`);
  }
  const out = {};
  for (const field of types[typeName]) {
    if (!(field.name in value)) throw new SignError(`typed data: ${where}.${field.name} is missing`);
    out[field.name] = coerceValue(field.type, value[field.name], types, `${where}.${field.name}`);
  }
  return out;
}

/**
 * Accepts the payload a wallet's signTypedData takes ({ domain, types, primaryType, message })
 * or the places Glider nests it ({ kind, typedData }, stage-1 `data`, the API envelope), and
 * returns it with every int/uint (including domain.chainId) coerced to bigint, as viem expects.
 */
export function extractTypedData(json) {
  if (json && typeof json === 'object') {
    if (json.types && json.primaryType && json.message) return json;
    if (json.typedData) return extractTypedData(json.typedData);
    if (json.message && typeof json.message === 'object' && json.message.typedData) {
      return extractTypedData(json.message);
    }
    if (json.data) return extractTypedData(json.data);
  }
  throw new SignError('typed data: expected { domain, types, primaryType, message }');
}

export function normalizeTypedData(raw) {
  const td = extractTypedData(raw);
  const { types, primaryType } = td;
  if (!types || typeof types !== 'object' || !Array.isArray(types[primaryType])) {
    throw new SignError(`typed data: primaryType "${primaryType}" is not defined in types`);
  }
  const domain = { ...(td.domain ?? {}) };
  if (domain.chainId !== undefined) domain.chainId = toBigInt(domain.chainId, 'domain.chainId');
  return { domain, types, primaryType, message: coerceStruct(primaryType, td.message, types, 'message') };
}

export function hashPayload(raw) {
  return hashTypedData(normalizeTypedData(raw));
}

/** W: the hash the signers actually sign, = vault.replaySafeHash(hash). */
export function wrapHash({ vault, chainId, hash }) {
  return hashTypedData({
    domain: { ...WRAP_DOMAIN, chainId: BigInt(chainId), verifyingContract: vault },
    types: { SplitMessage: [{ name: 'hash', type: 'bytes32' }] },
    primaryType: 'SplitMessage',
    message: { hash },
  });
}

// ---------------------------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------------------------

/** Parses "<index>:<0x privkey>" or "<index>:env:VAR". Never echoes the key in an error. */
export function parseKeySpec(spec, env = process.env) {
  const m = /^(\d{1,3}):(.+)$/.exec(spec);
  if (!m) throw new SignError('--key: expected <index>:<0xprivatekey> or <index>:env:VAR');
  const index = Number(m[1]);
  if (index > 255) throw new SignError(`--key: signer index ${index} is out of range (0-255)`);
  let secret = m[2];
  if (secret.startsWith('env:')) {
    const name = secret.slice(4);
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) throw new SignError(`--key ${index}: invalid env var name`);
    if (!env[name]) throw new SignError(`--key ${index}: environment variable ${name} is not set`);
    secret = env[name].trim();
  }
  if (!secret.startsWith('0x')) secret = `0x${secret}`;
  if (!/^0x[0-9a-fA-F]{64}$/.test(secret)) {
    throw new SignError(`--key ${index}: private key must be 32 bytes of hex`);
  }
  return { index, account: privateKeyToAccount(secret) };
}

// ---------------------------------------------------------------------------------------------
// Core
// ---------------------------------------------------------------------------------------------

function describeError(err, rpc) {
  let msg = err?.shortMessage || err?.message || String(err);
  if (rpc) msg = msg.split(rpc).join('<rpc>');
  return msg;
}

async function rpcCall(what, rpc, fn) {
  try {
    return await fn();
  } catch (err) {
    throw new SignError(`${what}: ${describeError(err, rpc)}`);
  }
}

/**
 * Signs `typedData` as the Splits SmartVault at `vault`.
 *
 * @param {object} p
 * @param {string} p.vault               SmartVault address (must already be deployed)
 * @param {string} p.rpc                 JSON-RPC URL of the chain the vault lives on
 * @param {object} p.typedData           EIP-712 payload { domain, types, primaryType, message }
 * @param {{index:number, account:object}[]} p.keys   EOA signer keys, see parseKeySpec
 * @param {number} [p.thresholdOverride] Use N instead of the on-chain threshold for the
 *                                        "enough keys" pre-check. The final on-chain
 *                                        verification is still authoritative.
 * @param {number} [p.expectedChainId]   Fail if the RPC is not on this chain
 * @param {(msg:string)=>void} [p.log]   Progress/diagnostics sink (never receives secrets)
 */
export async function signAsAccount({
  vault,
  rpc,
  typedData,
  keys,
  thresholdOverride,
  expectedChainId,
  log = noopLog,
}) {
  if (!isAddress(vault, { strict: false })) throw new SignError(`--vault: "${vault}" is not an address`);
  vault = getAddress(vault);
  if (!rpc) throw new SignError('--rpc is required');
  if (!keys?.length) throw new SignError('at least one --key is required');
  const seen = new Set();
  for (const { index } of keys) {
    if (seen.has(index)) throw new SignError(`--key: signer index ${index} given more than once`);
    seen.add(index);
  }

  const normalized = normalizeTypedData(typedData);
  const hash = hashTypedData(normalized);
  log(`typed data: primaryType=${normalized.primaryType} hash=${hash}`);

  const client = createPublicClient({ transport: http(rpc, { timeout: 30_000, retryCount: 2 }) });

  const chainId = await rpcCall('eth_chainId', rpc, () => client.getChainId());
  if (expectedChainId !== undefined && chainId !== Number(expectedChainId)) {
    throw new SignError(`RPC is on chain ${chainId}, expected ${expectedChainId}`);
  }
  if (normalized.domain.chainId !== undefined && Number(normalized.domain.chainId) !== chainId) {
    log(`warning: typed-data domain.chainId=${normalized.domain.chainId} but the vault RPC is on chain ${chainId}`);
  }

  const code = await rpcCall('eth_getCode', rpc, () => client.getCode({ address: vault }));
  if (!code || code === '0x') {
    throw new SignError(
      `no contract code at ${vault} on chain ${chainId}. Counterfactual (undeployed) vaults need ERC-6492, which is not supported; deploy the vault first.`,
    );
  }

  // 1. W locally, cross-checked against the chain. A mismatch means the wrap assumption is wrong.
  const W = wrapHash({ vault, chainId, hash });
  const onchainW = await rpcCall(
    `replaySafeHash on ${vault} (is it a Splits SmartVault?)`,
    rpc,
    () => client.readContract({ address: vault, abi: VAULT_ABI, functionName: 'replaySafeHash', args: [hash] }),
  );
  if (onchainW.toLowerCase() !== W.toLowerCase()) {
    throw new SignError(
      `replay-safe hash mismatch: local ${W} != vault.replaySafeHash ${onchainW}. The SplitMessage wrap assumption does not hold for this vault; refusing to sign.`,
    );
  }
  log(`replaySafeHash: ${W} (local == onchain)`);

  // 2. Threshold and key pre-checks.
  const onchainThreshold = Number(
    await rpcCall('getThreshold', rpc, () =>
      client.readContract({ address: vault, abi: VAULT_ABI, functionName: 'getThreshold' }),
    ),
  );
  const signerCount = Number(
    await rpcCall('getSignerCount', rpc, () =>
      client.readContract({ address: vault, abi: VAULT_ABI, functionName: 'getSignerCount' }),
    ),
  );
  let threshold = onchainThreshold;
  if (thresholdOverride !== undefined) {
    if (!Number.isInteger(thresholdOverride) || thresholdOverride < 1 || thresholdOverride > 255) {
      throw new SignError('--threshold-override must be an integer in 1..255');
    }
    if (thresholdOverride !== onchainThreshold) {
      log(`warning: --threshold-override ${thresholdOverride} differs from on-chain threshold ${onchainThreshold}`);
    }
    threshold = thresholdOverride;
  }
  log(`vault: chain=${chainId} threshold=${onchainThreshold} signers=${signerCount}; keys supplied=${keys.length}`);
  if (keys.length < threshold) {
    throw new SignError(
      `vault requires ${threshold} signature(s) but only ${keys.length} key(s) supplied. Provide ${threshold - keys.length} more with --key <index>:<key>.`,
    );
  }

  const sorted = [...keys].sort((a, b) => a.index - b.index);
  for (const { index, account } of sorted) {
    const signer = await rpcCall(`getSigner(${index})`, rpc, () =>
      client.readContract({ address: vault, abi: VAULT_ABI, functionName: 'getSigner', args: [index] }),
    );
    if (signer.slot2 !== ZERO_WORD) {
      throw new SignError(
        `signer index ${index} is a passkey (WebAuthn) signer. Passkey signatures need a WebAuthn assertion and are out of scope; use only EOA signer slots.`,
      );
    }
    const slot1 = BigInt(signer.slot1);
    if (slot1 === 0n) throw new SignError(`no signer registered at index ${index}`);
    if (slot1 > UINT160_MAX) throw new SignError(`signer index ${index} holds an invalid EOA slot`);
    const signerAddress = getAddress(`0x${signer.slot1.slice(26)}`);
    if (signerAddress !== account.address) {
      const signerCode = await rpcCall('eth_getCode', rpc, () => client.getCode({ address: signerAddress }));
      const hint =
        signerCode && signerCode !== '0x' && !signerCode.startsWith('0xef0100')
          ? ' (that signer is a contract account; nested ERC-1271 signers are not supported)'
          : '';
      throw new SignError(
        `key for index ${index} derives ${account.address} but the vault's signer ${index} is ${signerAddress}${hint}`,
      );
    }
  }

  // 3. Sign W with every key: EIP-191 personal_sign over the 32 raw bytes of W.
  const wrappers = [];
  for (const { index, account } of sorted) {
    const signatureData = await account.signMessage({ message: { raw: W } });
    wrappers.push({ signerIndex: index, signatureData });
  }
  const signature = encodeAbiParameters(ERC1271_SIGNATURE_PARAMS, [{ signatures: wrappers }]);

  // 4. Nothing is printed until the vault itself accepts the signature.
  let magic;
  try {
    const { data } = await client.call({
      to: vault,
      data: encodeFunctionData({ abi: VAULT_ABI, functionName: 'isValidSignature', args: [hash, signature] }),
    });
    magic = decodeFunctionResult({ abi: VAULT_ABI, functionName: 'isValidSignature', data });
  } catch (err) {
    throw new SignError(
      `vault.isValidSignature reverted (too few signatures for the on-chain threshold, a bad signer index or a malformed signature): ${describeError(err, rpc)}`,
    );
  }
  if (magic.toLowerCase() !== MAGIC_VALUE) {
    throw new SignError(`vault.isValidSignature returned ${magic}, expected ${MAGIC_VALUE}. Signature rejected.`);
  }
  log(`verified: vault.isValidSignature returned ${MAGIC_VALUE}`);

  return {
    hash,
    replaySafeHash: W,
    signature,
    signers: sorted.map(({ index, account }) => ({ index, address: account.address })),
    verified: true,
  };
}

// ---------------------------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------------------------

const USAGE = `Usage: sign-as-account.mjs --vault <addr> --rpc <url> --typed-data <file.json>
         --key <index>:<0xprivkey | env:VAR> [--key ...] [--threshold-override <n>]

Signs EIP-712 typed data as a Splits SmartVault (ERC-1271) using EOA signer keys.
Prints { hash, replaySafeHash, signature, signers, verified } to stdout only after the
vault's own isValidSignature accepts the signature. Diagnostics go to stderr.
Prefer --key <index>:env:VAR so keys stay out of the process list.
`;

export function parseThresholdOverride(value) {
  if (value === undefined) return undefined;
  if (!/^\d+$/.test(value)) throw new SignError('--threshold-override must be an integer in 1..255');
  return Number(value);
}

export function readJsonFile(path, flag) {
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch (err) {
    throw new SignError(`${flag}: cannot read ${path}: ${err.code ?? err.message}`);
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new SignError(`${flag}: ${path} is not valid JSON`);
  }
}

async function main(argv) {
  const { values } = parseArgs({
    args: argv,
    options: {
      vault: { type: 'string' },
      rpc: { type: 'string' },
      'typed-data': { type: 'string' },
      key: { type: 'string', multiple: true },
      'threshold-override': { type: 'string' },
      help: { type: 'boolean', short: 'h' },
    },
    strict: true,
  });
  if (values.help) {
    process.stdout.write(USAGE);
    return;
  }
  for (const required of ['vault', 'rpc', 'typed-data']) {
    if (!values[required]) throw new SignError(`--${required} is required\n\n${USAGE}`);
  }
  const keys = (values.key ?? []).map((spec) => parseKeySpec(spec));
  const result = await signAsAccount({
    vault: values.vault,
    rpc: values.rpc,
    typedData: readJsonFile(values['typed-data'], '--typed-data'),
    keys,
    thresholdOverride: parseThresholdOverride(values['threshold-override']),
    log: stderrLog,
  });
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

export function runCli(main_, argv = process.argv.slice(2)) {
  return main_(argv).catch((err) => {
    if (err instanceof SignError) {
      process.stderr.write(`error: ${err.message}\n`);
    } else if (err?.code === 'ERR_PARSE_ARGS_UNKNOWN_OPTION' || err?.code?.startsWith?.('ERR_PARSE_ARGS')) {
      process.stderr.write(`error: ${err.message}\n`);
    } else {
      process.stderr.write(`unexpected error: ${err?.message ?? err}\n`);
    }
    process.exitCode = 1;
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  await runCli(main);
}
