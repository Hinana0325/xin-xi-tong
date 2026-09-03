//! # 服务名录
//!
//! 软件不安装,只注册。能力按需召唤,代码内容寻址。
//!
//! | 传统 | 本系统 |
//! |---|---|
//! | 安装 = 复制进 /usr /opt | 注册 = 挂一条 manifest |
//! | 卸载残留 AppData | 类别消亡,无残留 |
//! | 权限随 App 永久持有 | 能力寿命 = 意图寿命 |

use serde::{Deserialize, Serialize};

/// 飞地类型:服务运行的安全沙箱类型。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum EnclaveType {
    /// AMD SEV-SNP
    TeeSev,
    /// Intel TDX
    TeeTdx,
    /// ARM CCA
    TeeCca,
    /// 本地沙箱(无硬件飞地)
    Sandbox,
}

impl std::fmt::Display for EnclaveType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EnclaveType::TeeSev => write!(f, "tee:sev"),
            EnclaveType::TeeTdx => write!(f, "tee:tdx"),
            EnclaveType::TeeCca => write!(f, "tee:cca"),
            EnclaveType::Sandbox => write!(f, "sandbox"),
        }
    }
}

/// 服务清单:注册一条 manifest,零字节落盘。
///
/// 服务向系统请求权限,不面对用户;
/// 拿到的是目的受限数据视图,处理完即焚。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ServiceManifest {
    /// 服务名称
    pub service: String,
    /// 厂商签名
    pub vendor: String,
    /// 声明的能力(如 ["ffmpeg:encode"])
    pub capabilities: Vec<String>,
    /// 飞地类型
    pub enclave: EnclaveType,
    /// 有状态性:none(无状态,处理完即焚)
    pub statefulness: ServiceStatefulness,
    /// 数据视图:目的受限,合约范围
    pub data_view: String,
    /// 计费方式
    pub billing: BillingMethod,
}

/// 服务有状态性。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ServiceStatefulness {
    /// 无状态:处理完即焚
    None,
    /// 会话级:令状存活期间
    Session,
}

/// 计费方式。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum BillingMethod {
    /// 按秒计费
    PerSecond,
    /// 按次计费
    PerCall,
    /// 按流量计费
    PerMB,
    /// 按算力计费
    PerFlop,
}

impl std::fmt::Display for BillingMethod {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BillingMethod::PerSecond => write!(f, "per-second"),
            BillingMethod::PerCall => write!(f, "per-call"),
            BillingMethod::PerMB => write!(f, "per-mb"),
            BillingMethod::PerFlop => write!(f, "per-flop"),
        }
    }
}

/// 服务名录:已注册的服务集合。
///
/// 主权:公共(名录开放,准入验签)
/// 寿命:可重建。名录丢了从网络重取即可。
///
/// `cache/` — 内容寻址的代码缓存(已 gitignore,可随时清空重建)
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Registry {
    /// 已注册清单
    pub manifests: Vec<ServiceManifest>,
}

impl Registry {
    /// 注册一个服务:挂一条 manifest,零字节落盘。
    pub fn register(&mut self, manifest: ServiceManifest) {
        self.manifests.push(manifest);
    }

    /// 按名称查找
    pub fn find(&self, name: &str) -> Option<&ServiceManifest> {
        self.manifests.iter().find(|m| m.service == name)
    }
}
