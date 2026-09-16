"""Check token publication records, consumer linkage, and deployed module bytes."""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib


ROOT = Path(__file__).resolve().parents[2]
TOKEN = ROOT / "talus"
CONSUMER = ROOT / "Tests" / "dependency"
DEPLOYMENTS = {
    "mainnet": (
        "35834a8a",
        "0xee962a61432231c2ede6946515beb02290cb516ad087bb06a731e922b2a5f57a",
    ),
    "testnet": (
        "4c78adac",
        "0x5f1861ac8198fae5dc6ec79e435d653d08167187ad8c0522c34f34c372853c5a",
    ),
}
# SHA256 of the single module submitted in both successful publications:
# Mainnet: EwmnFH7uYr9uDALhSNqdkQQzEqBn3ryS6vE2iYWm1agg
# Testnet: 9VH4oB8Xi6uA69nqTTNbaxwooZgRCJC3s95CEDxkETqE
# Publication bytes have the module's own address set to zero.
MODULE_SHA256 = "fd276ffb8e5c75685315b7a931a2a453015aeb1b0faa245c0a2c491aaa6b5e0f"


def run_sui(binary, *args):
    result = subprocess.run(
        [binary, *args], check=True, capture_output=True, text=True,
    )
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    return result.stdout


def check_publications():
    with (TOKEN / "Published.toml").open("rb") as source:
        records = tomllib.load(source)["published"]
    if set(records) != set(DEPLOYMENTS):
        raise ValueError("Publication records must contain Mainnet and Testnet")
    for network, (chain, package) in DEPLOYMENTS.items():
        expected = {
            "chain-id": chain,
            "published-at": package,
            "original-id": package,
            "version": 1,
            "toolchain-version": "1.59.1",
        }
        for key, value in expected.items():
            if records[network].get(key) != value:
                raise ValueError(f"Unexpected {network} publication field: {key}")


def module_bytes(build):
    if len(build["modules"]) != 1:
        raise ValueError("Expected exactly one module")
    return base64.b64decode(build["modules"][0], validate=True)


def check_bytecode(binary):
    version = run_sui(binary, "--version").split()[1].split("-")[0]
    if version != "1.59.1":
        raise ValueError("Bytecode reproduction requires Sui 1.59.1")
    # The release compiler supplies its pinned framework. Compile in isolation
    # so the current package manager's lockfile stays intact.
    with tempfile.TemporaryDirectory(prefix="talus_verify_") as directory:
        package = Path(directory)
        shutil.copyfile(TOKEN / "Move.toml", package / "Move.toml")
        shutil.copytree(TOKEN / "sources", package / "sources")
        build = json.loads(run_sui(
            binary, "move", "build", "--path", str(package),
            "--dump-bytecode-as-base64", "--ignore-chain",
        ))
    digest = hashlib.sha256(module_bytes(build)).hexdigest()
    if digest != MODULE_SHA256:
        raise ValueError(f"Token module differs from the deployed bytecode: {digest}")
    print("Token bytecode matches the published Mainnet and Testnet module")


def check_dependency(binary, network):
    build = json.loads(run_sui(
        binary, "move", "build", "--path", str(CONSUMER), "-e", network,
        "--dump-bytecode-as-base64", "--no-tree-shaking",
    ))
    package = DEPLOYMENTS[network][1]
    dependencies = {int(address, 16) for address in build["dependencies"]}
    if int(package, 16) not in dependencies:
        raise ValueError(f"Consumer does not link the {network} token package")
    for other_network, (_, other_package) in DEPLOYMENTS.items():
        if other_network != network and int(other_package, 16) in dependencies:
            raise ValueError(f"Consumer unexpectedly links the {other_network} token")
    if bytes.fromhex(package[2:]) not in module_bytes(build):
        raise ValueError("Consumer bytecode does not reference the expected token type")
    print(f"Consumer uses the correct {network} token: {package}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sui", default="sui", help="Path to the Sui binary")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("bytecode", help="Reproduce the token with Sui 1.59.1")
    dependency = commands.add_parser("dependency", help="Check consumer linkage")
    dependency.add_argument("network", choices=DEPLOYMENTS)
    args = parser.parse_args()
    check_publications()
    if args.command == "bytecode":
        check_bytecode(args.sui)
    else:
        check_dependency(args.sui, args.network)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(error.stdout or "", file=sys.stderr, end="")
        print(error.stderr or "", file=sys.stderr, end="")
        sys.exit(error.returncode)
    except (OSError, ValueError, KeyError) as error:
        sys.exit(str(error))
