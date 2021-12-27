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
# 12 The Magic Touch by Daniele
# 13 The Sound of Moosic
# 14 0x7cA132d9E8c420b84578a6618F10b23545513058
# 15 Fantom Conservatory of Music
# 16 Guqin qi
# 17 A Late Quartet
# 18 A Song of Ice and Fire
# 19 Tubular Bells: Curved and Linked
# 20 When Two Became One (Hundred)
# 21 Baron von Binance
# 22 FreshBeets
# 23 0x63386eF152E1Ddef96c065636D6cC0165Ff33291
# 24 0x41870439b607A29293D48f7c9da10e6714217624
# 25 Daniele and Do's Double Dollar Fugue
# 26 Beethoven's Battle of the Bands
# 27 Variations on a theme by USD Circle
# 28 BeethovenxOhmEmissionToken

def main():
    masterChef = Contract("0x8166994d9ebBe5829EC86Bd81258149B87faCfd3")
    for i in range(masterChef.poolLength()):
        try:
            pool = Contract(masterChef.lpTokens(i))
            print(f'{i} {pool.name()}')
        except ValueError:
            print(f'{i} {masterChef.lpTokens(i)}')

