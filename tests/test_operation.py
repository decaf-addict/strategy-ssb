import brownie
from brownie import Contract
import pytest
import util


def test_operation(
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX
):
    # Deposit to the vault
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
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX
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
        ldo_whale
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
                     ldo, gov,
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
    assert strategy.estimatedTotalAssets() >= half - slippageIn/2


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

    assert strategy.harvestTrigger(0) == False
    util.airdrop_rewards(strategy, bal, bal_whale, ldo, ldo_whale)
    assert strategy.harvestTrigger(0) == True

    assert strategy.tendTrigger(0) == False
    chain.sleep(strategy.minDepositPeriod() + 1)
    chain.mine(1)
    assert strategy.tendTrigger(0) == True


def test_rewards(
        strategy, strategist, gov
):
    # added in setup
    assert strategy.numRewards() == 2
    strategy.delistAllRewards({'from': gov})
    assert strategy.numRewards() == 0
