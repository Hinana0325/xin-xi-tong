//! # WARRANT OS — 类型即规格
//!
//! 八个顶级命名空间的形式化定义。每个模块的 Rust 类型即是该命名空间
//! 的不变量合约:编译通过 ≡ 规格自洽。
//!
//! ## 重启不变量
//!
//! ```text
//! 整机状态 = kernel + ledger + vault + mind + warrant/standing
//! ```
//!
//! 其余全部可重建。重启语义上是一次全网格重铸。
//!
//! ## 构建
//!
//! ```bash
//! cargo check   # 编译通过 ≡ 规格自洽
//! ```

pub mod crypto;
pub mod lineage;
pub mod warrant;
pub mod capability;
pub mod ledger;
pub mod kernel;
pub mod vault;
pub mod mesh;
pub mod registry;
pub mod run;
pub mod mind;

pub use crypto::*;
pub use lineage::*;
pub use warrant::*;
pub use capability::*;
pub use ledger::*;
pub use kernel::*;
pub use vault::*;
pub use mesh::*;
pub use registry::*;
pub use run::*;
pub use mind::*;
