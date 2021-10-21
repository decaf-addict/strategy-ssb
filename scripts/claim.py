import urllib.request, json
from brownie import Contract, accounts, web3
import click


def main():
    dev = accounts.load(click.prompt("Account", type=click.Choice(accounts.load())))
    merkleOrchard = Contract("0xdAE7e32ADc5d490a43cCba1f0c736033F2b4eFca")

    ssb_dai = Contract("0x9cff0533972da48ac05a00a375cc1a65e87da7ec")
    ssb_usdt = Contract("0x3ef6ec70d4d8fe69365c92086d470bb7d5fc92eb")
    ssb_usdc = Contract("0x520bf095fa58cb3f68c18d01746041733a1f7b85")
    ssb_wbtc = Contract("0x7c1612476d235c8054253c83b98f7ca6f7f2e9d0")

    dai_proof = [
        '0x642777898d82ee9ec859d0573b0ef9f9a08ab88c104f6549981f205a7be30a7e',
        '0x596c6c9ef0c2706d32d17cbb67d651c813d0c66667d2a5065f6f45471eb5e96c',
        '0x3e1eee950cb08c564431455d34b6d2650d605213c88d6ddaf950c8dfc1fd06da',
        '0xd356683393845ff2f1ede1df3781ff184e49ab5f4dcb6439e8dc90ace01cb499',
        '0x22d2dfb89ac5338a4eeb0f8f5fd9ab2f43846d3d7a7de87a149ed07345b40e52',
        '0x1a85b24e1f3e1d9092c886f88dd1caa66ebbb7e507c077077ff8283fec95c247',
        '0xf0eab6ddb6cc0b318b9be3be10f4f73de39bc8f0930a77f8365f0ab64715d68f',
        '0xbe3cfb3405756bede3bf7f24e1e1fd558a490f43475f3787bf292bacd0b3fd2d',
        '0x701e27a271b8ea17077a4304ed8ef8d3c063cb7dc2997855842ee3bac5059a64',
        '0xbc2e054e3e1e5d619353260444a6fca348d94e3efb93ea59417ec030cfbf108b',
        '0x5d55951953546f8a323c2757edcf82e75d6cbf722b9ae61fa6c77f0ddb5206c9',
        '0x1476d27ed99b613a844e98c12285f2cb07ca33a561f609ba4ad3e405c843ac5f'
    ]
    usdt_proof = [
        '0xd07c225a56a7503a30ccd966e8bcad393d58175d1f57d9e379661360d52a5691',
        '0x0f8d9f23e64c0771179c0bc2ecc4abe1dd8151ce82f968e3012dd6f3372b718f',
        '0xe39cbddcb0fb378e42972448ce4ee943c04d0c8b69d054d5e66030a15bc9acea',
        '0x9844ebe7bd8660bb1b53b0ad3b92b31eaecaba47248504409cd3f3bf26399487',
        '0xee2033d3ccc28dea3a4f06c9af12883195b82149a5258a93f3b628a5cc52bff8',
        '0x5c096dd017417bf50c3786618f9008544bd3c50f5dc43704b3451675bc3f15e3',
        '0x60884a0562e8cf9f1903de1e334e6f96f523eed68008f280cb1a2bde9f2a0fc0',
        '0xb5c3b31bc6f4402ed56acb15377e708163cf9e71e296a391c35eb27fc4838394',
        '0x340816abb5318f91a141a9d9c8e05cb3aaf66d6ef795a088870aa4cc6df9c79a',
        '0x7dbf71a2d9ec35c99af6159cf94bcbde123b2c1a6aaf829309e6c0931eb6529f',
        '0x6ed645d9b5a25b02e2671f9745ba560c736329e8f1767baf98c52a2df1da8ff1',
        '0xdd5933661c2b5728dcaf0f3f96893d66f1ed0457288e2d3cf738b324f4761a5b'
    ]
    usdc_proof = [
        '0xb708f68e52e0ec802f76328131e4f7e5af3fa01925a73733c7f1bb56b3ddd74f',
        '0xf898ea841435784e3376a58c38aaf3c6d3bb8d6ad544f69ae95cc0c3aeb66774',
        '0x9bf7f97a16581a2a619e79a03b1aa289d5776bba3fa26117c2131cb0b3cdacc1',
        '0xf1e5a60c6625d4f30ca385a592e77bb780c2ec693edb56b9e881b55308430c8d',
        '0xcfac69aa6413528c0bcfec8c41f970ee8eff2122fbf27ea0b5ffb7c09fdf3243',
        '0xf93068432846a6d1138b86d6342cec8effb6592755aa2168cb446067f719be64',
        '0x1f873f96ad260a2c017b4363b7018565fcc52a3209da61e293759011c8814bf7',
        '0x52513e3b4fad3f68e98c588984db741e2d6a43988e915f8397aa417d46dcfcde',
        '0xad3b95bd9d983ebe1d7774eecc72dd62548c1db4ae96d5fa8862925c58dd94e2',
        '0x7dbf71a2d9ec35c99af6159cf94bcbde123b2c1a6aaf829309e6c0931eb6529f',
        '0x6ed645d9b5a25b02e2671f9745ba560c736329e8f1767baf98c52a2df1da8ff1',
        '0xdd5933661c2b5728dcaf0f3f96893d66f1ed0457288e2d3cf738b324f4761a5b'
    ]
    wbtc_proof = [
        '0xd0a37d7487d2442852e63e22bea3b6b7a6452fc01a0662a3806d325dd7e33974',
        '0xcbe923b51d058d89570edb6c6c125a282aa0b76a6af1c5ece93ef81e26e0ef7a',
        '0xe39cbddcb0fb378e42972448ce4ee943c04d0c8b69d054d5e66030a15bc9acea',
        '0x9844ebe7bd8660bb1b53b0ad3b92b31eaecaba47248504409cd3f3bf26399487',
        '0xee2033d3ccc28dea3a4f06c9af12883195b82149a5258a93f3b628a5cc52bff8',
        '0x5c096dd017417bf50c3786618f9008544bd3c50f5dc43704b3451675bc3f15e3',
        '0x60884a0562e8cf9f1903de1e334e6f96f523eed68008f280cb1a2bde9f2a0fc0',
        '0xb5c3b31bc6f4402ed56acb15377e708163cf9e71e296a391c35eb27fc4838394',
        '0x340816abb5318f91a141a9d9c8e05cb3aaf66d6ef795a088870aa4cc6df9c79a',
        '0x7dbf71a2d9ec35c99af6159cf94bcbde123b2c1a6aaf829309e6c0931eb6529f',
        '0x6ed645d9b5a25b02e2671f9745ba560c736329e8f1767baf98c52a2df1da8ff1',
        '0xdd5933661c2b5728dcaf0f3f96893d66f1ed0457288e2d3cf738b324f4761a5b'
    ]
    tokens = ["0xba100000625a3754423978a60c9317c58a424e3D"]
    # claim = [(52, 1218133826982322000000, "0xd2EB7Bd802A7CA68d9AcD209bEc4E664A9abDD7b", 0, dai_proof)]
    # merkleOrchard.claimDistributions(ssb_dai, claim, tokens, {'from': dev, 'priority_fee': '1 gwei', 'max_fee': '130 gwei'})
    claim = [(52, 255781973303166000000, "0xd2EB7Bd802A7CA68d9AcD209bEc4E664A9abDD7b", 0, usdt_proof)]
    merkleOrchard.claimDistributions(ssb_usdt, claim, tokens, {'from': dev, 'priority_fee': '1 gwei', 'max_fee': '130 gwei'})
    claim = [(52, 121102189755154000000, "0xd2EB7Bd802A7CA68d9AcD209bEc4E664A9abDD7b", 0, usdc_proof)]
    merkleOrchard.claimDistributions(ssb_usdc, claim, tokens, {'from': dev, 'priority_fee': '1 gwei', 'max_fee': '130 gwei'})
    claim = [(52, 130117773103245000000, "0xd2EB7Bd802A7CA68d9AcD209bEc4E664A9abDD7b", 0, wbtc_proof)]
    merkleOrchard.claimDistributions(ssb_wbtc, claim, tokens, {'from': dev, 'priority_fee': '1 gwei', 'max_fee': '130 gwei'})

