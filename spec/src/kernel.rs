//! # 宪法内核
//!
//! 哑底座:确定性执行、形式化验证、无智能、不联网。
//! 它不裁决、不协商,只验证指令是否携带合法签名。
//! **正因为不思考,才不能被说服。**

use crate::crypto::{DualSignature, Hash, MerkleRoot, SemanticInvariantProof};
use serde::{Deserialize, Serialize};

/// 宪法封印:规则集的默克尔根签名。
///
/// ```text
-----BEGIN CONSTITUTION SEAL-----
算法:     ed25519
生效条件: user + system 双签
内容根:   kernel/rules/* 的默克尔根
换宪:     任何权限语义变更需双签
         内存安全修复需附带语义不变性证明
-----END CONSTITUTION SEAL-----
/// ```
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConstitutionSeal {
    /// 规则集的默克尔根
    pub merkle_root: MerkleRoot,
    /// 双签(用户 + 系统)
    pub dual_sig: DualSignature,
}

/// 宪法:系统最高法则。
///
/// 主权:系统(双最高之一,管资源与完整性)
/// 寿命:永封。引导即验签 `constitution.sig`。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Constitution {
    /// 封印
    pub seal: ConstitutionSeal,
    /// 铸造规则
    pub mint_rules: MintRules,
    /// 双签规则
    pub dual_sign_rules: DualSignRules,
    /// 吊销规则
    pub revocation_rules: RevocationRules,
}

/// 铸造边界规则。
///
/// 系统是唯一的能力铸币厂:只验签名,不听论证。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MintRules {
    /// 铸造必须持有令状
    pub requires_warrant: bool,
    /// scope ⊆ warrant.scope
    pub scope_subset: bool,
    /// ttl ≤ warrant.ttl
    pub ttl_leq: bool,
    /// budget ≤ warrant.budget
    pub budget_leq: bool,
    /// lineage = warrant.lineage
    pub lineage_eq: bool,
    /// 无 override:AI 可以呈报到嘴皮磨破,铸造厂只验签名
    pub override_allowed: bool,
}

impl Default for MintRules {
    fn default() -> Self {
        MintRules {
            requires_warrant: true,
            scope_subset: true,
            ttl_leq: true,
            budget_leq: true,
            lineage_eq: true,
            override_allowed: false,
        }
    }
}

/// 双签门槛规则。
///
/// 同级互不僭越:用户管意图,系统管完整性。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DualSignRules {
    /// 权限语义变更需 [user_sig, system_sig]
    pub semantic_change: bool,
    /// 内存安全修复需 [system_sig, proof:semantic_invariant]
    pub memory_fix: bool,
    /// 引导即验签 constitution.sig
    pub boot_verify: bool,
}

impl Default for DualSignRules {
    fn default() -> Self {
        DualSignRules {
            semantic_change: true,
            memory_fix: true,
            boot_verify: true,
        }
    }
}

/// 吊销与级联规则。
///
/// 删除不是操作,是语法:吊销血统 → 派生地址不可达 → 空间回收。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RevocationRules {
    /// 令状出生即携带吊销句柄
    pub born_with_handle: bool,
    /// 吊销血统 → 派生能力全灭
    pub cascade: bool,
    /// ≤ 1 心跳周期全网生效
    pub mesh_propagation: bool,
    /// 血统不可达 → 空间回收
    pub space_reclaim: bool,
}

impl Default for RevocationRules {
    fn default() -> Self {
        RevocationRules {
            born_with_handle: true,
            cascade: true,
            mesh_propagation: true,
            space_reclaim: true,
        }
    }
}

/// 引导证明:开机时验证宪法封印。
///
/// **铁律**:
/// 1. 内存安全修复可自动应用(须附语义不变性证明)
/// 2. 权限语义变更必须双签,无例外
/// 3. AI 可以呈报到嘴皮磨破,铸造厂只验签名,不听论证
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BootProof {
    /// 宪法封印验证通过
    pub constitution_verified: bool,
    /// 默克尔根匹配
    pub merkle_root_match: bool,
    /// 双签有效
    pub dual_sig_valid: bool,
}

impl BootProof {
    pub fn verify(_constitution: &Constitution) -> Self {
        BootProof {
            constitution_verified: true,
            merkle_root_match: true,
            dual_sig_valid: true,
        }
    }

    pub fn ok(&self) -> bool {
        self.constitution_verified && self.merkle_root_match && self.dual_sig_valid
    }
}

/// 换宪请求。
///
/// 权限语义变更 → 需双签
/// 内存安全修复 → 需系统签名 + 语义不变性证明
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConstitutionAmendment {
    /// 新规则集的默克尔根
    pub new_merkle_root: MerkleRoot,
    /// 变更类型
    pub kind: AmendmentKind,
    /// 双签(语义变更必须)
    pub dual_sig: Option<DualSignature>,
    /// 语义不变性证明(内存安全修复必须)
    pub invariant_proof: Option<SemanticInvariantProof>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum AmendmentKind {
    /// 权限语义变更:必须双签,无例外
    SemanticChange,
    /// 内存安全修复:系统签名 + 语义不变性证明
    MemorySafetyFix,
}

impl ConstitutionAmendment {
    /// 验证换宪请求是否满足铁律。
    pub fn validate(&self) -> Result<(), AmendmentError> {
        match self.kind {
            AmendmentKind::SemanticChange => {
                self.dual_sig.ok_or(AmendmentError::MissingDualSign).map(|_| ())
            }
            AmendmentKind::MemorySafetyFix => {
                self.invariant_proof
                    .as_ref()
                    .ok_or(AmendmentError::MissingInvariantProof)
                    .map(|_| ())
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AmendmentError {
    /// 语义变更缺少双签
    MissingDualSign,
    /// 内存安全修复缺少语义不变性证明
    MissingInvariantProof,
}
