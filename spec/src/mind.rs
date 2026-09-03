//! # 代理记忆
//!
//! AI 执行代理的本体:本地模型、上下文、会话记忆。
//! 翻译官 + 图书管理员,受托而非主权持有者。
//!
//! **铁律**:
//! 1. 核心策略模型必须本地运行——跑在云端,"系统"就归属厂商
//! 2. AI 只能呈报计划,骗不出硬件密钥里的用户签名
//! 3. 无令状则无行动能力:结构保证服从,而非对齐训练

use crate::crypto::Hash;
use serde::{Deserialize, Serialize};

/// 代理身份与角色声明。
///
/// ```json
/// {
///   "agent": "executor",
///   "role": "翻译官 + 图书管理员",
///   "obeys": "warrant only",
///   "sovereignty": "none",
///   "memory": ["context/"],
///   "replaceable": true
/// }
/// ```
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AgentIdentity {
    /// 代理类型(执行器)
    pub agent: String,
    /// 角色(翻译官 + 图书管理员)
    pub role: String,
    /// 服从对象:仅令状
    pub obeys: String,
    /// 主权:无
    pub sovereignty: String,
    /// 记忆路径
    pub memory: Vec<String>,
    /// 可整体更换
    pub replaceable: bool,
}

impl Default for AgentIdentity {
    fn default() -> Self {
        AgentIdentity {
            agent: "executor".to_string(),
            role: "翻译官 + 图书管理员".to_string(),
            obeys: "warrant only".to_string(),
            sovereignty: "none".to_string(),
            memory: vec!["context/".to_string()],
            replaceable: true,
        }
    }
}

/// 会话上下文:意图解释的临时记忆。
///
/// 存放于 `mind/context/`。
/// 换 AI = 换 /mind,数据在 /vault 不动。
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct SessionContext {
    /// 最近意图
    pub last_intent: Option<String>,
    /// 待处理计划数
    pub pending_plans: u32,
    /// 上下文窗口(对话历史摘要)
    pub context_window: Vec<ContextTurn>,
}

/// 一轮对话上下文。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ContextTurn {
    /// 轮次角色
    pub role: TurnRole,
    /// 内容摘要
    pub digest: Hash,
}

/// 轮次角色。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum TurnRole {
    /// 用户
    User,
    /// 代理
    Agent,
    /// 系统(铸造厂/账本)
    System,
}

/// AI 呈报的计划:数据清单 · 服务清单 · 预算上限三件套。
///
/// AI 只能呈报,不能自行执行。
/// 计划经用户审阅签名后成为令状。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProposedPlan {
    /// 意图描述(可枚举)
    pub intent: String,
    /// 数据清单
    pub data_refs: Vec<String>,
    /// 服务清单
    pub service_refs: Vec<String>,
    /// 预算上限
    pub budget_estimate: BudgetEstimate,
    /// 预计耗时
    pub estimated_ttl: u64,
}

/// 预算估算。
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct BudgetEstimate {
    pub tokens: Option<u64>,
    pub egress_mb: Option<u64>,
}
