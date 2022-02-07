import brownie
from brownie import Contract
import pytest
import util


def test_operation(
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX
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
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, beets, beets_whale, gov
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    chain.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # set emergency and exit
    strategy.setEmergencyExit({"from": gov})
    chain.mine(5)
    chain.sleep(1)
    # some slippage won't pass healthcheck
    strategy.setDoHealthCheck(False, {'from': gov})
    strategy.harvest({"from": strategist})
    assert strategy.estimatedTotalAssets() < amount


def test_manual_exit(
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, beets, beets_whale, gov
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    chain.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    chain.mine(5)
    chain.sleep(1)
    # some slippage won't pass healthcheck
    strategy.harvest({"from": strategist})

    strategy.withdrawFromMasterChef(strategy.balanceOfBptInMasterChef(), strategy.masterChefPoolId(), {"from": gov})
    assert strategy.balanceOfBpt() > 0
    assert strategy.balanceOfBptInMasterChef() == 0


def test_profitable_harvest(
        chain, token, vault, gov, strategy, user, strategist, amount, RELATIVE_APPROX, beets, beets_whale, management
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

    # Harvest 2: Realize profit
    util.airdrop_rewards(strategy, beets, beets_whale)

    tx = strategy.harvest({"from": strategist})
    print(tx.events["StrategyReported"])
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)

    profit = token.balanceOf(vault.address)

    assert strategy.estimatedTotalAssets() + profit > amount
    assert vault.pricePerShare() > before_pps


def test_deposit_all(chain, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, beets, beets_whale,
                     gov):
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
    while strategy.tendTrigger(0) == True:
        strategy.tend({'from': gov})
        util.stateOfStrat("tend", strategy, token)
        assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
        chain.sleep(strategy.minDepositPeriod() + 1)
        chain.mine(1)

    before_pps = vault.pricePerShare()
    util.airdrop_rewards(strategy, beets, beets_whale)
    util.stateOfStrat("after airdrop", strategy, beets)

    # Harvest 2: Realize profit
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    util.stateOfStrat("first harvest", strategy, beets)

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
        chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, beets, beets_whale
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
    chain.sleep(1)

    util.stateOfStrat("before airdrop", strategy, token)
    util.airdrop_rewards(strategy, beets, beets_whale)
    util.stateOfStrat("after airdrop", strategy, token)

    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    strategy.harvest({"from": strategist})
    chain.sleep(3600 * 6)
    chain.mine(1)
    util.stateOfStrat("after harvest 5000", strategy, token)
    # compounded slippage
    assert pytest.approx(strategy.estimatedTotalAssets(),
                         rel=RELATIVE_APPROX) == half or strategy.estimatedTotalAssets() >= half

    vault.updateStrategyDebtRatio(strategy.address, 0, {"from": gov})
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    util.stateOfStrat("after harvest", strategy, token)

    assert token.balanceOf(vault.address) >= amount or pytest.approx(token.balanceOf(vault.address),
                                                                     rel=RELATIVE_APPROX) >= amount


def test_sweep(gov, vault, strategy, token, user, amount, wftm, wftm_amount):
    # Strategy want token doesn't work
    token.transfer(strategy, amount, {"from": user})
    assert token.address == strategy.want()
    assert token.balanceOf(strategy) > 0
    with brownie.reverts("!want"):
        strategy.sweep(token, {"from": gov})

    # Vault share token doesn't work
    with brownie.reverts("!shares"):
        strategy.sweep(vault.address, {"from": gov})

    before_balance = wftm.balanceOf(gov)
    wftm.transfer(strategy, wftm_amount, {"from": user})
    assert wftm.address != strategy.want()
    assert wftm.balanceOf(user) == 0
    strategy.sweep(wftm, {"from": gov})
    assert wftm.balanceOf(gov) == wftm_amount + before_balance


def test_eth_sweep(chain, token, vault, strategy, user, strategist, gov):
    strategist.transfer(strategy, 1e18)
    with brownie.reverts():
        strategy.sweepETH({"from": strategist})

    eth_balance = gov.balance()
    strategy.sweepETH({"from": gov})
    assert gov.balance() > eth_balance


def test_triggers(
        chain, gov, vault, strategy, token, amount, user, wftm, wftm_amount, strategist, beets, beets_whale,
        token_whale
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    strategy.harvestTrigger(0)
    strategy.tendTrigger(0)

# simulate a bad deposit, aka pool has too much of the want you're trying to deposit already
def test_unbalance_deposit(chain, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, token2_whale,
                           token2, token_whale, gov, pool, balancer_vault):
    token.approve(vault.address, 2 ** 256 - 1, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    print(f'pool rate before whale swap: {pool.getRate()}')
    pooled = balancer_vault.getPoolTokens(pool.getPoolId())[1][strategy.tokenIndex()]
    token.approve(balancer_vault, 2 ** 256 - 1, {'from': token_whale})
    chain.snapshot()

    print(f'pool rate: {pool.getRate()}')
    tokens = balancer_vault.getPoolTokens(pool.getPoolId())[0]
    token2Index = 0
    if (tokens[0] == token2):
        token2Index = 0
    elif tokens[1] == token2:
        token2Index = 1

    pooled2 = balancer_vault.getPoolTokens(pool.getPoolId())[1][token2Index]
    print(balancer_vault.getPoolTokens(pool.getPoolId()))
    print(f'pooled: {pooled2}')
    token.approve(balancer_vault, 2 ** 256 - 1, {'from': token_whale})

    # simulate bad pool state by whale to swap out 98% of one side of the pool so pool only has excess want
    singleSwap = (pool.getPoolId(), 1, token, token2, pooled2 * 0.98, b'0x0')
    balancer_vault.swap(singleSwap, (token_whale, False, token_whale, False), token.balanceOf(token_whale),
                        chain.time(), {'from': token_whale})
    print(balancer_vault.getPoolTokens(pool.getPoolId()))
    print(f'pool rate: {pool.getRate()}')

    print(f'pool rate after whale swap: {pool.getRate()}')
    print(f'pool state after whale swap: {balancer_vault.getPoolTokens(pool.getPoolId())}')

    with brownie.reverts("BAL#208"):
        tx = strategy.harvest({
            "from": strategist})  # Error Code BAL#208 BPT_OUT_MIN_AMOUNT - Slippage/front-running protection check failed on a pool join


def test_unbalanced_pool_withdraw(chain, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX,
                                  token2_whale, token2,
                                  gov, pool, balancer_vault):
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

    util.stateOfStrat("after deposit all    ", strategy, token)
    pooled = balancer_vault.getPoolTokens(pool.getPoolId())[1][strategy.tokenIndex()]
    print(balancer_vault.getPoolTokens(pool.getPoolId()))
    print(f'pooled: {pooled}')
    token2.approve(balancer_vault, 2 ** 256 - 1, {'from': token2_whale})

    # simulate bad pool state by whale to swap out 98% of one side of the pool so pool only has 2% of the original want
    singleSwap = (pool.getPoolId(), 1, token2, token, pooled * 0.98, b'0x0')
    balancer_vault.swap(singleSwap, (token2_whale, False, token2_whale, False), token2.balanceOf(token2_whale),
                        chain.time(), {'from': token2_whale})
    print(balancer_vault.getPoolTokens(pool.getPoolId()))
    print(f'pool rate: {pool.getRate()}')

    # now pool is in a bad state low-want
    print(f'pool state: {balancer_vault.getPoolTokens(pool.getPoolId())}')

    # withdraw half to see how much we get back, it should be lossy. Assert that our slippage check prevents this
    with brownie.reverts():
        vault.withdraw(vault.balanceOf(user) / 2, user, 10000, {"from": user})
    old_slippage = strategy.maxSlippageOut()

    # loosen the slippage check to let the lossy withdraw go through
    strategy.setParams(10000, 10000, strategy.maxSingleDeposit(), strategy.minDepositPeriod(), {'from': gov})
    vault.withdraw(vault.balanceOf(user) / 2, user, 10000, {"from": user})
    print(f'pool state: {balancer_vault.getPoolTokens(pool.getPoolId())}')
    print(f'user balance: {token.balanceOf(user)}')
    print(f'user lost: {amount / 2 - token.balanceOf(user)}')
    util.stateOfStrat("after lossy withdraw", strategy, token)

    # make sure principal is still as expected, aka loss wasn't socialized
    assert strategy.estimatedTotalAssets() >= amount / 2 * (10000 - old_slippage) / 10000
