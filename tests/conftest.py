import pytest
from brownie import config
from brownie import Contract


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def token():
    # 0x6B175474E89094C44Da98b954EedeAC495271d0F DAI
    # 0x049d68029688eAbF473097a2fC38ef61633A3C7A fUSDT
    # 0x04068DA6C83AFCFA0e13ba15A6696662335D5B75 USDC
    token_address = "0x82f0B8B456c1A451378467398982d4834b6829c1"
    yield Contract(token_address)


@pytest.fixture
def token_whale(accounts):
    # 0x2dd7C9371965472E5A5fD28fbE165007c61439E1 MIM
    # 0x2dd7C9371965472E5A5fD28fbE165007c61439E1 fUSDT
    # 0x2dd7C9371965472E5A5fD28fbE165007c61439E1 USDC
    return accounts.at("0x2dd7C9371965472E5A5fD28fbE165007c61439E1", force=True)


@pytest.fixture
def amount(accounts, token, user, token_whale):
    amount = 1_000_000 * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    token.transfer(user, amount, {"from": token_whale})
    yield amount


@pytest.fixture
def wftm():
    token_address = "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83"
    yield Contract(token_address)


@pytest.fixture
def beets():
    token_address = "0xF24Bcf4d1e507740041C9cFd2DddB29585aDCe1e"
    yield Contract(token_address)


@pytest.fixture
def usdc():
    token_address = "0x04068DA6C83AFCFA0e13ba15A6696662335D5B75"
    yield Contract(token_address)


@pytest.fixture
def beets_whale(accounts):
    yield accounts.at("0xa2503804ec837D1E4699932D58a3bdB767DeA505", force=True)


@pytest.fixture
def wftm_amount(user, wftm, accounts):
    wftm_amount = 10 ** wftm.decimals()
    whale = accounts.at("0x20dd72Ed959b6147912C2e529F0a0C651c33c9ce", force=True)
    wftm.transfer(user, wftm_amount, {'from': whale})
    yield wftm_amount


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian, management, {"from": gov})
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def balancer_vault():
    yield Contract("0x20dd72Ed959b6147912C2e529F0a0C651c33c9ce")


@pytest.fixture
def pool():
    # 0xD163415BD34EF06f57C58D2AEd5A5478AfB464cC MIM-USDC-USDT Stable Pool
    address = "0xD163415BD34EF06f57C58D2AEd5A5478AfB464cC"
    yield Contract(address)


@pytest.fixture
def masterChef():
    address = "0x8166994d9ebBe5829EC86Bd81258149B87faCfd3"
    yield Contract(address)


@pytest.fixture
def beetsUsdcPool():
    address = "0x03c6B3f09D2504606936b1A4DeCeFaD204687890"
    yield Contract(address)


@pytest.fixture
def beetsUsdcPoolId():
    yield 0x03c6b3f09d2504606936b1a4decefad204687890000200000000000000000015


@pytest.fixture
def usdcTokenPoolId():
    id = 0xd163415bd34ef06f57c58d2aed5a5478afb464cc00000000000000000000000e  # usdc-mim
    yield id


@pytest.fixture
def swapStepsBeets(beetsUsdcPoolId, usdcTokenPoolId, beets, usdc, token):
    yield ([beetsUsdcPoolId, usdcTokenPoolId], [beets, usdc, token])


@pytest.fixture
def strategy(strategist, keeper, vault, Strategy, gov, balancer_vault, pool, beets, usdc, beetsUsdcPool, management,
             masterChef,
             swapStepsBeets):
    strategy = strategist.deploy(Strategy, vault, balancer_vault, pool, masterChef, 50, 50, 100_000, 2 * 60 * 60, 10)
    strategy.setKeeper(keeper)
    strategy.whitelistReward(beets, swapStepsBeets, {'from': gov})
    strategy.setStakeParams(8000, 7000, [usdc, beets], beetsUsdcPool, 1, 0, {'from': gov})
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    # making this more lenient bc of single
    # sided deposits incurring slippage
    yield 1e-3
