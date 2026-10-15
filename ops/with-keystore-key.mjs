#!/usr/bin/env node
// Run a command with a private key from the Splits CLI keystore (~/.splits/config.json, written by
// `splits auth create-key` / `import-key`) injected into the child's environment — and nowhere else.
//
//   node ops/with-keystore-key.mjs DEPLOYER_PRIVATE_KEY=0xKeeperAddress -- forge script ... --broadcast
//
// The key is read in-process and handed to the child via env, so it never appears in a shell command,
// shell history, or this process's output. Exit status is the child's.
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';

const sep = process.argv.indexOf('--');
if (sep < 2 || sep === process.argv.length - 1) {
  console.error('usage: with-keystore-key.mjs VAR=0xaddress [VAR2=0xaddress2 ...] -- <command> [args...]');
  process.exit(64);
}

const env = { ...process.env };
const path = `${homedir()}/.splits/config.json`;
let keys;
try {
  keys = JSON.parse(readFileSync(path, 'utf8')).keys ?? {};
} catch {
  console.error(`cannot read the Splits CLI keystore at ${path}`);
  process.exit(66);
}

for (const spec of process.argv.slice(2, sep)) {
  const m = /^([A-Za-z_][A-Za-z0-9_]*)=(0x[0-9a-fA-F]{40})$/.exec(spec);
  if (!m) {
    console.error(`bad spec "${spec}": expected VAR=0xaddress`);
    process.exit(64);
  }
  const [, name, address] = m;
  const entry = Object.entries(keys).find(([a]) => a.toLowerCase() === address.toLowerCase());
  if (!entry?.[1]?.privateKey) {
    console.error(`no local key for ${address} in ${path}`);
    process.exit(66);
  }
  env[name] = String(entry[1].privateKey).trim();
}

const [cmd, ...args] = process.argv.slice(sep + 1);
const r = spawnSync(cmd, args, { stdio: 'inherit', env });
process.exit(r.status ?? 1);
