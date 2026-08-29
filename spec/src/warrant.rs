//! # 令状
//!
//! 权限的原子单位不是身份,是**被签发的一次意图**。
//! 没有令状,系统拒绝铸造,服务拿不到能力,AI 寝步难行。

use crate::crypto::{Hash, Signature};
use crate::lineage::{Lineage, ResourceRef};
use serde::{Deserialize, Serialize};

/// 令状类型:一次性意图 vs 持续性意图。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum WarrantType {
    /// 活跃令状:一次性意图,TTL 到点自毁。
    /// 存放于 `warrant/live/`。
    Live,
    /// 常设令状:持续性意图(如物联网控制)。
    /// 存放于 `warrant/standing/`。
    /// 须持续证明存活(心跳),心跳断则降级。
    Standing,
}

/// 令状四属性之一:范围。
/// 能碰哪些数据、哪些服务、哪些执行器。
///
/// **铁律**:意图必须可枚举(数据·服务·预算三件套)。
/// 终值不可入状:"延续文明""最大化幸福"永远不能成为令状内容。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WarrantScope {
    /// 可触碰的数据资源(国库地址或传感器路径)
    pub data: Vec<ResourceRef>,
    /// 可调用的服务(名录引用)
    pub services: Vec<ResourceRef>,
    /// 可驱动的执行器(常设令状场景)
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub actuators: Vec<ResourceRef>,
}

/// 令状四属性之一:预算。
/// 次数/流量/算力额度,耗尽即止。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WarrantBudget {
    /// AI 调用 token 额度
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens: Option<u64>,
    /// 出站流量上限(MB)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub egress_mb: Option<u64>,
    /// 写入频率上限(次/小时,常设令状场景)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub writes_per_hour: Option<u64>,
}

/// 令状四属性之一:时限。
/// 到点自毁,不可延期(需重新签发新令状)。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WarrantTtl {
    /// 存活秒数(Live 令状)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seconds: Option<u64>,
    /// 绝对过期时间(Standing 令状)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expiry: Option<String>,
    /// 心跳证明(仅 Standing)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proof: Option<HeartbeatProof>,
}

/// 常设令状的持续存活证明。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct HeartbeatProof {
    /// 心跳间隔(分钟)
    pub interval_min: u16,
}

/// 令状四属性之一:吊销句柄。
/// 级联全网生效:吊销血统 → 派生能力全灭 → 派生地址不可达。
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct RevocationHandle(pub Hash);

/// 令状状态机:
///
/// ```text
/// Drafted → Signed → Live → Redeemed    (正常核销)
///                  ↘      ↘ Expired     (TTL 到点)
///                  ↘      ↘ Revoked     (用户吊销)
/// ```
///
/// **不可逆**:一旦 Expired/Redeemed/Revoked 终态不可回退。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum WarrantState {
    /// 草拟:AI 呈报计划,尚未签名
    Drafted,
    /// 已签名:用户硬件密钥签名完成
    Signed,
    /// 活跃:已铸造能力,正在执行
    Live,
    /// 已核销:任务完成,能力已焚毁
    Redeemed,
    /// 已过期:TTL 到点自毁
    Expired,
    /// 已吊销:用户吊销,血统级联全灭
    Revoked,
}

impl WarrantState {
    pub fn is_terminal(&self) -> bool {
        matches!(self, WarrantState::Redeemed | WarrantState::Expired | WarrantState::Revoked)
    }

    pub fn is_active(&self) -> bool {
        matches!(self, WarrantState::Live)
    }
}

/// 计划摘要:数据清单 · 服务清单 · 预算上限 三件套。
///
/// AI 呈报的执行计划经用户审阅后,其摘要写入令状。
/// 令状签发后,AI 只能在此计划范围内行动。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PlanDigest(pub Hash);

/// 一张令状:被签发的一次意图。
///
/// 这是整个系统的权限原子。所有能力铸造、数据访问、
/// 服务调用都必须追溯到一张合法签名的令状。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Warrant {
    /// 令状 ID = H(intent || scope || budget || ttl || handle)
    pub id: Hash,
    /// 令状类型
    pub warrant_type: WarrantType,
    /// 意图描述(人类可读,但必须可枚举)
    pub intent: String,
    /// 意图哈希
    pub intent_hash: Hash,
    /// 计划摘要(三件套的哈希)
    pub plan_digest: PlanDigest,
    /// 四属性:范围
    pub scope: WarrantScope,
    /// 四属性:预算
    pub budget: WarrantBudget,
    /// 四属性:时限
    pub ttl: WarrantTtl,
    /// 四属性:吊销句柄
    pub revocation_handle: RevocationHandle,
    /// 派生的血统
    pub lineage: Lineage,
    /// 当前状态
    pub state: WarrantState,
    /// 用户硬件密钥签名(非口令)
    pub user_sig: Signature,
}

impl Warrant {
    /// 验证令状四属性的完备性。
    ///
    /// **铁律**:不可枚举的意图不能入状。
    pub fn validate(&self) -> Result<(), WarrantError> {
        if self.intent.is_empty() {
            return Err(WarrantError::EmptyIntent);
        }
        if self.scope.data.is_empty() && self.scope.services.is_empty() && self.scope.actuators.is_empty() {
            return Err(WarrantError::EmptyScope);
        }
        if self.budget.tokens.is_none()
            && self.budget.egress_mb.is_none()
            && self.budget.writes_per_hour.is_none()
        {
            return Err(WarrantError::EmptyBudget);
        }
        match self.warrant_type {
            WarrantType::Live => {
                if self.ttl.seconds.is_none() {
                    return Err(WarrantError::LiveMissingTtl);
                }
            }
            WarrantType::Standing => {
                if self.ttl.expiry.is_none() || self.ttl.proof.is_none() {
                    return Err(WarrantError::StandingMissingExpiryOrProof);
                }
            }
        }
        Ok(())
    }
}

/// 令状校验错误。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WarrantError {
    /// 意图为空
    EmptyIntent,
    /// 范围为空(必须至少有一项数据/服务/执行器)
    EmptyScope,
    /// 预算为空(必须至少有一项额度)
    EmptyBudget,
    /// Live 令状缺少 TTL 秒数
    LiveMissingTtl,
    /// Standing 令状缺少过期时间或心跳证明
    StandingMissingExpiryOrProof,
}
