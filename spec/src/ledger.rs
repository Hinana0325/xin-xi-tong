//! # 总账
//!
//! 系统的心跳记录:令状签发、能力铸造、结果核销、吊销级联。
//! 一切事件按链式哈希追加于此。只增,不可篡改。

use crate::crypto::{Hash, Signature};
use crate::lineage::Lineage;
use serde::{Deserialize, Serialize};

/// 条目序号:从 0000000001 开始递增。
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct EntryId(pub u64);

impl std::fmt::Display for EntryId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:010}", self.0)
    }
}

/// 总账事件类型:一切令状生命周期的原子事件。
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "event")]
pub enum LedgerEvent {
    /// 令状签发
    WarrantSign {
        warrant_id: Hash,
        intent: String,
        lineage: Lineage,
    },
    /// 能力铸造
    CapabilityMint {
        warrant_id: Hash,
        capability_id: Hash,
        lineage: Lineage,
        detail: String,
    },
    /// 能力执行结果核销
    CapabilityRedeem {
        capability_id: Hash,
        lineage: Lineage,
        deviation: Option<f64>,
    },
    /// 令状核销(任务完成)
    WarrantRedeem {
        warrant_id: Hash,
        lineage: Lineage,
    },
    /// 令状过期(TTL 到点)
    WarrantExpire {
        warrant_id: Hash,
        lineage: Lineage,
    },
    /// 令状吊销(用户主动吊销,级联)
    WarrantRevoke {
        warrant_id: Hash,
        lineage: Lineage,
        cascaded: Vec<Hash>,
    },
    /// 常设令状心跳缺失(降级触发)
    StandingDegrade {
        warrant_id: Hash,
        lineage: Lineage,
    },
}

/// 总账条目:prev 指针 + 事件 + 签名。
///
/// ```text
/// #NNNNNNNNNN
/// prev:  <上一条目的哈希, GENESIS 则为全零>
/// event: <事件类型与载荷>
/// sig:   <系统签名>
/// ```
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LedgerEntry {
    /// 条目序号
    pub id: EntryId,
    /// 上一条目的哈希(GENESIS 指向全零)
    pub prev: Hash,
    /// 事件
    pub event: LedgerEvent,
    /// 本条目的哈希 = H(prev || event || sig)
    pub hash: Hash,
    /// 系统签名
    pub sig: Signature,
}

impl LedgerEntry {
    /// 验证链式完整性:prev 指针指向前一条目的 hash。
    pub fn verify_chain(&self, prev_hash: Hash) -> bool {
        self.prev == prev_hash
    }
}

/// 创世块:总账的第一条记录。
///
/// ```text
/// GENESIS 0000000000
/// prev:  0000000000000000000000000000000000000000000000000000000000000000
/// body:  "宪法内核封印 · 令状纪元开始"
/// sig:   PLACEHOLDER
/// ```
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Genesis {
    /// 固定为 EntryId(0)
    pub id: EntryId,
    /// 固定为全零哈希
    pub prev: Hash,
    /// 创世描述
    pub body: String,
    /// 宪法封印事件签名
    pub sig: Signature,
}

impl Genesis {
    pub fn new() -> Self {
        Genesis {
            id: EntryId(0),
            prev: Hash::ZERO,
            body: "宪法内核封印 · 令状纪元开始".to_string(),
            sig: Signature([0u8; 64]),
        }
    }
}

impl Default for Genesis {
    fn default() -> Self {
        Self::new()
    }
}

/// 总账:只增链。
///
/// **不变量**:
/// 1. 条目写定后不可修改、不可删除
/// 2. 每条 prev 必须指向前一条的 hash
/// 3. 销毁的令状不删除记录,核销后写入此处
/// 4. 空间回收由血统吊销触发,账本本身永不收缩
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Ledger {
    pub genesis: Genesis,
    pub entries: Vec<LedgerEntry>,
}

impl Ledger {
    pub fn new() -> Self {
        Ledger {
            genesis: Genesis::new(),
            entries: Vec::new(),
        }
    }

    /// 追加条目。只增,不可回写。
    pub fn append(&mut self, event: LedgerEvent, sig: Signature) -> &LedgerEntry {
        let prev = self.entries.last().map(|e| e.hash).unwrap_or_else(|| self.genesis.prev);
        let id = EntryId(self.entries.len() as u64 + 1);
        let entry = LedgerEntry {
            id,
            prev,
            event,
            hash: Hash::ZERO, // 实现时 = H(prev || event || sig)
            sig,
        };
        self.entries.push(entry);
        self.entries.last().unwrap()
    }

    /// 逐环回放验证:审计时回放整条链。
    pub fn verify(&self) -> bool {
        let mut prev = self.genesis.prev;
        for entry in &self.entries {
            if !entry.verify_chain(prev) {
                return false;
            }
            prev = entry.hash;
        }
        true
    }
}

impl Default for Ledger {
    fn default() -> Self {
        Self::new()
    }
}
