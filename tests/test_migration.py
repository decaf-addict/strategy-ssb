import pytest
from brownie import accounts, Contract
import util
import brownie


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
        masterChef
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # migrate to a new strategy
    new_strategy = strategist.deploy(Strategy, vault, balancer_vault, pool, masterChef, 5, 5, 100_000, 2 * 60 * 60,
                                     58)
    vault.migrateStrategy(strategy, new_strategy, {"from": gov})
    assert (pytest.approx(new_strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount)
