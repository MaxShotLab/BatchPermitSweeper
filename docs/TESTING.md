# 测试与验证范围

## 已执行的初始化验证

2026-09-29，代码提交 `4265620e0daad0955d4a0454634b620d30f9e135` 在 GitHub Actions 完成：

| 验证 | 结果 |
| --- | --- |
| Solidity 0.8.37 / Cancun 编译与大小检查 | 通过；Sweeper runtime 7,609 bytes |
| 合约测试 | 68 项通过，0 失败，0 跳过（不包含 opt-in fork 文件） |
| 模糊测试 | 单项余额守恒属性运行 1,024 次 |
| 状态不变量 | 2 项，各 256 轮 / 16,384 次 handler 调用，无意外回滚 |
| Python 部署工具测试 | 12 项通过 |
| Shell 语法检查 | 通过 |
| Anvil 部署与交接 | 通过 |

证据：[CI run 36516711234](https://github.com/MaxShotLab/BatchPermitSweeper/actions/runs/36516711234)。后续提交以对应 CI 结果为准，不能把历史测试结果自动归给后来修改的代码。

Anvil 演练实际广播了本地部署交易，分别指定部署者、最终 Owner、两个 Worker、recipient；核对 runtime bytecode 和初始暂停状态，生成未签名 Owner 配置，执行小额普通授权归集，验证 Worker 暂停/不能恢复，完成 Owner 两步转移并拒绝旧 Owner 管理调用。测试只发生在新建 loopback Anvil，不是主网或公共测试网部署。

Safe 门槛测试使用接口形状 mock；Anvil 使用独立 EOA 作为本地管理员。因此未宣称生产 Safe 的签名、模块或 UI 导入已做端到端验证。Python 对生成批次结构做单元测试，Anvil 还使用实际 `cast calldata` 生成文件；生产导入后仍需人工解码审核。

编译日志中 `renounceOwnership` 可标记为 view 的提示不改变禁用行为；时间戳 lint 对比是本合约有意实现的链上截止/24 小时等待检查，不使用时间戳产生随机数。初期 Paris 构建和 foundryup bootstrap 失败已分别通过 Cancun 目标和校验和固定的 Foundry 发行包安装修正。

## 可复现命令

```bash
make check
```

测试覆盖角色边界、初始参数、Owner 两步交接/取消/禁止 renounce、旧 Owner 独立 Worker 身份、24 小时边界、提案替换、暂停和全局版本、实际 Permit 签名/抢先提交/复用/未消费签名、来源顺序、零余额、有限授权冲突、后续来源失败的整体回滚、fee/false-return/no-return/no-transfer 代币、回调重入和受限找回。

测试不是形式化证明，也不等于生产 Worker 账务与恢复逻辑已通过验证。

## 真实资产 fork 验证：上线门槛，初始化时未执行

每个拟支持的 `(chainId,tokenAddress)` 必须单独审查，不能只根据 token symbol 或相同 ABI 推断兼容。

```bash
export FORK_RPC_URL='<ARCHIVE_RPC_ENDPOINT>'
export FORK_TOKEN='<REVIEWED_TOKEN_ADDRESS>'
export FORK_BLOCK_NUMBER='<FIXED_BLOCK_NUMBER>'
forge test --match-path test/Fork.t.sol -vvvv
```

固定区块必须属于已支持 Cancun 的链状态。测试在本地 fork 中为新建合成 EOA 设置余额，按真实 domain 和 nonce 签署 Permit，验证首次归集和后续 allowance 复用。不广播，不使用平台真实用户私钥。没有 `FORK_RPC_URL` 时明确跳过，不能计作兼容性通过。

此通用用例只是准入起点：还应检查发行方暂停/黑名单、代理实现、真实 Permit domain、nonce、额度语义、来源和 recipient 受限情况，记录合约地址、实现地址、区块、调用证据和 gas。先用主网 fork，再做经批准的小额真实资产演练。AIT 地址和首版生产资产尚未提供，因此没有预填“已通过”。

## 上线门槛

提交对应 CI 为绿色；部署配置经双人复核；目标链 Cancun 兼容；管理员多签实际实现和权限审核；每个资产的 fork 与小额演练完成；未决任务恢复和账务去重在生产后台完成测试；旧部署/授权迁移已清点。上述步骤未完成前，不以本仓库初始化成功替代生产批准。
