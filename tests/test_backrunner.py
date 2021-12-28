import brownie
from brownie import Contract
import pytest
import util


def test_backrunner(backrunner, strategist):
    backrunner.run(0, {'from': strategist})

    dai = Contract("0x6B175474E89094C44Da98b954EedeAC495271d0F")
    assert dai.balanceOf(backrunner) > 0
    print(f'profit: {dai.balanceOf(backrunner)/1e18} dai')
