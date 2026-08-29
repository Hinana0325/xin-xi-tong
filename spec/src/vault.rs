//! # 国库
//!
//! 用户数据唯一存放地。不存在"应用数据"——
//! 服务商零持有,数据永不落盘于应用。

use crate::crypto::Hash;
use crate::lineage::{Lineage, VaultAddress};
use serde::{Deserialize, Serialize};

/// 国库库房:一个血统一间库房。
///
/// 目录形态:`<血统哈希>/`
/// - `manifest.json` — 出生令状、内容寻址清单
///
/// `mv` 这个动词不存在:地址出生即写死。
/// 用户看到的是视图("照片""上个月那个视频"),不是目录。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct VaultRoom {
    /// 血统(即库房地址)
    pub lineage: Lineage,
    /// 出生令状 ID
    pub born_of_warrant: Hash,
    /// 内容寻址清单
    pub content: Vec<ContentEntry>,
    /// 编址规则说明
    pub addressing: String,
}

/// 内容条目:名称 + 内容寻址标识。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ContentEntry {
    /// 人类可读名称
    pub name: String,
    /// 内容标识符(内容哈希)
    pub cid: Hash,
}

impl ContentEntry {
    /// 由内容条目和国库地址派生存储位置。
    ///
    /// 地址 = 内容哈希 × 血统
    pub fn address(&self, lineage: Lineage) -> VaultAddress {
        VaultAddress::derive(self.cid, lineage)
    }
}

/// 国库读视图:目的受限数据视图。
///
/// 服务向系统请求权限,不面对用户;
/// 拿到的是目的受限数据视图,处理完即焚。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct VaultView {
    /// 视图来源能力 ID
    pub capability_id: Hash,
    /// 可见的数据地址(目的受限子集)
    pub visible: Vec<VaultAddress>,
    /// 视图目的(必须与令状意图对齐)
    pub purpose: String,
    /// 即焚标记:服务处理完后视图失效
    pub ephemeral: bool,
}

/// 国库空间回收:血统不可达后的空间回收。
///
/// 删除语法:
/// 1. 吊销血统
/// 2. 派生地址不可达
/// 3. 空间回收
///
/// 账本记录不删除(只增),只回收存储空间。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SpaceReclamation {
    /// 被回收的血统
    pub lineage: Lineage,
    /// 触发令状(吊销令状)
    pub revoked_warrant: Hash,
    /// 回收的地址数
    pub addresses_reclaimed: u64,
    /// 回收时间戳
    pub timestamp: String,
}
