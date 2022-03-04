import urllib.request, json
from brownie import Contract, accounts, web3
import click
import json


def main():
    ssb_dai = Contract('0x3B7c81daa0F7C897b3e09352E1Ca2fBE93Ac234D')
    ssb_usdt = Contract('0xf0E5f920F8daf2a01ed473D67e74565e7a4a1979')
    ssb_usdc = Contract('0xC7af91cdDDfC7c782671eFb640A4E4C4FB6352B4')
    ssb_wbtc = Contract('0xf2901406A1743ac032863777c61f1d61b59115fd')
    ssb_weth = Contract('0x1d4439680c489f18ce480e72DeeDc235952AF9C9')

    strats = [ssb_dai, ssb_usdt, ssb_usdc, ssb_wbtc, ssb_weth]

    bal_distributor = Contract("0xd2EB7Bd802A7CA68d9AcD209bEc4E664A9abDD7b")
    merkleOrchard = Contract("0xdAE7e32ADc5d490a43cCba1f0c736033F2b4eFca")
    bal = "0xba100000625a3754423978a60c9317c58a424e3D"

    nextId = merkleOrchard.getNextDistributionId(bal, bal_distributor)
    for strat in strats:
        for i in range(59, nextId):
            claimed = merkleOrchard.isClaimed(bal, bal_distributor, i, strat)
            print(f'{strat} id: {i} {claimed}')
