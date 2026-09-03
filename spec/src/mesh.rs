//! # 联邦
//!
//! 跨设备网格:权限跟着人走,不跟着设备走。
//! 手表说的话、手机签的状、网关铸的能力,是同一条血统链的几段。

use serde::{Deserialize, Serialize};

/// 端点分级:不同设备有不同的内核完整度和确认方式。
///
/// | 端点 | 内核 | 确认方式 |
/// |---|---|---|
/// | 桌面 | 完整内核 | 全量三件套审阅 |
/// | 移动 | 内核+安全芯片 | 生物识别签名 |
/// | 穿戴 | 瘦身内核,密钥锚定手机 | 一瞥确认,预算封顶 |
/// | 物联网 | 网关持内核,端点零智能 | 常设令状+持续证明 |
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum EndpointTier {
    /// 桌面:完整内核,全量三件套审阅
    Desktop,
    /// 移动:内核+安全芯片,生物识别签名
    Mobile,
    /// 穿戴:瘦身内核,密钥锚定手机,一瞥确认,预算封顶
    Wearable,
    /// 物联网:网关持内核,端点零智能,常设令状+持续证明
    IoT,
}

impl EndpointTier {
    pub fn confirmation_method(&self) -> &str {
        match self {
            EndpointTier::Desktop => "全量三件套审阅",
            EndpointTier::Mobile => "生物识别签名",
            EndpointTier::Wearable => "一瞥确认,预算封顶",
            EndpointTier::IoT => "常设令状+持续证明",
        }
    }
}

/// 签名锚:持有硬件密钥的设备。
///
/// 存放于 `mesh/anchors/`。
/// 换手机 = 新锚凭硬件密钥接管全部常设令状。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Anchor {
    /// 锚点名称(如 "phone")
    pub anchor: String,
    /// 密钥栖所(如 "secure-enclave:ed25519")
    pub keys: String,
    /// 此锚代签的设备列表
    pub signs_for: Vec<String>,
    /// 迁移策略:硬件密钥接管常设令状
    pub migration: String,
    /// 失联降级策略
    pub loss_policy: String,
}

/// 已知设备:联邦中的端点。
///
/// 存放于 `mesh/peers/`。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Peer {
    /// 设备标识
    pub device: String,
    /// 端点角色
    pub role: PeerRole,
    /// 端点分级
    pub tier: EndpointTier,
    /// 降级预算(离线时的本地预算上限)
    pub degraded_budget: Option<DegradedBudget>,
    /// 对账策略:回连时逐环核销
    pub reconcile: String,
}

/// 端点角色。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum PeerRole {
    /// 意图入口(用户在此签发令状)
    IntentEntry,
    /// 执行端点
    Executor,
    /// 网关(为零智能端点持内核)
    Gateway,
}

/// 降级预算:锚点失联超时后的本地预算。
///
/// 离线铸造自动进入降级预算,回连逐环核销,
/// 对不上即吊销整张令状。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DegradedBudget {
    /// 金额上限(如 "20 CNY")
    pub money: String,
    /// 流量上限(如 "10 MB")
    pub data: String,
}

/// 锚点迁移记录:换设备时硬件密钥接管。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MigrationRecord {
    /// 旧锚点
    pub from_anchor: String,
    /// 新锚点
    pub to_anchor: String,
    /// 接管的常设令状数
    pub standing_warrants_taken: u64,
    /// 迁移时间戳
    pub timestamp: String,
}

/// 联邦网格:跨设备状态。
///
/// 主权:用户(签名锚持有者)
/// 寿命:随锚点迁移
#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub struct Mesh {
    /// 已知设备
    pub peers: Vec<Peer>,
    /// 签名锚
    pub anchors: Vec<Anchor>,
    /// 迁移历史
    pub migrations: Vec<MigrationRecord>,
}
