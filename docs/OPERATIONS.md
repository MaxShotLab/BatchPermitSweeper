# 运维与交接

## 日常权限

Owner 管理 Worker、代币白名单、收款地址和所有权；Owner 与有效 Worker 都可以归集、暂停。只有 Owner 可以恢复。合约不自动校验后续新 Owner 的多签阈值，2/3 多签是部署和管理交接的运维要求。

`setOperator(account,status)`、`setTokenAllowed(token,status)` 实际改变状态时更新全局版本，相同值不更新。停用代币不撤销其 allowance，撤销 Worker 不改变充值地址的授权。

## 紧急暂停

Owner 或有效 Worker 执行 `pause()`。后台同时停止新任务和新签名，记录最后已确认区块，核对所有未决交易，不把 RPC 超时当作失败。Owner 撤销异常 Worker、处理密钥事件后才能执行 `unpause()`。

暂停和恢复各自递增配置版本，因此暂停前的旧上下文在恢复后仍不能执行。仍被授权的 Worker 能读取新版本生成新任务；版本检查不是永久撤销 Worker 的替代品。暂停不会撤回已经归集的资金，也不会使代币 allowance 失效。

## 收款地址轮换

正常轮换：`proposeRecipient(newRecipient)` → 旧目标继续收款 → 等待满 24 小时 → `pause()` → `activateRecipient(proposalId,expectedNewRecipient)` → 核对新目标 → `unpause()`。

疑似泄露时先暂停，再提案并等待，不能跳过 24 小时。到期不会自动切换，切换后也不会自动恢复。

链上查询 `pendingRecipientChange()` 获取编号、地址、`validAfter`。更换提案（即使目标相同）使用新编号并重置等待期；旧确认失效。取消使用 `cancelRecipientChange(proposalId)`，不改变当前收款地址或暂停状态。

时间以目标链 `block.timestamp` 为准，不以操作员电脑或浏览器倒计时为准。确认时必须匹配提案编号和目标地址。

## Owner 两步转移

当前 Owner 调用 `transferOwnership(newOwner)`，核对 `pendingOwner()` 后，由新 Owner 自己调用 `acceptOwnership()`。不要求 24 小时延迟，不强制暂停。新 Owner 为 Safe 时必须由新 Safe 发起接受交易，而非某个签名人的 EOA。

新 Owner 接受之前，当前 Owner 继续管理，并可改换待接任地址或通过 `transferOwnership(address(0))` 取消待接任。接受成功后配置版本更新，旧任务需重建。

`renounceOwnership()` 始终失败。不可升级不妨碍 Owner 转移。

交接必须另外核对：当前 recipient、待生效收款提案、Worker、代币白名单、暂停状态、所有未决任务和密钥持有人。已有收款提案保留原等待期，新 Owner 应明确取消或确认；不会因所有权交接而自动激活。

**旧 Owner 若独立登记为 Worker，转移后仍有 Worker 权限。需要新 Owner 单独执行 `setOperator(oldOwner,false)`。** 不自动清空其他 Worker，避免交接导致无关业务中断。

## 合约自身 ERC-20 找回

确认误转金额，暂停归集，Owner 调用 `recoverERC20(token,amount,context)`。context 使用当前 recipient、版本和有限截止时间。仅转出 Sweeper 自己持有的代币，且只到当前收款地址。

不要求正常归集白名单，但仍要求代币有代码、金额有效、收款净增加量一致。冻结、转账税或恶意代币可能无法找回。没有任意调用、第三方目标、EOA allowance 扣款、原生币或 NFT 找回入口；不要往 Sweeper 充值原生币或 NFT。

## 不可升级合约迁移

旧实例能暂停时：停止旧任务和旧 Permit 签发 → 确认未决交易 → 暂停并撤销旧 Worker → 部署/验证新实例 → 处理旧授权和未使用签名 → 建立新授权 → 小额验证 → 切换 Worker。

最早的示例合约没有暂停入口。对这样的旧部署，只能停止后台、撤销 Worker、处理仍有效的 Owner 权限和授权，不能把“停止服务”说成“链上已经暂停”。

旧 allowance 和旧签名分别清理：

- `approve(oldSweeper,0)` 不能保证 Permit nonce 被消费；旧有效签名仍可能重建授权。
- 新 Sweeper 的有效 Permit 即使推进 nonce，也不会自动清零旧 Sweeper 的 allowance。
- 对支持标准 Permit 的资产，可为 oldSweeper 签署 `value=0` 的 Permit，由交易发送账户直接向代币合约提交。签名人必须是来源 EOA。

读取当前 nonce 和 allowance，串行处理，直到旧 allowance 为零，且所有已签旧授权已消费、因 nonce 变化失效或到期。不能仅删除本地签名记录。迁移期间禁止预签未来 nonce；旧、新 spender 在同一代币同一来源上共享 Permit nonce 序列。

## 监控与审计记录

关注所有 Owner 转移、暂停恢复、Worker/代币状态改变、收款提案/取消/生效、资产找回事件，以及异常批次失败、实收不一致和 nonce 冲突。监控不能替代多签控制。

每次管理变更保存交易哈希、执行人审批记录、变化前后配置和未决任务处理结果。归集与充值入账账本保持独立，避免归集重复增加用户余额。
