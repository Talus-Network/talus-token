// Copyright (c) Talus Network
// SPDX-License-Identifier: Apache-2.0

/// The TALUS token is the native token for the Nexus Protocol.
module talus::talus;

use sui::coin::{Self, TreasuryCap, Coin};
use sui::dynamic_object_field as dof;
use sui::url;

const TOTAL_TALUS_SUPPLY_TO_MINT: u64 = 10_000_000_000; // 10B TALUS
const DECIMALS: u8 = 9;
const SYMBOL: vector<u8> = b"TALUS";
const NAME: vector<u8> = b"TALUS Token";
const DESCRIPTION: vector<u8> = b"The native token for the TALUSrus Protocol.";
// todo need to update
const ICON_URL: vector<u8> = b"https://talus.network/talus-icon.svg";

/// The OTW for the `TALUS` coin.
public struct TALUS has drop {}

public struct ProtectedTreasury has key {
    id: UID,
}

/// Key for the dynamic object field of the `TreasuryCap`.
///
/// Storing the `TreasuryCap` as a dynamic object field allows us to easily look up the
/// `TreasuryCap` from the `ProtectedTreasury` off-chain.
public struct TreasuryCapKey has copy, drop, store {}

/// Initializes the TALUS token and mints the total supply to the publisher.
/// This also wraps the `TreasuryCap` in a `ProtectedTreasury` analogous to the SuiNS token.
///
/// After publishing this, the `UpgradeCap` must be burned to ensure that the supply
/// of minted TALUS cannot change.
#[allow(lint(share_owned))]
fun init(otw: TALUS, ctx: &mut TxContext) {
    let (mut cap, metadata) = coin::create_currency(
        otw,
        DECIMALS,
        SYMBOL,
        NAME,
        DESCRIPTION,
        option::some(url::new_unsafe_from_bytes(ICON_URL)),
        ctx,
    );

    // Mint the total supply of TALUS.
    let frost_per_TALUS = 10u64.pow(DECIMALS);
    let total_supply_to_mint = TOTAL_TALUS_SUPPLY_TO_MINT * frost_per_TALUS;
    let minted_coin = cap.mint(total_supply_to_mint, ctx);

    transfer::public_freeze_object(metadata);

    // Wrap the `TreasuryCap` and share it.
    let mut protected_treasury = ProtectedTreasury {
        id: object::new(ctx),
    };
    dof::add(&mut protected_treasury.id, TreasuryCapKey {}, cap);
    transfer::share_object(protected_treasury);

    // Transfer the minted TALUS to the publisher.
    transfer::public_transfer(minted_coin, ctx.sender());
}

/// Get the total supply of the TALUS token.
public fun total_supply(treasury: &ProtectedTreasury): u64 {
    treasury.borrow_cap().total_supply()
}

/// Burns a `Coin<TALUS>` from the sender.
public fun burn(treasury: &mut ProtectedTreasury, coin: Coin<TALUS>) {
    treasury.borrow_cap_mut().burn(coin);
}

// ===== Private Accessors =====

/// Borrows the `TreasuryCap` from the `ProtectedTreasury`.
fun borrow_cap(treasury: &ProtectedTreasury): &TreasuryCap<TALUS> {
    dof::borrow(&treasury.id, TreasuryCapKey {})
}

/// Borrows the `TreasuryCap` from the `ProtectedTreasury` as mutable.
fun borrow_cap_mut(treasury: &mut ProtectedTreasury): &mut TreasuryCap<TALUS> {
    dof::borrow_mut(&mut treasury.id, TreasuryCapKey {})
}

// ===== Tests =====

#[test_only]
use sui::test_scenario as test;

#[test]
fun test_init() {
    let user = @0xa11ce;
    let mut test = test::begin(user);
    init(TALUS {}, test.ctx());
    test.next_tx(user);

    let protected_treasury = test.take_shared<ProtectedTreasury>();
    let frost_per_TALUS = 10u64.pow(DECIMALS);
    let talus_supply = 5_000_000_000;
    assert!(protected_treasury.total_supply() == talus_supply * frost_per_TALUS);
    test::return_shared(protected_treasury);

    let coin_metadata = test.take_immutable<coin::CoinMetadata<TALUS>>();

    assert!(coin_metadata.get_decimals() == 9);
    assert!(coin_metadata.get_symbol() == b"TALUS".to_ascii_string());
    assert!(coin_metadata.get_name() == b"TALUS Token".to_string());
    assert!(
        coin_metadata.get_description() ==
            b"The native token for the TALUS Protocol.".to_string(),
    );
    assert!(
        coin_metadata.get_icon_url() == option::some(
            url::new_unsafe_from_bytes(b"https://www.TALUSrus.xyz/TALUS-icon.svg"),
        ),
    );

    test::return_immutable(coin_metadata);
    test.end();
}

#[test]
fun test_burn() {
    let user = @0xa11ce;
    let mut test = test::begin(user);
    init(TALUS {}, test.ctx());
    test.next_tx(user);

    let mut protected_treasury = test.take_shared<ProtectedTreasury>();
    let frost_per_TALUS = 10u64.pow(DECIMALS);
    let talus_supply = 5_000_000_000;
    assert!(protected_treasury.total_supply() == talus_supply * frost_per_TALUS);

    let mut coin = test.take_from_sender<Coin<TALUS>>();
    let new_coin = coin.split(1000 * frost_per_TALUS, test.ctx());
    protected_treasury.burn(new_coin);
    assert!(protected_treasury.total_supply() == (talus_supply - 1000) * frost_per_TALUS);

    test.return_to_sender(coin);
    test::return_shared(protected_treasury);
    test.end();
}
