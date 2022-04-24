from brownie import Contract, chain


def airdrop_rewards(strategy, bal, bal_whale, ldo, ldo_whale):
    # wait a week
    chain.sleep(3600 * 24 * 7)


def stateOfStrat(msg, strategy, token):
    print(f'\n===={msg}====')
    wantDec = 10 ** token.decimals()
    print(f'Balance of {token.symbol()}: {strategy.balanceOfWant() / wantDec}')
    print(f'Balance of Unstaked Bpt: {strategy.balanceOfUnstakedBpt() / wantDec}')
    print(f'Balance of Staked Bpt: {strategy.balanceOfStakedBpt() / wantDec}')
    for i in range(strategy.numRewards()):
        print(
            f'Balance of {Contract(strategy.rewardTokens(i)).symbol()}: {Contract(strategy.rewardTokens(i)).balanceOf(strategy.address)}')
    print(f'Estimated Total Assets: {strategy.estimatedTotalAssets() / wantDec}')


def stateOfOldStrat(msg, strategy, token):
    print(f'\n===={msg}====')
    wantDec = 10 ** token.decimals()
    print(f'Balance of {token.symbol()}: {strategy.balanceOfWant() / wantDec}')
    print(f'Balance of Bpt: {strategy.balanceOfBpt() / wantDec}')
    for i in range(strategy.numRewards()):
        print(
            f'Balance of {Contract(strategy.rewardTokens(i)).symbol()}: {Contract(strategy.rewardTokens(i)).balanceOf(strategy.address)}')
    print(f'Estimated Total Assets: {strategy.estimatedTotalAssets() / wantDec}')
