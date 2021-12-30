import brownie
from brownie import Contract
import pytest
import util


def test_backrunner(arber, loaner, strategist, accounts):
    usdc = Contract("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")
    bbUsdc = Contract("0x9210F1204b5a24742Eba12f710636D76240dF3d0")
    vault = Contract(bbUsdc.getVault())
    usdcWhale = Contract("0x0A59649758aa4d66E25f08Dd01271e891fe52199")

    amount = 1_000_000 * 1e6
    usdc.approve(vault, amount, {'from': usdcWhale})
    vault.swap(
        (bbUsdc.getPoolId(), 0, usdc, bbUsdc, amount, b'0x'),
        (usdcWhale, False, usdcWhale, False),
        0,
        2 ** 256 - 1,
        {'from': usdcWhale}
    )

    arber.initiateArb(bbUsdc)
    assert usdc.balanceOf(arber) > 0
    print(f'profit: {usdc.balanceOf(arber) / 1e6} usdc')

    rando = accounts.at("0x621BcFaA87bA0B7c57ca49e1BB1a8b917C34Ed2F", force=True)
    before = usdc.balanceOf(rando)
    arber.sweep(usdc, rando)
    assert usdc.balanceOf(rando) > before
