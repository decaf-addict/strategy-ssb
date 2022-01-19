from brownie import Contract


def main():
    # DAI
    ssbeet_staBeetPool_dai = Contract("0xB905eabA7A23424265638bdACFFE55564c7B299B")
    ssbeet_guqinQiPool_dai = Contract("0x85c307D24da7086c41537b994de9bFc4C21BAEB5")

    # USDC
    ssbeet_staBeetPool_usdc = Contract("0x56aF79e182a7f98ff6d0bF99d589ac2CabA24e2d")
    ssbeet_guqinQiPool_usdc = Contract("0xBd3791F3Dcf9DD5633cd30662381C80a2Cd945bd")
    ssbeet_beetXlpMimUsdcUsdtPool_usdc = Contract("0x4003eE222d44953B0C3eB61318dD211a4A6f109f")
    ssbeet_mimUsdcUstPool_usdc = Contract("0x1c13C43f8F2fa0CdDEE6DFF6F785757650B8c2BF")
    ssbeet_asUsdcPool_usdc = Contract("0x8Bb79E595E1a21d160Ba3f7f6C94efF1484FB4c9")

    # MIM
    ssbeet_beetXlpMimUsdcUsdtPool_mim = Contract("0xbBdc83357287a29Aae30cCa520D4ed6C750a2a11")
    ssbeet_mimUsdcUstPool_mim = Contract("0xfD7E0cCc4dE0E3022F47834d7f0122274c37a0d1")

    # USDT
    ssbeet_beetXlpMimUsdcUsdtPool_usdt = Contract("0x36E74086C388305CEcdeff83d6cf31a2762A3c91")

    ssbs = [
        ssbeet_staBeetPool_dai,
        ssbeet_guqinQiPool_dai,
        ssbeet_staBeetPool_usdc,
        ssbeet_guqinQiPool_usdc,
        ssbeet_beetXlpMimUsdcUsdtPool_usdc,
        ssbeet_mimUsdcUstPool_usdc,
        ssbeet_asUsdcPool_usdc,
        ssbeet_mimUsdcUstPool_mim,
        ssbeet_beetXlpMimUsdcUsdtPool_mim,
        ssbeet_beetXlpMimUsdcUsdtPool_usdt
    ]

    profits = 0;
    for ssb in ssbs:
        yv = Contract(ssb.vault())
        profit = yv.balanceOf(ssb) / (10 ** yv.decimals())
        print(f'{ssb.name()} has {profit}')
        profits += profit
        
    print(f'estimated total: {profits}')
