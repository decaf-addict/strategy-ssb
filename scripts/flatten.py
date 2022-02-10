from brownie import Strategy, StrategyFactory, accounts, config, network, project, web3


def main():
    with open('./build/contracts/StrategyFlat.sol', 'w') as f:
        f.write(Strategy.get_verification_info()['flattened_source'])
    with open('./build/contracts/StrategyFactoryFlat.sol', 'w') as f:
        f.write(StrategyFactory.get_verification_info()['flattened_source'])