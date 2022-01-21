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
        pool
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    assert pytest.approx(strategy.estimateTotalAssets({"from": user}).return_value, rel=RELATIVE_APPROX) == amount

    # migrate to a new strategy
    new_strategy = strategist.deploy(Strategy, vault, balancer_vault, pool, 5, 5, 100_000, 2 * 60 * 60)
    vault.migrateStrategy(strategy, new_strategy, {"from": gov})
    assert (pytest.approx(new_strategy.estimateTotalAssets({"from": user}).return_value, rel=RELATIVE_APPROX) == amount)
