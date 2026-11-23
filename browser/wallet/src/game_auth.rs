//! Browser game identity. Neither the wallet seed nor the derived key is sent
//! to the JavaScript bridge or written as a separate credential.
use cdk_common::bitcoin::secp256k1::{Keypair, Message, PublicKey, Secp256k1, SecretKey};
use hkdf::Hkdf;
use sha2::{Digest, Sha256};
use wasm_bindgen::prelude::*;
use zeroize::Zeroizing;

#[wasm_bindgen]
pub struct GameSigner {
    key: Zeroizing<[u8; 32]>,
}

impl GameSigner {
    pub(crate) fn derive(seed: &[u8; 64]) -> Option<Self> {
        let kdf = Hkdf::<Sha256>::new(Some(b"haystack/wallet-key/v1"), seed);
        let mut key = Zeroizing::new([0u8; 32]);
        for counter in 0..=u32::MAX {
            kdf.expand_multi_info(
                &[b"haystack/ws-auth/secp256k1/v1", &counter.to_be_bytes()],
                &mut *key,
            )
            .ok()?;
            if let Ok(mut candidate) = SecretKey::from_slice(&*key) {
                candidate.non_secure_erase();
                return Some(Self { key });
            }
        }
        None
    }

    #[cfg(target_arch = "wasm32")]
    pub(crate) fn signing_key(&self) -> Option<cdk::nuts::SecretKey> {
        use zeroize::Zeroizing;
        let hex = Zeroizing::new(cdk::util::hex::encode(*self.key));
        cdk::nuts::SecretKey::from_hex(&hex).ok()
    }

    #[cfg(target_arch = "wasm32")]
    pub(crate) fn channel_keys(&self, receiver: &str) -> Option<(String, Zeroizing<String>)> {
        let key = self.signing_key()?;
        let hex = Zeroizing::new(key.to_secret_hex());
        let secret = cdk_spilman::compute_channel_secret_from_hex(&hex, receiver).ok()?;
        Some((key.public_key().to_hex(), Zeroizing::new(secret)))
    }

    fn proof(&self, nonce: &[u8; 32], aux: &[u8; 32]) -> Option<[u8; 97]> {
        let secp = Secp256k1::new();
        let mut key = SecretKey::from_slice(&*self.key).ok()?;
        let mut pair = Keypair::from_secret_key(&secp, &key);
        key.non_secure_erase();
        let digest = Sha256::new()
            .chain_update(b"haystack/ws-auth/v1")
            .chain_update(nonce)
            .finalize();
        let signature =
            secp.sign_schnorr_with_aux_rand(&Message::from_digest(digest.into()), &pair, aux);
        let public = PublicKey::from_keypair(&pair).serialize();
        pair.non_secure_erase();
        let mut proof = [0u8; 97];
        proof[..33].copy_from_slice(&public);
        proof[33..].copy_from_slice(signature.as_ref());
        Some(proof)
    }
}

#[wasm_bindgen]
impl GameSigner {
    pub fn sign(&self, nonce: &[u8], aux: &[u8]) -> Option<Vec<u8>> {
        self.proof(nonce.try_into().ok()?, aux.try_into().ok()?)
            .map(|proof| proof.to_vec())
    }
}

#[test]
fn game_identity_matches_desktop() {
    use std::str::FromStr;
    let signer = GameSigner::derive(&[1; 64]).unwrap();
    let proof = signer.proof(&[7; 32], &[8; 32]).unwrap();
    let expected =
        PublicKey::from_str("020d82abed9ad0b47627a01df67bd14cdfb824669562b37b967c9b58181436eb87")
            .unwrap();
    assert_eq!(&proof[..33], &expected.serialize());
    let signature =
        cdk_common::bitcoin::secp256k1::schnorr::Signature::from_slice(&proof[33..]).unwrap();
    let digest = Sha256::digest([b"haystack/ws-auth/v1".as_slice(), &[7; 32]].concat());
    Secp256k1::verification_only()
        .verify_schnorr(
            &signature,
            &Message::from_digest(digest.into()),
            &expected.x_only_public_key().0,
        )
        .unwrap();
}
