from pathlib import Path

from brownie import Strategy, accounts, config, network, project, web3
from eth_utils import is_checksum_address
import click

API_VERSION = config["dependencies"][0].split("@")[-1]
Vault = project.load(
    Path.home() / ".brownie" / "packages" / config["dependencies"][0]
).Vault


def get_address(msg: str, default: str = None) -> str:
    val = click.prompt(msg, default=default)

    # Keep asking user for click.prompt until it passes
    while True:

        if is_checksum_address(val):
            return val
        elif addr := web3.ens.address(val):
            click.echo(f"Found ENS '{val}' [{addr}]")
            return addr

        click.echo(
            f"I'm sorry, but '{val}' is not a checksummed address or valid ENS record"
        )
        # NOTE: Only display default once
        val = click.prompt(msg)


def main():
    print(f"You are using the '{network.show_active()}' network")
    dev = accounts.load(click.prompt("Account", type=click.Choice(accounts.load())))
    print(f"You are using: 'dev' [{dev.address}]")

    if input("Is there a Vault for this strategy already? y/[N]: ").lower() == "y":
        vault = Vault.at(get_address("Deployed Vault: "))
        assert vault.apiVersion() == API_VERSION
    else:
        print("You should deploy one vault using scripts from Vault project")
        return  # TODO: Deploy one using scripts from Vault project

    print(
        f"""
    Strategy Parameters

       api: {API_VERSION}
     token: {vault.token()}
      name: '{vault.name()}'
    symbol: '{vault.symbol()}'
    """
    )
    publish_source = click.confirm("Verify source on etherscan?")
    if input("Deploy Strategy? y/[N]: ").lower() != "y":
        return

    balancer_vault = "0x20dd72Ed959b6147912C2e529F0a0C651c33c9ce"
    pool = "0xD163415BD34EF06f57C58D2AEd5A5478AfB464cC"
    masterchef = "0x8166994d9ebBe5829EC86Bd81258149B87faCfd3"
    strategy = Strategy.deploy(vault, balancer_vault, pool, masterchef, 50, 50, 100_000, 2 * 60 * 60, 10, {"from": dev}, publish_source=publish_source)
