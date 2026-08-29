# spec/ — 类型即规格

WARRANT OS 八个命名空间的形式化 Rust 类型定义。

**编译通过 ≡ 规格自洽。** 这不是实现,是合约。

## 构建

```bash
cargo check
```

## 模块与命名空间映射

| 模块 | 命名空间 | 核心类型 |
|---|---|---|
| `crypto` | (信任根) | `Hash`, `Signature`, `DualSignature`, `MerkleRoot` |
| `lineage` | (编址层) | `Lineage`, `VaultAddress`, `ResourceRef` |
| `warrant` | `warrant/` | `Warrant`, `WarrantType`, `WarrantScope`, `WarrantBudget` |
| `capability` | `run/capabilities/` | `Capability`, `MintRequest`, `MintResult` |
| `ledger` | `ledger/` | `LedgerEntry`, `LedgerEvent`, `Genesis`, `Ledger` |
| `kernel` | `kernel/` | `Constitution`, `ConstitutionSeal`, `BootProof` |
| `vault` | `vault/` | `VaultRoom`, `ContentEntry`, `VaultView` |
| `mesh` | `mesh/` | `Anchor`, `Peer`, `EndpointTier`, `Mesh` |
| `registry` | `registry/` | `ServiceManifest`, `EnclaveType`, `Registry` |
| `run` | `run/` | `Enclave`, `RuntimeCapability`, `Run` |
| `mind` | `mind/` | `AgentIdentity`, `SessionContext`, `ProposedPlan` |

## 核心等式

```
地址 = 内容哈希 × 血统
权限根 = 意图(令状), 非身份
整机状态 = kernel + ledger + vault + mind + warrant/standing
```
