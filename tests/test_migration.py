import pytest


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
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # migrate to a new strategy
    new_strategy = strategist.deploy(Strategy, vault, balancer_vault, pool, masterChef, 10, 10, 100_000, 2 * 60 * 60,
                                     10)
    vault.migrateStrategy(strategy, new_strategy, {"from": gov})
    assert (pytest.approx(new_strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount)


def test_masterchef(
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
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    chain.mine(3)
    strategy.tend({"from": gov})

    strategy.setMasterChef(masterChef, {"from": gov})
    assert strategy.balanceOfBptInMasterChef() == 0
    assert strategy.balanceOfStakeBptInMasterChef() == 0
