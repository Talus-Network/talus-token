module loyalty::loyalty;

use sui::coin;

/// The OTW for the Token / Coin.
public struct LOYALTY has drop {}

// Create a new LOYALTY currency, create a `TokenPolicy` for it and allow
// everyone to spend `Token`s if they were `reward`ed.
fun init(otw: LOYALTY, ctx: &mut TxContext) {
    let (treasury_cap, coin_metadata) = coin::create_currency(
        otw,
        0, // no decimals
        b"LOY", // symbol
        b"Talus Loyalty Token", // name
        b"Token for Loyalty US holders", // description
        option::none(), // url
        ctx,
    );

    transfer::public_freeze_object(coin_metadata);
    transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
}

// ===== Tests =====

#[test_only]
use sui::test_scenario as test;
#[test]
fun test_init() {
    use sui::coin::TreasuryCap;

    let user = @0xa11ce;
    let mut test = test::begin(user);
    init(LOYALTY {}, test.ctx());
    test.next_tx(user);

    let treasury_cap = test.take_from_sender<TreasuryCap<LOYALTY>>();
    assert!(treasury_cap.total_supply() == 0);
    test.return_to_sender(treasury_cap);

    let coin_metadata = test.take_immutable<coin::CoinMetadata<LOYALTY>>();

    assert!(coin_metadata.get_decimals() == 0);
    assert!(coin_metadata.get_symbol() == b"LOY".to_ascii_string());
    assert!(coin_metadata.get_name() == b"Talus Loyalty Token".to_string());
    assert!(
        coin_metadata.get_description() ==
            b"Token for Loyalty US holders".to_string(),
    );
    assert!(coin_metadata.get_icon_url() == option::none());

    test::return_immutable(coin_metadata);
    test.end();
}
