# Worker 与签名服务接入

本仓库提供合约、ABI 生成方式与接入约束，不包含生产 Worker、私钥服务或充值账务服务的实现。

## Worker 权限矩阵

以下按调用账户仅持有 Worker 权限说明；全角色、接口条件和版本变化见 [运维权限矩阵](OPERATIONS.md#权限矩阵)。Owner 无须另登记为 Worker 即可执行归集和暂停。

| 调用 / 操作 | 有效 Worker | 未授权或已撤销的 Worker | 执行边界 |
| --- | --- | --- | --- |
| 读取公开状态 | 可以 | 可以 | 无角色限制 |
| `batchSweep` | 可以 | 不可以 | 未暂停；授权、白名单、上下文和金额检查通过 |
| `batchSweepWithPermit` | 可以 | 不可以 | 与普通归集相同；有效 Permit 不替代操作员权限 |
| `pause` | 可以 | 不可以 | 必须处于未暂停状态 |
| `unpause` | 不可以 | 不可以 | 仅当前 Owner |
| `setOperator`、`setTokenAllowed` | 不可以 | 不可以 | 仅当前 Owner，Worker 不能自行恢复身份或启用资产 |
| 收款地址提议、取消、确认 | 不可以 | 不可以 | 仅当前 Owner，确认仍须暂停并满 24 小时 |
| `transferOwnership` | 不可以 | 不可以 | 仅当前 Owner |
| `acceptOwnership` | 不因 Worker 身份获得 | 不因 Worker 身份获得 | 仅当账户另外等于 pendingOwner 时可接受 |
| `recoverERC20` | 不可以 | 不可以 | 仅当前 Owner 且已暂停 |
| 任意目的地转账、升级、放弃所有权 | 不支持 | 不支持 | 不存在这样的 Worker 能力 |

`PermitParam.owner` 是**代币来源地址**，不是 Sweeper 的管理员 `owner()`。来源地址持有代币、签署 Permit 或成为 recipient，都不会自动授予 Sweeper 操作员权限。任何人直接向代币合约提交有效 Permit，与谁有权调用 Sweeper 是两套独立规则；仅有签名或已有 allowance 的外部调用者仍不能归集。

权限按 Sweeper 实际收到的 `msg.sender` 判断。使用转发器、打包合约或智能账户时，不能假定交易外层 EOA 的 Worker 身份会自动传递；必须核对真正调用 Sweeper 的地址。已撤销的 Worker 若另外仍是当前 Owner，其 Owner 权限仍生效；Owner 转移也不会自动清除独立的 Worker 映射。

## ABI 与上下文

从锁定提交的构建产物读取 ABI。构造函数为 `(address owner,address recipient,address[] workers)`。

无 Permit 入口：

```text
batchSweep(address token,address[] sources,(address,uint256,uint256) context)
```

带 Permit 入口：

```text
batchSweepWithPermit(address token,(address,uint256,uint256,uint8,bytes32,bytes32)[] items,(address,uint256,uint256) context)
```

context 依次为 `expectedRecipient`、`expectedConfigVersion`、`validUntil`。Permit item 依次为 `owner`、`value`、`deadline`、`v`、`r`、`s`。所有金额、nonce、版本、截止时间均使用无损整数，JavaScript 不得用 Number 存储 uint256。

sources/items 按来源地址数值严格升序排列，不能按混合大小写字符串排序；先转为无损整数再排序并去重。单个来源也使用数组。

发送前读取当前 recipient、configVersion、paused 和 isTokenAllowed，设置有限截止时间（建议批次 10 分钟）。执行时配置不匹配即失败。全局版本在暂停、恢复、实际 Worker/代币变更、收款激活和 Owner 接受时递增；仅提案或相同值重复设置不递增。

没有链上 taskId 去重：同一 context 在到期前可能被操作员用于多笔交易，来源再次到账后也可能再次成功。后台负责业务任务幂等及来源占用；普通外部地址仍无法调用。

## 授权和 Permit

余额为零就整批回滚。已有 allowance 足够时普通入口可直接全额归集。带 Permit 入口只在不足时尝试 Permit，失败后根据实际 allowance 再决定是否转账；所有转账失败继续抛出，绝不跳过失败来源。

后台默认建立最大 allowance，签名有效期建议 30 分钟。不要求每次产生新签名。不支持不足时自动转 `min(balance,allowance)`；执行前新增充值也必须一并转出，否则整体失败。

Permit 的 domain 属于代币合约：`verifyingContract=token`，消息 `spender=sweeper`。读取真实 token domain/nonce，不根据 symbol 推导，不把 Sweeper 当 domain verifyingContract。标准 Permit nonce 在同一链、同一 token、同一来源内共享，不能按 Worker 或 spender 分拆。

签名服务验证来源属于平台登记的托管 EOA，只为已批准链、token 和 Sweeper 签名。Worker 不持有充值私钥。不能接受 Worker 任意提交的 spender 作为签名策略。

第三方可以提前提交有效 Permit；allowance 已建立时 Sweeper 应继续成功。签名过期或错误不影响已有足够授权的路径。Permit deadline 只限制签名提交，**不使存量 allowance 到期**。

带 Permit 的归集成功也不能证明签名已消费：合约可能跳过了 Permit。必须根据 nonce、allowance、签名到期时间维护状态。交易上下文过期不等于附带 Permit 过期；不预签未来 nonce。

## 来源、签名和交易三种并发控制

| 对象 | 唯一协调键 |
| --- | --- |
| 来源未决归集任务 | `(chainId,token,source)` |
| Permit 签名序列 | `(chainId,token,source)` |
| 发送交易 nonce | `(chainId,worker)` |

任务与交易记录先持久化，再广播；记录链、Sweeper、版本、目的地、来源、发送人、nonce、原始签名交易及所有替换哈希。接管过期租约时先核对链上结果，不能假设租约过期意味着原交易已经失败。

RPC 超时先查询/重播同一笔签名交易，而不是换 Worker 或换 nonce 再扣一次。替换交易必须跟踪原 nonce 的完整生命周期。需要确认层数和重组恢复策略，由目标链接入配置确定。

## 失败处理

零余额、某来源受限、签名/allowance 不足：确认原交易失败后隔离来源，重新读余额和 nonce，重新组批。可以拆分父任务，但每个新链上批次仍全部成功或全部失败。

暂停、Worker 撤销、代币停用：停止执行并处理管理状态。版本或 recipient 不匹配：刷新配置和任务。实收不一致：暂停该资产的后台归集并报警，不盲目对所有来源循环重试。gas 不足按真实估算拆小批次，没有未经测量的固定每批地址数承诺。

同一调用内较后来源失败会回滚较前来源的转账和 Permit 状态。第三方在另一笔交易提交的 Permit 不会回滚。失败交易仍消耗 gas。

## 事件与账务

`UserSwept(token,from,recipient,amount)` 记录本项转出请求额；成功调用还会核对接收方整批净余额增量等于累计金额，再发出 `BatchSwept(token,recipient,operator,totalAmount,totalCount,configVersion)`。

不要仅凭外层交易 status 推断归集成功，尤其在多签、转发器或打包调用环境。核对正确 Sweeper 发出的事件、token、recipient、版本和来源，并按规范链确认。用 `(chainId,txHash,logIndex)` 做事件幂等，同时存 blockHash 以处理重组。

不实现失败后 emit 再 revert 的持久日志：回滚日志不会保留。错误来自模拟、回执、调用跟踪和任务记录。

充值以原始充值交易记账。归集失败不撤销已确认充值，归集成功不重复给用户加余额。执行前新到账资金可能被一并归集，即使后台尚未确认其充值资格。

## 上线前接入验证

后台负责人必须在自身服务中验证崩溃恢复、多 Worker 竞争、未知回执、替换交易、链重组、重复日志、暂停恢复和收款轮换的旧任务失效。本仓库的链上测试不能证明尚未接入的生产后台已经实现这些行为。

规范参考：[ERC-2612](https://eips.ethereum.org/EIPS/eip-2612)、[ERC-20](https://eips.ethereum.org/EIPS/eip-20)。
