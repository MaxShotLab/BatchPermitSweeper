# 部署手册

## 1. 权限和前置条件

部署账户只负责支付创建合约的 gas。最终管理员直接写入构造函数，初始 Worker 同时写入，不存在临时管理员、需要部署者代为执行的配置阶段或代理。

生产 Owner 按产品基线使用 2/3 多签，Worker 使用独立地址。多签必须已经部署到目标链。部署脚本默认检查 Owner 有代码、`getThreshold()==2`、`getOwners()` 返回三个不同的非零地址；这只是接口形状和门槛检查，**不能证明合约一定是可信 Safe，也不替代 singleton、签名人、模块、guard 和 fallback handler 的人工审核**。

目标链必须支持 Cancun。Owner、recipient、workers、chainId 和允许接入的代币地址应由两名负责人交叉核对。收款地址不要求是 EOA，可以是合法合约钱包。

不在配置文件、仓库、聊天记录或命令行参数中放私钥/助记词。签名采用本地加密 keystore 或受支持的硬件钱包。CI 无生产密钥，也不会执行生产部署。

## 2. 固定待部署版本

```bash
git clone https://github.com/MaxShotLab/BatchPermitSweeper.git
cd BatchPermitSweeper
git checkout <APPROVED_COMMIT>
git submodule update --init
forge --version
make check
```

记录完整 commit、两个 submodule 的 commit、Foundry 版本、编译器 0.8.37、Cancun、optimizer 200、viaIR=false。不要在部署前执行自动更新依赖；不要忽略测试失败。GitHub 自动下载的 source ZIP 不包含 submodule 内容，交接优先使用 Git clone。

## 3. 填写公开部署参数

```bash
cp -n config/deployment.example.json config/deployment.local.json
```

编辑该文件：

| 字段 | 说明 |
| --- | --- |
| `chainId` | 目标链数字 ID；脚本必须与 RPC 返回的实际链一致 |
| `owner` | 最终管理员多签；不是部署者地址的默认值 |
| `recipient` | 首个资金收款地址，必须准确 |
| `workers` | 初始 Worker 地址数组；一位 Worker 也用数组；不得重复、不得等于 Owner |
| `requireSafeOwner` | 生产基线为 `true`；`false` 仅用于本地演练或明确批准的非 Safe 环境 |

Worker 可为多个，也可暂设空数组、后续由 Owner 添加。普通部署脚本不添加代币、不恢复运行。

```bash
python3 scripts/validate_config.py config/deployment.local.json
export DEPLOY_CONFIG=config/deployment.local.json
export RPC_URL='<RPC_ENDPOINT>'
export DEPLOYER_ADDRESS='<DEPLOYER_ADDRESS>'
cast chain-id --rpc-url "$RPC_URL"
```

示例文件的零地址必须替换，不能直接部署。Python 校验拒绝未知字段和重复 JSON key，但只验证公开参数结构。链和多签检查在后面的 Forge 模拟中执行。地址校验不验证地址控制权，操作人必须独立核对。

## 4. 配置签名账户并只做模拟

首次使用 keystore 时交互导入，不把原始私钥写入 `.env`：

```bash
cast wallet import sweeper-deployer --interactive
cast wallet address --account sweeper-deployer
```

确认输出地址与 `DEPLOYER_ADDRESS` 相同，账户有足够目标链原生币支付 gas。随后执行无广播模拟：

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" \
  --sender "$DEPLOYER_ADDRESS" \
  --account sweeper-deployer
```

必须检查最终 Owner、recipient、Worker 数量、链 ID、预期构造参数和 gas。无 `--broadcast` 不会提交创建交易。硬件钱包用户可替换签名器选项，但不改变脚本与构造参数。

## 5. 经确认后广播创建交易

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" \
  --sender "$DEPLOYER_ADDRESS" \
  --account sweeper-deployer \
  --broadcast
```

创建交易的构造参数是 `(owner, recipient, workers)`，不是旧方案中的两个参数。保存 Forge 输出和 `broadcast/Deploy.s.sol/<CHAIN_ID>/run-latest.json`，确认交易回执和实际部署地址。

RPC 超时或进程退出不代表创建交易失败；先核对部署账户 nonce、已广播哈希和回执。不要无检查地重复执行创建命令，避免产生第二份合约。

## 6. 配置前检查链上实例

```bash
export SWEEPER_ADDRESS='<DEPLOYED_SWEEPER_ADDRESS>'
forge script script/VerifyDeployment.s.sol:VerifyDeployment --rpc-url "$RPC_URL"
```

这是只读检查，不签名、不广播。它核对当前构建的 runtime bytecode、Owner、pendingOwner、recipient、初始 Worker、暂停状态、配置版本 1 和无收款提案历史。

**必须在任何 Owner 配置交易之前运行。** 启用代币、改 Worker 或恢复之后版本会增加，初始检查会故意失败，不能把它当成日常健康检查。映射成员并不枚举；初始版本与同一字节码验证结合构造参数/事件核对，不能只看几个 getter。

确认链上合约代码后，导出部署用 ABI：

```bash
forge inspect src/BatchPermitSweeper.sol:BatchPermitSweeper abi --json > deployments/BatchPermitSweeper.abi.json
```

浏览器源码验证使用相同提交和编译设置，构造参数可编码为：

```bash
cast abi-encode 'constructor(address,address,address[])' \
  '<OWNER>' '<RECIPIENT>' '[<WORKER_1>,<WORKER_2>]'
```

根据目标浏览器配置 verifier 与密钥，使用 `forge verify-contract`；不要因此修改编译器、依赖或优化参数。若浏览器尚不支持目标编译器，先保留完整编译输入输出和链上 bytecode 比对证据，不能声称源码验证已完成。

## 7. 多签配置资产，然后单独启用

先对每个真实代币完成 `docs/TESTING.md` 的固定区块 fork 验证及发行方限制审查。项目不会根据 symbol 自动登记 USDC、AIT 等资产。

生成未签名的 Safe Transaction Builder 文件：

```bash
python3 scripts/owner_batch.py \
  --config "$DEPLOY_CONFIG" \
  --sweeper "$SWEEPER_ADDRESS" \
  --token '<APPROVED_TOKEN_1>' \
  --token '<APPROVED_TOKEN_2>' \
  --output deployments/allowlist.json
```

由管理员在正确链、正确 Safe 中导入 JSON，审核每项 `to`、`value=0` 和解码后的 `setTokenAllowed(token,true)`，收集多签并执行。脚本只编码文件，不访问 Safe 服务、不签名、不广播，也不会隐式添加 `unpause()`。

逐个读取 `isTokenAllowed(token)`，再次确认 recipient、owner、所有 workers。准备正式启用时再生成只含恢复指令的文件：

```bash
python3 scripts/owner_batch.py \
  --config "$DEPLOY_CONFIG" \
  --sweeper "$SWEEPER_ADDRESS" \
  --include-unpause \
  --output deployments/unpause.json
```

仍由 Owner 多签审核执行。Worker 无权完成这一步。导入文件不等于上链成功；以多签内部调用结果、事件及链上状态为准。

## 8. 交接验收

归档 `deployments/record.example.json` 对应的信息：源码提交、构建参数、链、部署交易/区块、Sweeper、Owner、recipient、Worker、资产审核记录、启用交易、ABI和代码校验结果。工作副本中的 `.local.json`、broadcast 和部署记录默认不进入 Git；按组织要求存入受控运维记录库，不以忽略 Git 代替备份。

先用专用平台测试充值 EOA 和小额资金走首次 Permit，再验证同一来源的新充值不需要再次签名也能归集；确认事件、实收和账务分离。测试暂停、Worker 不能恢复、Owner 转移两步流程。热钱包轮换先在测试环境完整等待/模拟 24 小时，不在生产为演练任意改动收款地址。

本工程没有运行生产部署，也没有内置生产链/代币保证。交付人员填入真实配置并完成上述审核后，才能执行第 5 和第 7 步。

官方参考：[Foundry Solidity scripting](https://getfoundry.sh/guides/scripting-with-solidity)、[Safe Transaction Builder](https://help.safe.global/articles/4180673514-transaction-builder)。
