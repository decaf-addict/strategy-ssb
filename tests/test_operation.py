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
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, beets, beets_whale, gov
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})

    chain.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # set emergency and exit
    strategy.setEmergencyExit()
    chain.mine(5)
    chain.sleep(1)
    # some slippage won't pass healthcheck
    strategy.setDoHealthCheck(False, {'from': gov})
    strategy.harvest({"from": strategist})
    assert strategy.estimatedTotalAssets() < amount


def test_profitable_harvest(
        chain, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, beets, beets_whale, management
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

    strategy.harvest({"from": strategist})
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    # do a second harvest so the first harvest's stake is sold
    strategy.harvest({"from": strategist})
    chain.sleep(3600 * 6)
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
    # do a second harvest so the first harvest's stake is sold
    strategy.harvest({"from": strategist})
    chain.sleep(3600 * 6)
    chain.mine(1)
    profit = token.balanceOf(vault.address)  # Profits go to vault
    util.stateOfStrat("second harvest", strategy, beets)

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

    util.stateOfStrat("before airdrop", strategy, token)
    util.airdrop_rewards(strategy, beets, beets_whale)
    util.stateOfStrat("after airdrop", strategy, token)

    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    strategy.harvest({"from": strategist})
    chain.sleep(3600 * 6)
    chain.mine(1)
    # do a second harvest so the first harvest's stake is sold
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
