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
