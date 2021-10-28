from brownie import Contract


def main():
    vault = [Contract("0x20dd72Ed959b6147912C2e529F0a0C651c33c9ce"), "vault"]
    stablePool = [Contract("0xD163415BD34EF06f57C58D2AEd5A5478AfB464cC"), "stablepool"]
    lbp = [Contract("0x03c6b3f09d2504606936b1a4decefad204687890"), "lbp"]
    protocolFeesCollector = [Contract("0xC6920d3a369E7c8BD1A22DbE385e11d1F7aF948F"), "fees collector"]
    authorizor = Contract("0x974D3FF709D84Ba44cde3257C0B5B0b14C081Ce9")
    timelock = Contract("0xB5CaEe3CD5d86c138f879B3abC5B1bebB63c6471")
    masterchef = Contract("0x8166994d9ebBe5829EC86Bd81258149B87faCfd3")
    contracts = [vault, stablePool, protocolFeesCollector, lbp]
    grantedRoles = {}

    for contract in contracts:
        selectors = contract[0].selectors
        for key in selectors:
            role = contract[0].getActionId(key)
            count = authorizor.getRoleMemberCount(role)

            for i in range(0, count):
                member = authorizor.getRoleMember(role, i)
                s = f'{contract[1]} {selectors[key]}:'
                grantedRoles[s] = member
    grantedRoles[f'{"timelock admin": }'] = timelock.admin()
    grantedRoles[f'{"masterchef owner": }'] = masterchef.owner()

    for key in grantedRoles:
        print(f'{key} {grantedRoles[key]}')
