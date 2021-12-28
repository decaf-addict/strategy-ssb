from brownie import chain, Strategy, Contract, accounts, config, network, project, web3
from eth_utils import is_checksum_address
import click


def main():
    rebalancer = Contract("0x1Ed9C8BD3DccB85f704A5287444B552F9d5E1a26")
    pool = Contract("0x7B50775383d3D6f0215A8F290f2C9e2eEBBEceb2")
    vault = Contract("0xBA12222222228d8Ba445958a75a0704d566BF2C8")
    profit = 0
    (tokens, balances, last) = vault.getPoolTokens(pool.getPoolId())
    for token in tokens:
        token = Contract(token)
        if pool == token:
            continue
        main = Contract(token.getMainToken())
        wrapped = Contract(token.getWrappedToken())
        dec = main.decimals()
        (swap, amountNeededIn) = rebalancer.getSwapAndAmountInNeeded(token, 0)
        gain = swap[4] - wrapped.staticToDynamicAmount(amountNeededIn)
        print(f'gain: {gain / (10 ** dec)}')
        print(f'{swap}')
        print(f'amountNeededIn: {amountNeededIn}')

        profit += gain / (10 ** dec)
    print(f'total: {profit}')
