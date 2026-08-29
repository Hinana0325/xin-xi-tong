//! # 血统与编址
//!
//! 核心等式:**地址 = 内容哈希 × 血统**
//!
//! 没有人"放"东西,东西出现在它血统指向的地方。

use crate::crypto::Hash;
use serde::{Deserialize, Serialize};

/// 血统标识符。一张令状签发时即派生出血统,
/// 后续所有铸造的能力、产生的数据都继承这条血统。
///
/// 吊销血统 → 所有派生地址不可达 → 空间回收。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Lineage(pub Hash);

impl Lineage {
    /// 从令状意图哈希派出血统:lineage = H(intent_hash || "lineage")
    pub fn from_intent(intent_hash: &Hash) -> Self {
        // 实现时用 BLAKE3
        Lineage(Hash([0xa3, 0xf9, 0xc2, 0x00, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0]))
    }
}

impl std::fmt::Debug for Lineage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Lineage({})", self.0.short())
    }
}

impl std::fmt::Display for Lineage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0.short())
    }
}

/// 国库地址 = 内容哈希 × 血统。
///
/// - 同内容 + 同血统 = 同地址(自动去重)
/// - 同内容 + 异血统 = 不同地址(故意的隐私取舍:跨血统去重是侧信道)
#[derive(Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct VaultAddress {
    pub content_hash: Hash,
    pub lineage: Lineage,
}

impl VaultAddress {
    /// 地址 = H(content_hash || lineage)
    ///
    /// 同内容同血统必同地址;异血统必异地址。
    pub fn derive(content_hash: Hash, lineage: Lineage) -> Self {
        VaultAddress { content_hash, lineage }
    }
}

impl std::fmt::Debug for VaultAddress {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "vault://{}/{}", self.lineage, self.content_hash.short())
    }
}

impl std::fmt::Display for VaultAddress {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "vault://{}/{}", self.lineage, self.content_hash.short())
    }
}

/// 资源引用:统一资源定位,跨命名空间引用数据或服务。
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "scheme")]
pub enum ResourceRef {
    /// 国库数据引用
    Vault { address: VaultAddress },
    /// 服务名录引用
    Registry { service: String },
    /// 传感器引用(常设令状场景)
    Sensor { path: String },
    /// 执行器引用(常设令状场景)
    Actuator { path: String },
}

impl ResourceRef {
    pub fn vault(address: VaultAddress) -> Self {
        ResourceRef::Vault { address }
    }

    pub fn service(name: &str) -> Self {
        ResourceRef::Registry { service: name.to_string() }
    }
}

impl std::fmt::Display for ResourceRef {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ResourceRef::Vault { address } => write!(f, "{address}"),
            ResourceRef::Registry { service } => write!(f, "registry://{service}"),
            ResourceRef::Sensor { path } => write!(f, "sensor://{path}"),
            ResourceRef::Actuator { path } => write!(f, "hvac://{path}"),
        }
    }
}
