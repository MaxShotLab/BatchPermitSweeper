# BatchPermitSweeper

平台托管充值 EOA 的 ERC-20 批量归集工程。资金直接从来源地址转入当前收款地址；长期 allowance 可复用，仅不足时使用 ERC-2612 Permit 补充授权。

**部署时可以指定最终 Owner、收款地址和多个 Worker。部署者不会自动获得 Owner 或操作员权限。合约默认暂停，代币白名单为空，启用必须由 Owner 显式操作。**

```solidity
constructor(address initialOwner, address initialRecipient, address[] memory initialWorkers)
```

| 能力 | 规则 |
| --- | --- |
| 归集 | Owner 或 Worker；执行时全余额；单次调用全成功或全回滚 |
| 授权 | 允许复用历史 allowance，不是逐次签名消费模型 |
| 收款地址 | Owner 提议，等待 24 小时，暂停后确认，再显式恢复 |
| 管理权 | Ownable2Step 两步转移；允许取消待接任；禁止 renounce |
| 暂停 | Owner、Worker 均可暂停，只有 Owner 可恢复 |
| 资产准入 | Owner 管理代币白名单；不支持转账税或 rebasing 语义 |
| 过期任务 | 收款地址、全局配置版本、执行截止时间共同校验 |
| 资产找回 | 仅暂停时由 Owner 把合约自身的 ERC-20 转给生效收款地址 |
| 升级 | 不可升级，无任意调用入口 |

## 部署交接入口

先读 **[部署手册](docs/DEPLOYMENT.md)**，按顺序完成构建、参数校验、模拟、部署、字节码核对和多签启用。

- [运维与交接](docs/OPERATIONS.md)：Owner 转移、收款地址轮换、暂停和旧授权退役。
- [Worker 接入](docs/INTEGRATION.md)：ABI、Permit、排序、任务恢复和事件记账边界。
- [验证范围](docs/TESTING.md)：自动测试与真实资产上线门槛。
- [安全边界](SECURITY.md)：长期授权和管理员信任，不等同第三方审计报告。

## 本地构建与测试

需要 Git、Python 3.10+、GNU Make、Bash，以及 Foundry 1.7.1。Linux x86_64 可使用仓库的固定版本、校验和安装脚本；其他系统使用官方相同版本发行文件并校验其摘要。

```bash
git clone https://github.com/MaxShotLab/BatchPermitSweeper.git
cd BatchPermitSweeper
git submodule update --init
# Linux x86_64 only:
bash scripts/install-foundry-linux.sh
export PATH="$HOME/.foundry/bin:$PATH"
make check
```

`make check` 包含编译、合约单元/模糊/状态不变量测试、Python 工具测试，以及全新本地 Anvil 上的真实部署与管理权交接演练。Anvil 演练不连接主网、不读取生产私钥。

ABI 可用 `make abi` 查看，或直接读取 `out/BatchPermitSweeper.sol/BatchPermitSweeper.json`。

## 固定构建基线

| 组件 | 固定版本 / 提交 |
| --- | --- |
| Solidity | 0.8.37 |
| EVM target | **Cancun** |
| Optimizer | enabled，200 runs，viaIR=false |
| OpenZeppelin Contracts | v5.7.0 / `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` |
| forge-std | v1.16.2 / `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` |
| Foundry | v1.7.1 |

**兼容性调整：** 实际编译确认 OpenZeppelin 5.7.0 的依赖包含 `MCOPY`，先前方案中的 Paris 目标不能通过编译。本工程使用 Cancun；部署人员必须确认目标链已支持 Cancun，不能把本构建产物部署到不兼容的 EVM。存储版重入锁保留，不使用 `ReentrancyGuardTransient`。

配置从 `config/deployment.example.json` 复制。示例中的零地址故意不能通过校验，chainId 也必须改为实际目标链；仓库不预设 AIT 或任何生产资产已通过审核。

## 目录

```text
src/                       Production contract
script/                    Deployment configuration and verification
config/                    Public deployment template; no keys
scripts/                   Validation, unsigned Safe batches, local smoke test
test/                      Unit, fuzz, invariant and opt-in fork tests
docs/                      Deployment, operations and integration handover
.github/workflows/ci.yml    Reproducible build and tests; never deploys to production
```

本仓库交付合约及部署工具，不包含托管私钥服务、生产 Worker 运行服务或充值账务服务。接入约束已记录，但这些外部系统不在本次代码修改范围内。生产部署前仍需资产专属 fork 验证、管理员多签审核和小额演练。
