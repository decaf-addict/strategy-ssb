from brownie import Contract, accounts
def airdrop_rewards(strategy, bal, bal_whale, ldo, ldo_whale):
    bal.approve(strategy, 2 ** 256 - 1, {'from': bal_whale})
    bal.transfer(strategy, 100 * 1e18, {'from': bal_whale})
    ldo.approve(strategy, 2 ** 256 - 1, {'from': ldo_whale})
    ldo.transfer(strategy, 100 * 1e18, {'from': ldo_whale})

def simulate_trading_fees_profit(strategy):
    bpt_whale = accounts.at("0xA976eA51b9ba3232706aF125a92e32788Dc08Ddc", force=True)
    bpt = Contract(strategy.poolData()["bpt"])
    bpt.approve(strategy, 2 ** 256 - 1, {'from': bpt_whale})
    bpt.transfer(strategy, 1000 * 1e18, {'from': bpt_whale})

def stateOfStrat(msg, strategy, token):
    print(f'\n===={msg}====')
    wantDec = 10 ** token.decimals()
    print(f'Balance of {token.symbol()}: {strategy.balanceOfWant() / wantDec}')
    print(f'Balance of Bpt: {strategy.balanceOfBpt() / wantDec}')
    for i in range(strategy.numRewards()):
        print(f'Balance of {Contract(strategy.rewardTokens(i)).symbol()}: {Contract(strategy.rewardTokens(i)).balanceOf(strategy.address)}')
    print(f'Estimated Total Assets: {strategy.estimatedTotalAssets() / wantDec}')
