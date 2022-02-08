import pytest
from brownie import Contract, accounts
import test_operation
import util


# old_dai to fixed_dai
def test_live_dai_migration(
        chain,
        token,
        vault,
        amount,
        Strategy,
        strategist,
        gov,
        user,
        RELATIVE_APPROX,
        balancer_vault, bal_whale,
        pool, ldo, ldo_whale, management, bal
):
    old = Contract("0x9cfF0533972da48Ac05a00a375CC1a65e87Da7eC")
    vault = Contract(old.vault())
    gov = accounts.at(vault.governance(), force=True)
    fromGov = {'from': gov}

    util.stateOfStrat("old strategy before migration", old, token)

    fixed_strategy = Contract("0x3B7c81daa0F7C897b3e09352E1Ca2fBE93Ac234D")
    vault.migrateStrategy(old, fixed_strategy, fromGov)
    util.stateOfStrat("old strategy after migration", old, token)
    util.stateOfStrat("new strategy after migration", fixed_strategy, token)

    total_debt = vault.strategies(fixed_strategy)["totalDebt"]
    assert fixed_strategy.estimatedTotalAssets() >= total_debt

    # exit everything out and see how much we get
    fixed_strategy.setEmergencyExit(fromGov)
    fixed_strategy.harvest(fromGov)

    util.stateOfStrat("debt ratio 0", fixed_strategy, token)

    # hopefully the gains from trading fees cancels out slippage
    print(f'net loss from exit: {vault.strategies(fixed_strategy)["totalLoss"]}')
    assert fixed_strategy.estimatedTotalAssets() == 0


# clone fixed_dai to fixed_usdc, migrate old_usdc to fixed_usdc
def test_clone_usdc_then_migration(
        chain,
        token,
        vault,
        amount,
        Strategy,
        strategist,
        gov,
        user,
        RELATIVE_APPROX,
        balancer_vault, bal_whale,
        pool, ldo, ldo_whale, management, bal, swapStepsBal
):
    old = Contract("0x7A32aA9a16A59CB335ffdEe3dC94024b7F8A9a47")
    vault = Contract(old.vault())
    fixed_original = Contract("0x3B7c81daa0F7C897b3e09352E1Ca2fBE93Ac234D")
    gov = accounts.at(vault.governance(), force=True)
    fromGov = {'from': gov}
    fixed_strategy = Strategy.at(fixed_original.clone(
        old.vault(),  # yvUSDC
        old.strategist(),
        old.rewards(),
        old.keeper(),
        old.balancerVault(),
        old.bpt(),
        old.maxSlippageIn(),
        old.maxSlippageOut(),
        old.maxSingleDeposit(),
        old.minDepositPeriod(),
        fromGov
    ).return_value)

    fixed_strategy.whitelistRewards(bal, swapStepsBal, {'from': gov})

    vault.migrateStrategy(old, fixed_strategy, fromGov)
    util.stateOfStrat("old strategy after migration", old, token)
    util.stateOfStrat("new strategy after migration", fixed_strategy, token)

    total_debt = vault.strategies(fixed_strategy)["totalDebt"]
    assert fixed_strategy.estimatedTotalAssets() >= total_debt

    pps_before = vault.pricePerShare()
    # test profitable harvest from unsold bals from old
    fixed_strategy.harvest(fromGov)

    util.stateOfStrat("new strategy after harvest", fixed_strategy, token)

    # pps unlock
    chain.sleep(3600 * 6)
    chain.mine(1)

    pps_after = vault.pricePerShare()
    assert pps_after > pps_before
    assert vault.strategies(fixed_strategy)["totalLoss"] == 0

