import pytest
from brownie import accounts, Contract
import util

def test_real_migration_and_multiple_harvest(
        chain,
        vault,
        amount,
        Strategy,
        strategist,
        gov,
        user,
        masterChef,
        RELATIVE_APPROX,
        balancer_vault, pool, management, swapStepsBeets, beets
):
    old = Contract("0xF864f92e88054AA05639324090b411C1D55B4a5B")
    token = Contract(old.want())
    vault = Contract(old.vault())
    gov = accounts.at(vault.governance(), force=True)
    fromGov = {'from': gov}

    util.stateOfStrat("old strategy before migration", old, token)

    fixed_strategy = strategist.deploy(Strategy, vault, balancer_vault, pool, masterChef, 5, 5, 100_000, 2 * 60 * 60,
                                       33)
    fixed_strategy.whitelistReward(beets, swapStepsBeets, fromGov)

    

    # steady beets 2 pool = #33
    old_pending = masterChef.pendingBeets(33, old)
    print(f'pending beets from old strategy: {old_pending}')

    vault.migrateStrategy(old, fixed_strategy, fromGov)
    util.stateOfStrat("old strategy after migration", old, token)
    util.stateOfStrat("new strategy after migration", fixed_strategy, token)

    total_debt = vault.strategies(fixed_strategy)["totalDebt"]
    assert fixed_strategy.estimatedTotalAssets() >= total_debt

    # this lets gov sweep and take x% cut
    assert beets.balanceOf(fixed_strategy) >= old_pending
    print(f'vault state: {vault.strategies(fixed_strategy)}')

    fixed_strategy.depositIntoMasterChef(fixed_strategy.balanceOfBpt(), fromGov)
    print(f'vault state: {vault.strategies(fixed_strategy)}')

    util.stateOfStrat("old strategy after harvest", old, token)
    util.stateOfStrat("new strategy after harvest", fixed_strategy, token)

    tx = fixed_strategy.harvest(fromGov)
    tx = fixed_strategy.harvest(fromGov)
    
    # sell everything
    # fixed_strategy.setEmergencyExit(fromGov)
    fixed_strategy.updateStrategyDebtRatio(0,fromGov)
    # rewards sold separately
    fixed_strategy.sellRewards(fromGov)

    fixed_strategy.setParams(
        5_000,
        5_000,
        fixed_strategy.maxSingleDeposit(),
        fixed_strategy.minDepositPeriod(),
        fromGov
    )
    fixed_strategy.setDoHealthCheck(False, fromGov)
    fixed_strategy.harvest(fromGov)

    print(f'vault state: {vault.strategies(fixed_strategy)}')

    util.stateOfStrat("debt ratio 0", fixed_strategy, token)

    # hopefully the gains from trading fees cancels out slippage
    print(f'net loss from exit: {vault.strategies(fixed_strategy)["totalLoss"]}')
    assert fixed_strategy.estimatedTotalAssets() == 0
