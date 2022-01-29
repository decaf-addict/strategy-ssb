import sympy
import numpy
from brownie import Contract
import requests


def main():
    # Steady Beets 2
    ssbeet_staBeetPool_dai = Contract("0xB905eabA7A23424265638bdACFFE55564c7B299B")
    ssbeet_staBeetPool_usdc = Contract("0x56aF79e182a7f98ff6d0bF99d589ac2CabA24e2d")

    # Guqin Qi V2
    ssbeet_guqinQiPool_dai = Contract("0x85c307D24da7086c41537b994de9bFc4C21BAEB5")
    ssbeet_guqinQiPool_usdc = Contract("0xBd3791F3Dcf9DD5633cd30662381C80a2Cd945bd")

    # Ziggy Stardust & Magic Internet Money
    ssbeet_beetXlpMimUsdcUsdtPool_mim = Contract("0xbBdc83357287a29Aae30cCa520D4ed6C750a2a11")
    ssbeet_beetXlpMimUsdcUsdtPool_usdc = Contract("0x4003eE222d44953B0C3eB61318dD211a4A6f109f")
    ssbeet_beetXlpMimUsdcUsdtPool_usdt = Contract("0x36E74086C388305CEcdeff83d6cf31a2762A3c91")

    # Daniele and Do's Double Dollar Fugue
    ssbeet_mimUsdcUstPool_usdc = Contract("0x1c13C43f8F2fa0CdDEE6DFF6F785757650B8c2BF")
    ssbeet_mimUsdcUstPool_mim = Contract("0xfD7E0cCc4dE0E3022F47834d7f0122274c37a0d1")

    # Variations on a theme by USD Circle
    ssbeet_asUsdcPool_usdc = Contract("0x8Bb79E595E1a21d160Ba3f7f6C94efF1484FB4c9")

    query = """query {
        pools {
            id
            name
            apr {
              total
            }
          }
    }"""

    # Call the public hosted TheGraph endpoint
    url = 'https://backend.beets-ftm-node.com/graphql'
    pools = requests.post(url, json={'query': query}).json()["data"]["pools"]
    aprs = {}
    for pool in pools:
        aprs[pool["id"]] = float(pool["apr"]["total"])

    print(f'== aprs ==')
    print(aprs)

    strategies = [
        # ssbeet_staBeetPool_dai,
        # ssbeet_guqinQiPool_dai,
        ssbeet_staBeetPool_usdc,
        ssbeet_guqinQiPool_usdc,
        ssbeet_beetXlpMimUsdcUsdtPool_usdc,
        ssbeet_mimUsdcUstPool_usdc,
        ssbeet_asUsdcPool_usdc,
    ]
    print(f'== strategies ==')
    print(strategies)

    tvls = []

    for strategy in strategies:
        if strategy.balanceOfBptInMasterChef() == 0:
            continue
        yv = Contract(strategy.vault())
        pool = Contract(strategy.bpt())
        tvl = yv.strategies(strategy)["totalDebt"] / strategy.balanceOfBptInMasterChef() * pool.totalSupply()
        tvls.append(tvl)
    print(f'== tvls ==')
    print(tvls)

    length = len(tvls)
    A = numpy.zeros((length, length))
    b = numpy.zeros((length, 1))

    x = 0
    for i in range(0, length):
        A[x, i] = 1

    coeffs = []
    for i in range(1, len(tvls)):
        tvl1 = tvls[i - 1]
        strat1 = strategies[i - 1]
        tvl2 = tvls[i]
        strat2 = strategies[i]
        print(Contract(strat1.bpt()).getPoolId())
        coeffs.append(coefficients(tvl1, aprs[str(Contract(strat1.bpt()).getPoolId())], tvl2, aprs[str(Contract(strat2.bpt()).getPoolId())]))

    x += 1
    for coeff in coeffs:
        A[x, x - 1] = coeff[1]
        A[x, x] = coeff[2]
        b[x, 0] = coeff[0]
        x += 1

    print(f'== A ==')
    print(A)
    print(f'== b ==')
    print(b)
    x = numpy.linalg.lstsq(A, b)
    print(f'== x ==')
    print(x)


def coefficients(tvl1, apy1, tvl2, apy2):
    a, b = sympy.symbols('a,b')
    l = (tvl1 * apy1) * (tvl2 + b)
    r = (tvl2 * apy2) * (tvl1 + a)
    eq = sympy.simplify(l - r)
    (constant, variables) = eq.as_coeff_Add()

    return (constant * -1, variables.coeff(a, 1), variables.coeff(b, 1))
