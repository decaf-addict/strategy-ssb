import brownie
from brownie import Contract, accounts
import pytest
import util


def test_operation(
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, gov
):
    # Deposit to the vault
    print("Strategy Name:", strategy.name())
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # tend()
    strategy.tend({"from": strategist})

    # withdrawal
    vault.withdraw(vault.balanceOf(user), user, 10, {"from": user})
    assert (pytest.approx(token.balanceOf(user), rel=RELATIVE_APPROX) == user_balance_before)


def test_emergency_exit(
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, gov
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # set emergency and exit
    strategy.setEmergencyExit()
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    assert strategy.estimatedTotalAssets() < amount


def test_profitable_harvest(
        chain, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, bal, bal_whale, ldo,
        ldo_whale, management
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    before_pps = vault.pricePerShare()
    util.airdrop_rewards(strategy, bal, bal_whale, ldo, ldo_whale)

    # Harvest 2: Realize profit
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    profit = token.balanceOf(vault.address)  # Profits go to vault

    assert strategy.estimatedTotalAssets() + profit > amount
    assert vault.pricePerShare() > before_pps


def test_deposit_all(chain, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, bal, bal_whale,
                     ldo, gov, pool,
                     ldo_whale):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)

    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    chain.sleep(strategy.minDepositPeriod() + 1)
    chain.mine(1)

    strategy.setParams(15, strategy.maxSlippageOut(), strategy.maxSingleDeposit(), strategy.minDepositPeriod(),
                       {'from': gov})
    while strategy.tendTrigger(0) == True:
        strategy.tend({'from': gov})
        util.stateOfStrat("tend", strategy, token)
        assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
        chain.sleep(strategy.minDepositPeriod() + 1)
        chain.mine(1)

    before_pps = vault.pricePerShare()
    util.airdrop_rewards(strategy, bal, bal_whale, ldo, ldo_whale)

    # Harvest 2: Realize profit
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    profit = token.balanceOf(vault.address)  # Profits go to vault

    slippageIn = amount * strategy.maxSlippageIn() / 10000
    assert strategy.estimatedTotalAssets() + profit > (amount - slippageIn)
    assert vault.pricePerShare() > before_pps

    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    util.stateOfStrat("after harvest 5000", strategy, token)

    half = int(amount / 2)
    # profits
    assert strategy.estimatedTotalAssets() >= half - slippageIn / 2


def test_change_debt(
        chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, bal, bal_whale, ldo, ldo_whale
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    half = int(amount / 2)

    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half

    vault.updateStrategyDebtRatio(strategy.address, 10_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    util.stateOfStrat("before airdrop", strategy, token)
    util.airdrop_rewards(strategy, bal, bal_whale, ldo, ldo_whale)
    util.stateOfStrat("after airdrop", strategy, token)

    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    util.stateOfStrat("after harvest 5000", strategy, token)

    # compounded slippage
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half

    vault.updateStrategyDebtRatio(strategy.address, 0, {"from": gov})
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    util.stateOfStrat("after harvest", strategy, token)

    assert token.balanceOf(vault.address) >= amount or pytest.approx(token.balanceOf(vault.address),
                                                                     rel=RELATIVE_APPROX) >= amount


def test_sweep(gov, vault, strategy, token, user, amount, weth, weth_amout):
    # Strategy want token doesn't work
    token.transfer(strategy, amount, {"from": user})
    assert token.address == strategy.want()
    assert token.balanceOf(strategy) > 0
    with brownie.reverts("!want"):
        strategy.sweep(token, {"from": gov})

    # Vault share token doesn't work
    with brownie.reverts("!shares"):
        strategy.sweep(vault.address, {"from": gov})

    # # Protected token doesn't work
    # for i in range(strategy.numRewards()):
    #     with brownie.reverts("!protected"):
    #         strategy.sweep(strategy.rewardTokens(i), {"from": gov})

    before_balance = weth.balanceOf(gov)
    weth.transfer(strategy, weth_amout, {"from": user})
    assert weth.address != strategy.want()
    assert weth.balanceOf(user) == 0
    strategy.sweep(weth, {"from": gov})
    assert weth.balanceOf(gov) == weth_amout + before_balance


def test_eth_sweep(chain, token, vault, strategy, user, strategist, gov):
    strategist.transfer(strategy, 1e18)
    with brownie.reverts():
        strategy.sweepETH({"from": strategist})

    eth_balance = gov.balance()
    strategy.sweepETH({"from": gov})
    assert gov.balance() > eth_balance


def test_triggers(
        chain, gov, vault, strategy, token, amount, user, weth, weth_amout, strategist, bal, bal_whale, ldo, ldo_whale,
        token_whale
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    assert strategy.tendTrigger(0) == False
    chain.sleep(strategy.minDepositPeriod() + 1)
    chain.mine(1)
    assert strategy.tendTrigger(0) == True


def test_rewards(
        strategy, strategist, gov
):
    # added in setup
    assert strategy.numRewards() == 1
    strategy.delistAllRewards({'from': gov})
    assert strategy.numRewards() == 0


def test_unbalance_deposit(chain, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, bal,
                           bal_whale, token2_whale, token2, usdc_whale,
                           ldo, gov, pool, balancer_vault):
    # added in setup
    assert strategy.numRewards() == 1
    strategy.delistAllRewards({'from': gov})
    assert strategy.numRewards() == 0

    token.approve(vault.address, 2 ** 256 - 1, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    lpt = Contract(strategy.lpt())

    print(f'pool rate before whale swap: {lpt.getRate()}')

    wantIndex = 0
    tokens = balancer_vault.getPoolTokens(lpt.getPoolId())[0]
    balances = balancer_vault.getPoolTokens(lpt.getPoolId())[1]
    for i, address in enumerate(tokens):
        if address == token.address:
            wantIndex = i

    pooled = balances[wantIndex]
    token.approve(balancer_vault, 2 ** 256 - 1, {'from': usdc_whale})
    chain.snapshot()
    want2Lpt = (
        lpt.getPoolId(),  # PoolID
        0,  # asset in
        1,  # asset out
        100_000_000 * 1e6,  # amount -- here we increase usdc side of the pool dramatically
        b'0x0'  # user data
    )
    lpt2Bpt = (
        pool.getPoolId(),
        1,
        2,
        0,
        b'0x0'
    )
    swaps = [want2Lpt, lpt2Bpt]
    assets = [token, lpt, pool]
    funds = (  # fund struct
        usdc_whale,  # sender
        False,  # fromInternalBalance
        usdc_whale,  # recipient
        False  # toInternalBalance
    )
    deadline = 2 ** 256 - 1
    limits = [int(token.balanceOf(usdc_whale)), 0, 0]
    chain.snapshot()
    balancer_vault.batchSwap(
        0,  # swap struct
        swaps,
        assets,
        funds,
        limits,  # token limit
        deadline,  # Deadline
        {'from': usdc_whale}
    )
    print(f'pool rate after whale swap: {lpt.getRate()}')

    with brownie.reverts("slippedin!"):
        tx = strategy.harvest({
            "from": gov})

        # loosen the slippage check to let the lossy withdraw go through
    strategy.setParams(10000, 10000, strategy.maxSingleDeposit(), strategy.minDepositPeriod(), {'from': gov})
    tx = strategy.harvest({"from": gov})
    print(f'price impact loss : {vault.strategies(strategy)["totalDebt"] - strategy.estimatedTotalAssets()}')
    print(f'bpt: {balancer_vault.getPoolTokens(pool.getPoolId())[1]}')


def test_unbalanced_pool_withdraw(chain, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, bal,
                                  bal_whale, token2_whale, token2,
                                  ldo, gov, pool, balancer_vault):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    print(f'pool rate: {pool.getRate()}')

    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    chain.sleep(strategy.minDepositPeriod() + 1)
    chain.mine(1)

    strategy.setParams(15, strategy.maxSlippageOut(), strategy.maxSingleDeposit(), strategy.minDepositPeriod(),
                       {'from': gov})
    # iterate to get all the funds in
    while strategy.tendTrigger(0) == True:
        strategy.tend({'from': gov})
        util.stateOfStrat("tend", strategy, token)
        assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
        chain.sleep(strategy.minDepositPeriod() + 1)
        chain.mine(1)

    print(f'pool rate: {pool.getRate()}')
    tokens = balancer_vault.getPoolTokens(pool.getPoolId())[0]
    token2Index = 0
    if (tokens[0] == token2):
        token2Index = 0
    elif tokens[1] == token2:
        token2Index = 1
    elif tokens[2] == token2:
        token2Index = 2

    util.stateOfStrat("after deposit all    ", strategy, token)

    lpt = Contract(strategy.lpt())
    bpt = Contract(strategy.bpt())
    pooled = balancer_vault.getPoolTokens(lpt.getPoolId())[1][lpt.getMainIndex()]
    print(f'lpt normal state: {balancer_vault.getPoolTokens(lpt.getPoolId())}')
    print(f'pooled usdc: {pooled}')
    lower_target = lpt.getTargets()[0]
    bpt_whale = accounts.at("0x68d019f64A7aa97e2D4e7363AEE42251D08124Fb", force=True)

    # === simulate bad pool state ===
    bpt.approve(balancer_vault, 2 ** 256 - 1, {'from': bpt_whale})

    usdc2Lpt = (
        lpt.getPoolId(),  # PoolID
        1,  # asset in
        0,  # asset out
        pooled - lower_target / 1e12,  # get pool to lower target
        b'0x0'  # user data
    )
    lpt2Bpt = (
        pool.getPoolId(),
        2,
        1,
        0,
        b'0x0'
    )

    swaps = [usdc2Lpt, lpt2Bpt]
    assets = [token, lpt, pool]
    funds = (  # fund struct
        bpt_whale,  # sender
        False,  # fromInternalBalance
        bpt_whale,  # recipient
        False  # toInternalBalance
    )
    deadline = 2 ** 256 - 1
    limits = [0, 0, int(bpt.balanceOf(bpt_whale))]

    balancer_vault.batchSwap(
        1,  # swap struct
        swaps,
        assets,
        funds,
        limits,  # token limit
        deadline,  # Deadline
        {'from': bpt_whale}
    )
    # now pool should be only 2.9m USDC, which is the lower target of the lpt,
    # any withdraws below 2.9m will start incurring price impact

    print(balancer_vault.getPoolTokens(pool.getPoolId()))
    print(f'pool rate: {pool.getRate()}')

    # now pool is in a bad state low-want
    print(f'lpt bad state: {balancer_vault.getPoolTokens(lpt.getPoolId())}')

    # === simulate strategy withdraws ===
    new_pooled = balancer_vault.getPoolTokens(lpt.getPoolId())[1][lpt.getMainIndex()]

    # this should revert bc we try to withdarw more than the pooled USDC, boosted pool won't allow this.
    with brownie.reverts():
        vault.withdraw(vault.balanceOf(user), user, 10000, {"from": user})

    old_slippage = strategy.maxSlippageOut()

    # exit seems to have very little price impact
    vault.withdraw(new_pooled * 0.98, user, 0, {"from": user})

    print(f'user balance: {token.balanceOf(user)}')
    print(f'user lost: {amount / 2 - token.balanceOf(user)}')
    util.stateOfStrat("after lossy withdraw", strategy, token)

    # make sure principal is still as expected, aka loss wasn't socialized
    assert strategy.estimatedTotalAssets() >= amount / 2 * (10000 - old_slippage) / 10000
