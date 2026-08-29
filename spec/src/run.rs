//! # 瞬态层
//!
//! 无主之地:正在进行的执行。重启即空,内容永不持久化。
//!
//! 重启在语义上是一次全网格重铸——
//! 能力全部重新铸造,而不是从盘上恢复。
//! 攻击者在持久层植入的任何东西,活不过一次断电。

use crate::capability::Capability;
use serde::{Deserialize, Serialize};

/// 服务飞地:临时沙箱,用后即焚。
///
/// 存放于 `run/enclaves/`(gitignore,重启即空)。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Enclave {
    /// 飞地 ID
    pub id: String,
    /// 来源服务
    pub service: String,
    /// 飞地类型
    pub enclave_type: String,
    /// 关联能力 ID
    pub capability_id: String,
    /// 状态
    pub state: EnclaveState,
}

/// 飞地状态。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum EnclaveState {
    /// 已启动
    Running,
    /// 已终止,数据即焚
    Destroyed,
}

/// 运行时能力令牌:已铸造的能力在瞬态层的活体。
///
/// 能力令牌从这里出生,在这里耗尽预算,在这里自毁。
/// 持久层(ledger)只记账本,不记令牌本身。
///
/// 存放于 `run/capabilities/`(gitignore,重启即空)。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RuntimeCapability {
    /// 能力令牌
    pub capability: Capability,
    /// 关联的飞地
    pub enclave_id: String,
    /// 运行状态
    pub state: RuntimeState,
}

/// 运行时状态。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum RuntimeState {
    /// 等待执行
    Pending,
    /// 执行中
    Executing,
    /// 执行完成,结果已核销入账本
    Completed,
    /// 异常终止
    Aborted,
}

/// 瞬态层:所有运行中的飞地和能力令牌。
///
/// 主权:无主(运行时由内核托管)
/// 寿命:瞬态。断电 = 全部消失,这是特性不是缺陷。
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Run {
    /// 活跃飞地
    pub enclaves: Vec<Enclave>,
    /// 活跃能力令牌
    pub capabilities: Vec<RuntimeCapability>,
}

impl Run {
    /// 重启语义:全网格重铸,一切清空。
    pub fn reboot(&mut self) {
        self.enclaves.clear();
        self.capabilities.clear();
    }
}
