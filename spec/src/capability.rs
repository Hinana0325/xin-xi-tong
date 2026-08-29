//! # 能力令牌
//!
//! 令状是意图,能力是执行权。系统是唯一的能力铸币厂:
//! 只验签名,不听论证。

use crate::crypto::Hash;
use crate::lineage::Lineage;
use crate::warrant::{WarrantBudget, WarrantScope};
use serde::{Deserialize, Serialize};

/// 能力令牌:从令状铸造出的执行权。
///
/// 存放于 `run/capabilities/`(瞬态层,重启即空)。
/// 持久层(ledger)只记账本,不记令牌本身。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Capability {
    /// 能力 ID = H(warrant_id || scope || budget || ttl)
    pub id: Hash,
    /// 来源令状 ID
    pub warrant_id: Hash,
    /// 范围(⊆ warrant.scope)
    pub scope: WarrantScope,
    /// 预算(≤ warrant.budget)
    pub budget: WarrantBudget,
    /// 时限(≤ warrant.ttl)
    pub ttl_seconds: u64,
    /// 血统(= warrant.lineage,不可变)
    pub lineage: Lineage,
    /// 当前状态
    pub state: CapabilityState,
    /// 已消耗预算
    pub consumed: BudgetConsumption,
}

/// 能力状态机:
///
/// ```text
/// Minted → Active → Exhausted    (预算耗尽)
///        ↘        ↘ Expired      (TTL 到点)
///        ↘        ↘ Revoked     (血统被吊销)
/// ```
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum CapabilityState {
    /// 刚铸造,尚未激活
    Minted,
    /// 正在执行
    Active,
    /// 预算耗尽,自毁
    Exhausted,
    /// TTL 到点,自毁
    Expired,
    /// 血统被吊销,级联销毁
    Revoked,
}

impl CapabilityState {
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            CapabilityState::Exhausted | CapabilityState::Expired | CapabilityState::Revoked
        )
    }
}

/// 预算消耗追踪。
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct BudgetConsumption {
    pub tokens_used: u64,
    pub egress_mb_used: f64,
    pub writes_count: u64,
}

impl BudgetConsumption {
    /// 检查是否超出令状预算。
    pub fn exceeds(&self, budget: &WarrantBudget) -> bool {
        if let Some(limit) = budget.tokens {
            if self.tokens_used >= limit {
                return true;
            }
        }
        if let Some(limit) = budget.egress_mb {
            if self.egress_mb_used >= limit as f64 {
                return true;
            }
        }
        if let Some(limit) = budget.writes_per_hour {
            if self.writes_count >= limit {
                return true;
            }
        }
        false
    }
}

/// 铸造请求:从令状派生能力。
///
/// 铸造时系统(铸币厂)验证:
/// 1. 令状签名合法且状态为 Live
/// 2. capability.scope ⊆ warrant.scope
/// 3. capability.ttl ≤ warrant.ttl
/// 4. capability.budget ≤ warrant.budget
/// 5. capability.lineage = warrant.lineage
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MintRequest {
    pub warrant_id: Hash,
    pub scope: WarrantScope,
    pub budget: WarrantBudget,
    pub ttl_seconds: u64,
}

/// 铸造结果。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum MintResult {
    /// 铸造成功
    Minted(Capability),
    /// 铸造失败:违反边界规则
    Rejected(MintRejection),
}

/// 铸造拒绝原因。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum MintRejection {
    /// 令状不存在或已终态
    WarrantInvalid,
    /// 范围越界:capability.scope ⊄ warrant.scope
    ScopeExceeds,
    /// 时限越界:capability.ttl > warrant.ttl
    TtlExceeds,
    /// 预算越界:capability.budget > warrant.budget
    BudgetExceeds,
    /// 无 override:铸币厂只验签名,不听论证
    NoOverride,
}

/// 铸造边界验证器。
///
/// **mint.rules** 的 Rust 体现:
/// ```text
/// rule mint.scope      "capability.scope ⊆ warrant.scope"
/// rule mint.ttl        "capability.ttl ≤ warrant.ttl"
/// rule mint.budget     "capability.budget ≤ warrant.budget"
/// rule mint.lineage    "capability.lineage = warrant.lineage"
/// rule mint.override   none
/// ```
pub fn verify_mint(req: &MintRequest, warrant_scope: &WarrantScope, warrant_budget: &WarrantBudget, warrant_ttl: u64) -> Result<(), MintRejection> {
    // scope ⊆
    if !scope_is_subset(&req.scope, warrant_scope) {
        return Err(MintRejection::ScopeExceeds);
    }
    // ttl ≤
    if req.ttl_seconds > warrant_ttl {
        return Err(MintRejection::TtlExceeds);
    }
    // budget ≤
    if budget_exceeds(&req.budget, warrant_budget) {
        return Err(MintRejection::BudgetExceeds);
    }
    Ok(())
}

fn scope_is_subset(cap: &WarrantScope, warrant: &WarrantScope) -> bool {
    cap.data.iter().all(|d| warrant.data.contains(d))
        && cap.services.iter().all(|s| warrant.services.contains(s))
        && cap.actuators.iter().all(|a| warrant.actuators.contains(a))
}

fn budget_exceeds(cap: &WarrantBudget, warrant: &WarrantBudget) -> bool {
    if let (Some(c), Some(w)) = (cap.tokens, warrant.tokens) {
        if c > w { return true; }
    } else if cap.tokens.is_some() && warrant.tokens.is_none() {
        return true;
    }
    if let (Some(c), Some(w)) = (cap.egress_mb, warrant.egress_mb) {
        if c > w { return true; }
    } else if cap.egress_mb.is_some() && warrant.egress_mb.is_none() {
        return true;
    }
    if let (Some(c), Some(w)) = (cap.writes_per_hour, warrant.writes_per_hour) {
        if c > w { return true; }
    } else if cap.writes_per_hour.is_some() && warrant.writes_per_hour.is_none() {
        return true;
    }
    false
}
