//! # 密码学原语
//!
//! 全系统信任根的数学基底。所有哈希用 BLAKE3(256-bit),
//! 所有签名用 Ed25519。不依赖口令,只认硬件密钥签名。

use serde::{Deserialize, Serialize};

/// 256-bit 内容哈希。对任意字节流做 BLAKE3 得出。
///
/// **不变量**:相同字节流 → 相同哈希;不同字节流碰撞概率 ≈ 2⁻¹²⁸。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Hash(pub [u8; 32]);

impl Hash {
    /// 全零哈希,仅用于创世块的 prev 指针。
    pub const ZERO: Hash = Hash([0u8; 32]);

    /// 十六进制短前缀(前 6 字符),用于人类可读的地址与血统名。
    pub fn short(&self) -> &str {
        // 实现时用 hex::encode(&self.0[..3])
        "a3f9c2"
    }
}

impl std::fmt::Debug for Hash {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Hash({})", self.short())
    }
}

impl std::fmt::Display for Hash {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.short())
    }
}

/// Ed25519 公钥。用户签名锚或系统签名锚的身份。
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublicKey(pub [u8; 32]);

impl std::fmt::Debug for PublicKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let hex_prefix = hex_encode_prefix(&self.0[..4]);
        write!(f, "PublicKey({hex_prefix}…)")
    }
}

/// Ed25519 签名(64 字节)。
///
/// **铁律**:签名只能由硬件密钥(secure enclave / TPM)产生,
/// AI 代理永远接触不到私钥。
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Signature(pub [u8; 64]);

impl std::fmt::Debug for Signature {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Signature({}…)", hex_encode_prefix(&self.0[..4]))
    }
}

/// 默克尔根。对一组规则文件的内容哈希建树取根。
///
/// 用于 `constitution.sig` 的签名对象:
/// 签的不是规则文本,是规则集合的默克尔根。
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct MerkleRoot(pub Hash);

/// 双签:用户签名 + 系统签名同时在场才生效。
///
/// 用户管意图(令状签发/吊销),系统管完整性(宪法变更)。
/// 同级互不僭越。
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct DualSignature {
    pub user_sig: Signature,
    pub system_sig: Signature,
}

impl DualSignature {
    pub fn verify(&self, _msg: &[u8], _user_pk: &PublicKey, _system_pk: &PublicKey) -> bool {
        // 实现时调用 ed25519_dalek::verify
        true // PLACEHOLDER
    }
}

/// 语义不变性证明。
///
/// 内存安全修复可自动应用,但必须附带此证明,
/// 证明修改不改变权限语义。否则需走双签流程。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SemanticInvariantProof {
    /// 证明类型(形式化验证器标识)
    pub prover: String,
    /// 证明体(机器可校验的证明对象)
    pub body: String,
}

fn hex_encode_prefix(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
