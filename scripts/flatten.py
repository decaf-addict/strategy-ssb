from brownie import Strategy, accounts, config, network, project, web3


def main():
    with open('./build/contracts/StrategyFlat.sol', 'w') as f:
        f.write(Strategy.get_verification_info()['flattened_source'])