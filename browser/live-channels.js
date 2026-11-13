// Live Spilman channel coverage against the local fake mint.
//
// These are real Cashu swaps: the funding token is dispensed by /test-token
// and its proofs are used directly as channel funding inputs (never received
// into a wallet first). Cooperative close and post-expiry refund responses come
// from the running mint and the resulting proofs are redeemed into fresh
// wallets. All secrets stay in this function scope; nothing is persisted except
// by the wallet database itself.
import {open_wallet} from "./wallet/cdk_wallet_browser.js";
import {createWallet, deleteWallet} from "./test-wallet.js";

const nowSeconds = () => Math.floor(Date.now() / 1000);

export async function runLiveChannels({app, pure, text, assert}) {
  const mint = location.origin;
  const suffix = crypto.randomUUID().replaceAll("-", "");
  const names = {
    alice: `channel-alice-${suffix}`,
    charlie: `channel-charlie-${suffix}`,
    refund: `channel-refund-${suffix}`,
  };
  // Each wallet is provisioned explicitly with its own mnemonic before opening.
  const seeds = {};
  const wallets = {};
  const json = async (wallet, operation, args = []) =>
    JSON.parse(await wallet.call(operation, JSON.stringify(args)));
  const must = async (wallet, operation, args = []) => {
    const response = await json(wallet, operation, args);
    if (response.status !== 0) {
      throw new Error(`${operation} failed (status ${response.status}): ${response.error || "no error message"}`);
    }
    return response;
  };
  const newToken = () => fetch("/test-token").then(response => {
    if (!response.ok) throw new Error("Local fake mint is required for live channel tests");
    return response.json();
  });
  const sumAmounts = proofs => proofs.reduce((total, proof) => total + proof.amount, 0);

  try {
    seeds.alice = await createWallet(names.alice);
    seeds.charlie = await createWallet(names.charlie);
    wallets.alice = await open_wallet(seeds.alice, names.alice);
    wallets.charlie = await open_wallet(seeds.charlie, names.charlie);
    for (const wallet of [wallets.alice, wallets.charlie]) await must(wallet, "add_mint", [mint]);

    // The active keyset and the by-id lookup must agree before any channel is
    // built, so fixture and live material are never mixed.
    const keyset = (await must(wallets.alice, "get_active_keyset_info_json", [mint])).value;
    const keysetId = JSON.parse(keyset).keysetId;
    const byId = (await must(wallets.alice, "get_keyset_info_json", [mint, keysetId])).value;
    assert(keyset === byId, "Live active keyset matches its by-id lookup");

    const fundingAmount = await pure("spilman_compute_funding_token_amount", ["100", keyset, "64"]);
    assert(fundingAmount.status === 0 && fundingAmount.net_sats === "100", "Live funding amount covers 100 sats");

    const aliceKeys = await pure("spilman_generate_keypair");
    const charlieKeys = await pure("spilman_generate_keypair");
    const channelSecret = await text("spilman_compute_channel_secret", [aliceKeys.secret_key_hex, charlieKeys.pubkey_hex]);

    // --- Live cooperative close, 70/30 ------------------------------------
    const closeExpiry = nowSeconds() + 3600;
    const token = (await newToken()).token;
    const computed = JSON.parse(await text("spilman_compute_channel_from_token", [
      token, charlieKeys.pubkey_hex, aliceKeys.pubkey_hex, channelSecret,
      String(closeExpiry), keyset, "64",
    ]));
    assert(computed.capacity === 100, "Live token derives a 100-sat channel");

    const tokenProofs = await text("token_to_proofs_json", [token, keyset]);
    assert(
      JSON.stringify(JSON.parse(tokenProofs)) === JSON.stringify(JSON.parse(computed.proofs_json)),
      "Live token proofs match the channel's funding inputs",
    );

    const funding = JSON.parse(await text("spilman_create_funding_swap", [
      computed.params_json, channelSecret, keyset, computed.proofs_json,
    ]));
    const fundingResponse = (await must(wallets.alice, "post_swap", [mint, funding.swap_request_json])).value;
    const completed = JSON.parse(await text("spilman_complete_funding_swap", [
      fundingResponse, funding.funding_secrets_json, keyset,
    ]));
    const fundingProofs = completed.funding_proofs_json;
    const params = computed.params_json;
    assert((await pure("spilman_verify_valid_channel", [params, channelSecret, keyset, fundingProofs])).status === 0,
      "Live funded channel verifies DLEQ and proof commitments");

    const signed = JSON.parse(await text("spilman_create_signed_balance_update", [
      params, keyset, aliceKeys.secret_key_hex, fundingProofs, "70",
    ]));
    assert((await pure("spilman_verify_balance_update", [
      params, channelSecret, keyset, fundingProofs, signed.channel_id, "70", signed.signature,
    ])).status === 0, "Live channel verifies the sender's 70-sat balance update");

    const close = JSON.parse(await text("spilman_prepare_close_swap", [
      params, channelSecret, keyset, keyset, fundingProofs, "70", signed.signature, charlieKeys.secret_key_hex,
    ]));
    const closeResponse = (await must(wallets.alice, "post_swap", [mint, JSON.stringify(close.swap_request)])).value;
    const closed = await pure("spilman_unblind_close_swap", [
      params, channelSecret, keyset, keyset, JSON.stringify(close.secrets_with_blinding),
      closeResponse, "70", charlieKeys.secret_key_hex,
    ]);
    assert(closed.status === 0, "Live cooperative-close response unblinds");
    assert(closed.receiver_sum === "70" && closed.sender_sum === "30", "Live close splits 70/30");

    const receiver = await must(wallets.charlie, "receive_proofs", [mint, closed.receiver_proofs_json, null]);
    assert(receiver.net_sats === "70", "Receiver wallet redeems the live close proofs");
    const sender = await must(wallets.alice, "receive_proofs", [mint, closed.sender_proofs_json, aliceKeys.secret_key_hex]);
    assert(sender.net_sats === "30", "Sender wallet reclaims the live close remainder");

    const charlieBalance = (await must(wallets.charlie, "list_balances")).balances;
    const aliceBalance = (await must(wallets.alice, "list_balances")).balances;
    assert(charlieBalance.some(entry => entry.sats === "70"), "Live close leaves the receiver wallet with 70 sats");
    assert(aliceBalance.some(entry => entry.sats === "30"), "Live close leaves the sender wallet with 30 sats");

    // --- Live post-expiry refund -----------------------------------------
    seeds.refund = await createWallet(names.refund);
    wallets.refund = await open_wallet(seeds.refund, names.refund);
    await must(wallets.refund, "add_mint", [mint]);

    const refundToken = (await newToken()).token;
    const refundKeys = await pure("spilman_generate_keypair");
    const refundSecret = await text("spilman_compute_channel_secret", [refundKeys.secret_key_hex, charlieKeys.pubkey_hex]);
    const refundExpiry = nowSeconds() - 60;
    const refundChannel = JSON.parse(await text("spilman_compute_channel_from_token", [
      refundToken, charlieKeys.pubkey_hex, refundKeys.pubkey_hex, refundSecret,
      String(refundExpiry), keyset, "64",
    ]));
    assert(refundChannel.capacity === 100, "Expired live token derives a 100-sat channel");

    const refundFunding = JSON.parse(await text("spilman_create_funding_swap", [
      refundChannel.params_json, refundSecret, keyset, refundChannel.proofs_json,
    ]));
    const refundFundingResponse = (await must(wallets.refund, "post_swap", [mint, refundFunding.swap_request_json])).value;
    const refundCompleted = JSON.parse(await text("spilman_complete_funding_swap", [
      refundFundingResponse, refundFunding.funding_secrets_json, keyset,
    ]));
    const refundProofs = refundCompleted.funding_proofs_json;
    assert((await pure("spilman_verify_valid_channel", [
      refundChannel.params_json, refundSecret, keyset, refundProofs,
    ])).status === 0, "Expired live channel still verifies its funding");

    // At exactly the expiry timestamp the refund path stays closed.
    const boundary = await app.pure("spilman_prepare_sender_refund", [
      refundChannel.params_json, refundSecret, keyset, keyset, refundProofs,
      refundKeys.secret_key_hex, String(refundExpiry), null,
    ]);
    assert(boundary.status === 2, "Refund at exactly the live expiry is rejected");

    const refundNow = nowSeconds();
    const preparedRefund = await text("spilman_prepare_sender_refund", [
      refundChannel.params_json, refundSecret, keyset, keyset, refundProofs,
      refundKeys.secret_key_hex, String(refundNow), null,
    ]);
    const refundPreparedJson = JSON.parse(preparedRefund);
    const refundResponse = (await must(wallets.refund, "post_swap", [mint, JSON.stringify(refundPreparedJson.swap_request)])).value;
    const refunded = JSON.parse(await text("spilman_complete_sender_refund", [
      refundChannel.params_json, refundSecret, keyset, refundProofs,
      refundKeys.secret_key_hex, preparedRefund, refundResponse,
    ]));
    assert(sumAmounts(refunded) === 100, "Live post-expiry refund returns the full 100 sats");

    const refundTokenB = await text("spilman_build_cashu_b_token", [mint, "sat", JSON.stringify(refunded)]);
    const refundedReceive = await must(wallets.refund, "receive_with_keys", [refundTokenB, null]);
    assert(refundedReceive.net_sats === "100", "Refund proofs redeem into the sender wallet");

    const restored = (await must(wallets.refund, "list_balances")).balances;
    assert(restored.some(entry => entry.sats === "100"), "Refund restores the sender wallet to 100 sats");

    // Persistence and repeated explicit recovery must not change the balance.
    await wallets.refund.close();
    wallets.refund.free();
    wallets.refund = await open_wallet(seeds.refund, names.refund);
    const reopened = (await must(wallets.refund, "list_balances")).balances;
    assert(reopened.some(entry => entry.sats === "100"), "Refunded balance survives reopen and startup recovery");

    for (let run = 0; run < 2; run += 1) {
      const recovery = await must(wallets.refund, "recover");
      assert(recovery.reports.some(report => report.mint_url === mint), `Refund recovery reports the live mint (run ${run + 1})`);
      assert(recovery.reports.every(report => report.failed === 0 && report.skipped === 0),
        `Refund recovery has no failed or skipped mints (run ${run + 1})`);
      const unchanged = (await must(wallets.refund, "list_balances")).balances;
      assert(unchanged.some(entry => entry.sats === "100"), `Repeated refund recovery is unchanged (run ${run + 1})`);
    }
  } finally {
    for (const wallet of Object.values(wallets)) {
      if (!wallet) continue;
      try { await wallet.close(); } catch {}
      try { wallet.free(); } catch {}
    }
    for (const name of Object.values(names)) await deleteWallet(name);
    for (const seed of Object.values(seeds)) if (seed) seed.fill(0);
  }
}
