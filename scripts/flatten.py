from brownie import Arbitrager, KeeperDaoFlashloaner, accounts, config, network, project, web3


def main():
    with open('./build/contracts/ArbitragerFlat.sol', 'w') as f:
        Arbitrager.get_verification_info()
        f.write(Arbitrager._flattener.flattened_source)
    with open('./build/contracts/KeeperDaoFlashloanerFlat.sol', 'w') as f:
        KeeperDaoFlashloaner.get_verification_info()
        f.write(KeeperDaoFlashloaner._flattener.flattened_source)