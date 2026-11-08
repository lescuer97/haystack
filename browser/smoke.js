// Browser-only tests. Deterministic public fixtures and a local fake mint only.
import {open_wallet} from "./wallet/cdk_wallet_browser.js";

export async function runSmoke(app) {
  await app.ready;
  const checks = [];
  window.browserTestProgress = checks;
  const assert = (condition, label) => { if (!condition) throw new Error(label); checks.push(label); };
  const ok = response => { if (response.status !== 0) throw new Error(response.error || `status ${response.status}`); return response; };
  const pure = async (name, args = []) => ok(await app.pure(name,args));
  const text = async (name, args) => (await pure(name,args)).value;
  const call = async (name, args = []) => ok(await app.call(name,args));
  const v = await fetch("spilman_vectors.json").then(r => r.json());
  // Fresh identities let the suite run repeatedly against the same fake mint
  // without reusing deterministic blinded outputs from an earlier test run.
  const seed = crypto.getRandomValues(new Uint8Array(64));
  const receiverSeed = crypto.getRandomValues(new Uint8Array(64));
  const suffix = crypto.randomUUID().replaceAll("-", "");
  const name = `smoke-${suffix}`;
  const secondName = `receiver-${suffix}`;
  let second = null;
  try {
    const mnemonic = (await pure("generate_mnemonic")).value;
    assert(mnemonic.split(" ").length === 12, "Browser CSPRNG generates BIP-39 mnemonic");
    const known = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    assert((await pure("mnemonic_to_entropy",[known])).hex === "00".repeat(16), "BIP-39 entropy matches known vector");
    assert((await pure("mnemonic_to_seed",[known])).hex.length === 128, "BIP-39 seed derivation runs");
    assert((await app.pure("mnemonic_to_seed",["invalid"])).status !== 0, "Invalid mnemonic is rejected");

    const keypair = await pure("spilman_generate_keypair");
    assert((await text("spilman_secret_key_to_pubkey",[keypair.secret_key_hex])) === keypair.pubkey_hex, "Spilman key generation and public-key derivation run");
    assert((await text("spilman_compute_channel_secret",[v.alice_secret,v.charlie_pubkey])) === v.channel_secret, "Channel secret matches native fixture");
    const keyset = v.keyset_json;
    const synth = JSON.stringify([64,32,4].map(amount => ({amount,id:v.keyset_id,secret:`fixture-input-${amount}`,C:JSON.parse(keyset).keys["1"]})));
    const token = await text("spilman_build_cashu_b_token",[v.mint_url,"sat",synth]);
    assert(token.startsWith("cashuB"), "Cashu B token encoding runs");
    assert((await text("spilman_build_cashu_a_token",[v.mint_url,synth])).startsWith("cashuA"), "Cashu A token encoding runs");
    assert(JSON.parse(await text("token_to_proofs_json",[token,keyset])).length === 3, "Cashu token decoding runs");
    const channel = JSON.parse(await text("spilman_compute_channel_from_token",[token,v.charlie_pubkey,v.alice_pubkey,v.channel_secret,String(v.expiry_timestamp),keyset,"64"]));
    assert(channel.params_json !== undefined, "Channel reconstruction runs in browser");
    assert((await pure("spilman_compute_funding_token_amount",["100",keyset,"64"])).net_sats === "100", "Funding amount matches native vector");
    const id = await text("spilman_channel_parameters_get_channel_id",[v.params_json,v.channel_secret,keyset]);
    assert(id.length === 64, "Deterministic channel ID runs");
    const outputs = await text("spilman_create_funding_outputs",[v.params_json,v.alice_secret,keyset]);
    assert(outputs === await text("spilman_create_funding_outputs",[v.params_json,v.alice_secret,keyset]), "Funding outputs are deterministic");
    async function fund(params, response) {
      const prepared=JSON.parse(await text("spilman_create_funding_swap",[params,v.channel_secret,keyset,synth]));
      const completed=JSON.parse(await text("spilman_complete_funding_swap",[JSON.stringify(response),prepared.funding_secrets_json,keyset]));
      const constructed=await text("spilman_construct_proofs",[JSON.stringify(response.signatures),prepared.funding_secrets_json,keyset]);
      assert(constructed === completed.funding_proofs_json, "Raw proof construction matches completed funding swap");
      return completed.funding_proofs_json;
    }
    const funding = await fund(v.params_json,v.responses.funding);
    assert(funding === v.funding_proofs_json, "Funding response unblinds byte-identically to native fixture");
    await pure("spilman_verify_valid_channel",[v.params_json,v.channel_secret,keyset,funding]);
    checks.push("Channel DLEQ and proofs verify");
    const signed=JSON.parse(await text("spilman_create_signed_balance_update",[v.params_json,keyset,v.alice_secret,funding,"70"]));
    await pure("spilman_verify_balance_update",[v.params_json,v.channel_secret,keyset,funding,id,"70",signed.signature]);
    checks.push("Signed balance update verifies");
    const unsigned=JSON.parse(await text("spilman_create_unsigned_balance_update",[v.params_json,keyset,v.channel_secret,funding,"70"]));
    const signature=await text("spilman_sign_with_tweaked_key_util",[v.alice_secret,unsigned.message_hex,unsigned.tweak_scalar_hex]);
    const attached=JSON.parse(await text("spilman_attach_signature_to_balance_update",[unsigned.unsigned_swap_request_json,signature,unsigned.channel_id,"70"]));
    await pure("spilman_verify_balance_update",[v.params_json,v.channel_secret,keyset,funding,id,"70",attached.signature]);
    checks.push("Unsigned/sign/attach balance-update flow verifies");
    const close=JSON.parse(await text("spilman_prepare_close_swap",[v.params_json,v.channel_secret,keyset,keyset,funding,"70",signed.signature,v.charlie_secret]));
    const closed=await pure("spilman_unblind_close_swap",[v.params_json,v.channel_secret,keyset,keyset,JSON.stringify(close.secrets_with_blinding),JSON.stringify(v.responses.close),"70",v.charlie_secret]);
    assert(closed.receiver_sum === "70" && closed.sender_sum === "30", "Cooperative close unblinds into native 70/30 split");
    const expiredFunding=await fund(v.params_expired_json,v.responses.funding_expired);
    const refund=await text("spilman_prepare_sender_refund",[v.params_expired_json,v.channel_secret,keyset,keyset,expiredFunding,v.alice_secret,String(v.refund_now),null]);
    const refunded=JSON.parse(await text("spilman_complete_sender_refund",[v.params_expired_json,v.channel_secret,keyset,expiredFunding,v.alice_secret,refund,JSON.stringify(v.responses.refund)]));
    assert(refunded.reduce((sum,p) => sum+p.amount,0) === 100, "Expired sender refund matches native fixture");

    await app.open(seed,name);
    assert((await call("list_mints")).mints.length === 0, "Shared wallet core opens browser database offline");
    let locked=false;
    try { const duplicate=await open_wallet(seed,name); await duplicate.close(); duplicate.free(); } catch { locked=true; }
    assert(locked, "Second wallet handle is rejected by Web Locks");
    assert((await app.call("add_mint",["https://mint.example.com?secret=invalid"])).status === 9, "Mint URL policy rejects query before networking");
    assert((await app.call("receive",[token])).status === 18, "Unknown-mint token is rejected before networking");
    assert((await app.call("get_active_keyset_info_json",[v.mint_url])).status === 11, "Wallet-backed Spilman helpers enforce mint approval");
    await app.close();
    const key=`cdk_wallet_browser_v1_${name}`;
    const snapshot=localStorage.getItem(key);
    let wrongSeed=false;
    try { await app.open(new Uint8Array(64).fill(99),name); } catch { wrongSeed=true; }
    assert(wrongSeed && localStorage.getItem(key) === snapshot, "Wrong seed is rejected without mutating storage");
    await app.open(seed,name);

    const mint=location.origin;
    const realSet=Storage.prototype.setItem;
    Storage.prototype.setItem=function(k,value) { if (k === key) throw new DOMException("Injected quota failure","QuotaExceededError"); return realSet.call(this,k,value); };
    let failedWrite;
    try { failedWrite=await app.call("add_mint",[mint]); } finally { Storage.prototype.setItem=realSet; }
    assert(failedWrite.status !== 0, "Storage write failure is reported, not silently accepted");
    await call("add_mint",[mint]);
    const active=await call("get_active_keyset_info_json",[mint]);
    assert(JSON.parse(active.value).keys !== undefined, "Browser Fetch retrieves approved mint keyset");
    const issued=await fetch("/test-token").then(r => { if(!r.ok) throw new Error("Local fake mint is required for network tests"); return r.json(); });
    assert((await call("receive",[issued.token])).net_sats === "100", "Browser receives 100 test sats through real Cashu HTTP protocol");
    const sent=await call("send",[mint,"40","0"]);
    assert(sent.token.startsWith("cashu"), "Browser sends a real 40-sat test token");
    assert((await call("list_pending_tokens")).pending.some(p => p.operation_id === sent.operation_id), "Outgoing token is persisted and retrievable");
    assert((await call("get_pending_token",[sent.operation_id])).token === sent.token, "Pending token retrieval preserves bearer payload");
    await app.close();
    await app.open(seed,name);
    assert((await call("list_mints")).mints.includes(mint), "Mint approval survives close/reopen");
    assert((await call("list_balances")).balances.some(b => b.sats === "60"), "60-sat balance survives persisted reopen and startup recovery");
    second=await open_wallet(receiverSeed,secondName);
    const secondCall=async (op,args=[]) => ok(JSON.parse(await second.call(op,JSON.stringify(args))));
    await secondCall("add_mint",[mint]);
    assert((await secondCall("receive",[sent.token])).net_sats === "40", "Second browser wallet receives sender token");
    const recovery=await call("recover");
    assert(recovery.reports.every(r => r.failed === 0 && r.skipped === 0), "Explicit recovery succeeds after recipient redeems token");
    assert((await call("list_pending_tokens")).pending.length === 0, "Recovered claimed token leaves pending list");
    const frame=document.querySelector("iframe");
    const canvas=frame?.contentDocument?.querySelector("canvas");
    assert(canvas?.width === 800 && canvas?.height === 450, "Independent Zig/raylib Wasm renderer initializes alongside wallet");
    return {ok:true,checks,count:checks.length};
  } catch (error) {
    return {ok:false,checks,count:checks.length,error:String(error.message || error)};
  } finally {
    if (second) { await second.close(); second.free(); }
    await app.close();
    // Only generated test names, never user wallet keys.
    localStorage.removeItem(`cdk_wallet_browser_v1_${name}`);
    localStorage.removeItem(`cdk_wallet_browser_v1_${secondName}`);
    seed.fill(0);
    receiverSeed.fill(0);
  }
}
