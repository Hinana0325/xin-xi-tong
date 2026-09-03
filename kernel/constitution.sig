# 功能: 宪法封印 — 内核规则集 kernel/rules/* 的默克尔根签名
# 作用: 引导时验签防篡改;换宪(权限语义变更)须用户+系统双签
-----BEGIN CONSTITUTION SEAL-----
PLACEHOLDER — 此处为宪法内核的默克尔根签名

算法:     ed25519
生效条件: user + system 双签
内容根:   kernel/rules/* 的默克尔根
换宪:     任何权限语义变更需双签,内存安全修复
         需附带语义不变性形式化证明
-----END CONSTITUTION SEAL-----
