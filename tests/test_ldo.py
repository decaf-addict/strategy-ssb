import brownie
from brownie import Contract
import pytest
import util

def test_ldo_claim(accounts, ldo, chain):
    bpt = Contract("0x32296969Ef14EB0c6d29669C550D4a0449130230")

    # holder of bpt that hasn't been deposited into gauge
    whale = accounts.at("0x3C0AeA3576B0D70e581FF613248A74D56cDe0853", force=True)
    gauge = Contract("0xcD4722B7c24C29e0413BDCd9e51404B4539D14aE")

    bpt.approve(gauge, 2 ** 256 - 1, {'from': whale})

    ldo_before = ldo.balanceOf(whale)
    gauge.deposit(bpt.balanceOf(whale), {'from': whale})

    chain.sleep(3600 * 24 * 7)
    chain.mine(1)

    gauge.claim_rewards(whale, {'from': whale})

    assert ldo.balanceOf(whale) > ldo_before
