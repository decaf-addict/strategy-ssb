import pytest
from brownie import Contract, accounts
import test_operation
import util


def test_migration(
        chain,
        token,
        vault,
        strategy,
        amount,
        Strategy,
        strategist,
        gov,
        user,
        RELATIVE_APPROX,
        balancer_vault,
        pool,
        balancer_minter,
        gauge_factory
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # migrate to a new strategy
    new_strategy = strategist.deploy(Strategy, vault, balancer_vault, pool, gauge_factory, balancer_minter, 5, 5,
                                     100_000, 2 * 60 * 60)
    vault.migrateStrategy(strategy, new_strategy, {"from": gov})
    assert (pytest.approx(new_strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount)


def test_real_migration(
        chain,
        token,
        vault,
        swapStepsBal,
        strategy,
        amount,
        strategist,
        gov,
        user,
        RELATIVE_APPROX,
        balancer_vault, bal_whale,
        pool, ldo, ldo_whale, management, bal, gauge_factory
):
    old = Contract("0x3B7c81daa0F7C897b3e09352E1Ca2fBE93Ac234D")
    vault = Contract(old.vault())
    gov = accounts.at(vault.governance(), force=True)
    fromGov = {'from': gov}

    util.stateOfOldStrat("old strategy before migration", old, token)

    new_strat = Contract("0x034d775615d50D870D742caA1e539fC8d97955c2")
    new_strat.whitelistRewards(bal, swapStepsBal, {'from': gov})
    vault.migrateStrategy(old, new_strat, fromGov)
    new_strat.stakeBpt(new_strat.balanceOfUnstakedBpt(), {'from': gov})
    util.stateOfOldStrat("old strategy after migration", old, token)
    util.stateOfStrat("new strategy after migration", new_strat, token)

    total_debt = vault.strategies(new_strat)["totalDebt"]
    assert new_strat.estimatedTotalAssets() >= total_debt

    chain.sleep(3600 * 24 * 7)
    chain.mine(1)

    bal_before = new_strat.balanceOfReward(0)
    new_strat.claimAndSellRewards(False, {'from': gov})
    assert new_strat.balanceOfReward(0) > bal_before

    util.stateOfStrat("new strategy after claim", new_strat, token)

    tx = new_strat.harvest({'from': gov})
    print(tx.events["StrategyReported"])
