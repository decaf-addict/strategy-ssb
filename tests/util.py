from brownie import Contract


def airdrop_beets_rewards(strategy, beets, beets_whale):
    beets.approve(strategy, 2 ** 256 - 1, {'from': beets_whale})
    beets.transfer(strategy, 500 * 1e18, {'from': beets_whale})

def airdrop_tusd_rewards(strategy, tusd, tusd_whale):
    tusd.approve(strategy, 2 ** 256 - 1, {'from': tusd_whale})
    tusd.transfer(strategy, 500 * 1e18, {'from': tusd_whale})

def airdrop_rewards(strategy, beets, beets_whale, tusd, tusd_whale):
    airdrop_beets_rewards(strategy, beets, beets_whale)
    airdrop_tusd_rewards(strategy, tusd, tusd_whale)


def stateOfStrat(msg, strategy, token):
    print(f'\n===={msg}====')
    wantDec = 10 ** token.decimals()
    print(f'Balance of {token.symbol()}: {strategy.balanceOfWant() / wantDec}')
    print(f'Balance of Bpt: {strategy.balanceOfBpt() / 1e18}')
    print(f'balanceOfBptInMasterChef: {strategy.balanceOfBptInMasterChef() / 1e18}')
    print(f'Balance of BEETS: {strategy.balanceOfBeets()/ wantDec}')
    print(f'Estimated Total Assets: {strategy.estimatedTotalAssets() / wantDec}')
