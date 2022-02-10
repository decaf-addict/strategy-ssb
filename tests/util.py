from brownie import Contract


def airdrop_rewards(strategy, beets, beets_whale):
    beets.approve(strategy, 2 ** 256 - 1, {'from': beets_whale})
    beets.transfer(strategy, 8_000 * 1e18, {'from': beets_whale})


def stateOfStrat(msg, strategy, token):
    print(f'\n===={msg}====')
    wantDec = 10 ** token.decimals()
    print(f'Balance of {token.symbol()}: {strategy.balanceOfWant() / wantDec}')
    print(f'Balance of Bpt: {strategy.balanceOfBpt() / 1e18}')
    print(f'balanceOfBptInMasterChef: {strategy.balanceOfBptInMasterChef() / 1e18}')
    print(f'Balance of BEETS: {strategy.balanceOfReward()/ wantDec}')
    print(f'Estimated Total Assets: {strategy.estimatedTotalAssets() / wantDec}')
