from brownie import Contract
import time

# 0 Symphony Nr 10. Opus 138.
# 1 The Grand Orchestra
# 2 Steady Beets
# 3 FTM Sonata
# 4 The E Major
# 5 The B Major
# 6 The Classic Trio
# 7 Dance of the Degens
# 8 Fantom of the Opera
# 9 The Fidelio Duetto
# 10 MIM-USDC-USDT Stable Pool
# 11 Guqin qi

def main():
    masterChef = Contract("0x8166994d9ebBe5829EC86Bd81258149B87faCfd3")
    for i in range(masterChef.poolLength()):
        pool = Contract(masterChef.lpTokens(i))
        print(f'{i} {pool.name()}')
        time.sleep(3)