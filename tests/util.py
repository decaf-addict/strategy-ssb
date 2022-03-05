from brownie import Contract


def airdrop_rewards(strategy, beets, beets_whale):
    beets.approve(strategy, 2 ** 256 - 1, {'from': beets_whale})
    beets.transfer(strategy, 500 * 1e18, {'from': beets_whale})

def airdrop_tusd_rewards(strategy, token2, token2_whale):
    token2.approve(strategy, 2 ** 256 - 1, {'from': token2_whale})
    token2.transfer(strategy, 3_000 * 1e18, {'from': token2_whale})

def airdrop_all_rewards(strategy, beets, beets_whale, token2, token2_whale):
    token2.approve(strategy, 2 ** 256 - 1, {'from': token2_whale})
    token2.transfer(strategy, 3_000 * 1e18, {'from': token2_whale})
    token2.approve(strategy, 2 ** 256 - 1, {'from': token2_whale})
    token2.transfer(strategy, 3_000 * 1e18, {'from': token2_whale})


def stateOfStrat(msg, strategy, token):
    print(f'\n===={msg}====')
    wantDec = 10 ** token.decimals()
    print(f'Balance of {token.symbol()}: {strategy.balanceOfWant() / wantDec}')
    print(f'Balance of Bpt: {strategy.balanceOfBpt() / 1e18}')
    print(f'balanceOfBptInMasterChef: {strategy.balanceOfBptInMasterChef() / 1e18}')
    print(f'Balance of BEETS: {strategy.balanceOfBeets()/ wantDec}')
    print(f'Estimated Total Assets: {strategy.estimatedTotalAssets() / wantDec}')
