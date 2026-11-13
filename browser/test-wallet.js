// Test-only wallet fixtures for the browser suites.
//
// A disposable test wallet is a fresh BIP-39 mnemonic, its 64-byte seed, and an
// explicitly provisioned `haystack-wallet` pair under a unique test name. This
// module is installed by the test targets only; it is not the player wallet and
// it never provisions the fixed user wallet implicitly.
import {call_pure, provision_wallet} from "./wallet/cdk_wallet_browser.js";

export {
  USER_WALLET_NAME,
  deleteMnemonic,
  deleteState,
  deleteWallet,
  readWallet,
  setStateData,
  writeState,
} from "./wallet-store.js";

function checked(raw) {
  const value = JSON.parse(raw);
  if (!value || value.status !== 0) throw new Error("wallet test helper failed");
  return value;
}

export function generateMnemonic() {
  const mnemonic = checked(call_pure("generate_mnemonic", "[]")).value;
  if (typeof mnemonic !== "string" || mnemonic.length === 0) throw new Error("mnemonic generation failed");
  return mnemonic;
}

export function seedFromMnemonic(mnemonic) {
  const hex = checked(call_pure("mnemonic_to_seed", JSON.stringify([mnemonic]))).hex;
  if (typeof hex !== "string" || !/^[0-9a-f]{128}$/i.test(hex)) throw new Error("seed derivation failed");
  return Uint8Array.from(hex.match(/../g), byte => parseInt(byte, 16));
}

export function seedFromHex(hex) {
  if (typeof hex !== "string" || !/^[0-9a-f]{128}$/i.test(hex)) throw new Error("seed hex is invalid");
  return Uint8Array.from(hex.match(/../g), byte => parseInt(byte, 16));
}

export function hexFromSeed(seed) {
  return Array.from(seed, byte => byte.toString(16).padStart(2, "0")).join("");
}

// Provision a fresh disposable wallet and return its seed. The mnemonic is
// derived locally, stored once by provisioning, and not retained.
export async function createWallet(name) {
  const mnemonic = generateMnemonic();
  const seed = seedFromMnemonic(mnemonic);
  try {
    await provision_wallet(mnemonic, name);
  } catch (error) {
    seed.fill(0);
    throw error;
  }
  return seed;
}

export async function createWalletHex(name) {
  const seed = await createWallet(name);
  const hex = hexFromSeed(seed);
  seed.fill(0);
  return hex;
}
