from brownie import Strategy, Contract, accounts, config, network, project, web3
from eth_utils import is_checksum_address
import click


def main():
    dev = accounts.load(click.prompt("Account", type=click.Choice(accounts.load())))

    ssb_mim = Contract("0x04A67AdFF3D9E4b3F40915ea06aC797d490874E6")

    beets = "0xF24Bcf4d1e507740041C9cFd2DddB29585aDCe1e"
    usdc = "0x04068DA6C83AFCFA0e13ba15A6696662335D5B75"
    mim = "0x82f0B8B456c1A451378467398982d4834b6829c1"
    beetsUsdcPoolId = 0x03c6b3f09d2504606936b1a4decefad204687890000200000000000000000015
    usdcTokenPoolId = 0xd163415bd34ef06f57c58d2aed5a5478afb464cc00000000000000000000000e
    swapStepsBeets = ([beetsUsdcPoolId, usdcTokenPoolId], [beets, usdc, mim])
    beetsUsdcPool = 0x03c6B3f09D2504606936b1A4DeCeFaD204687890

    ssb_mim.whitelistReward(beets, swapStepsBeets, {'from': dev})
    ssb_mim.setStakeParams(8000, [usdc, beets], beetsUsdcPool, 1, 0, {'from': dev})
