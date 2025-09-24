/// This module implements a bi-directional faucet for exchanging two types of coins
/// at a fixed exchange rate. The faucet allows users to:
/// - Mint coin Target using coin Base at a fixed exchange rate
/// - Refund coin Base by returning coin Target
/// - Inject additional liquidity
///
/// # Examples
/// ```
/// // Create a new faucet with TOKEN coin, exchange rate of 2 (2 Token = 1 USDC)
/// faucet::initiate<TOKEN, USDC>(coin, 2, 10, ctx);
///
/// // Mint TOKEN using USDC
/// faucet::mint(faucet, usdc_coin, ctx);
///
/// // Refund USDC by returning TOKEN
/// faucet::refund(faucet, token_coin, ctx);
/// ```
module faucet::faucet;

use std::u64::min;
use sui::balance::{Balance, zero};
use sui::coin::Coin;

const MAX_PCT: u64 = 100;

/// Reserve container holding balances of two coin types.
/// Exchange happens at a fixed rate between coin Target and coin Base.
/// Withdrawals are limited to a percentage of total reserves.
///
/// * `target_balance` - Balance of coin type Target
/// * `base_balance` - Balance of coin type Base
/// * `exchange_rate` - Number of coin Target per coin Base
/// * `withdrawal_pct` - Maximum withdrawal percentage per call
public struct BiFaucet<phantom Target, phantom Base> has key, store {
    id: UID,
    target_balance: Balance<Target>,
    base_balance: Balance<Base>,
    exchange_rate: u64,
    max_withdrawal_pct: u64,
}

/// Creates a new shared faucet with initial liquidity of coin Target.
///
/// # Parameters
/// * `initial_token` - Initial deposit of coin Target
/// * `exchange_rate` - Number of coin Target per coin Base
/// * `withdrawal_pct` - Maximum withdrawal percentage per transaction (must be < 100)
/// * `ctx` - Transaction context
entry fun new<Target, Base>(
    initial_tokens: Coin<Target>,
    exchange_rate: u64,
    max_withdrawal_pct: u64,
    ctx: &mut TxContext,
) {
    assert!(max_withdrawal_pct < MAX_PCT, 1);
    let faucet = BiFaucet<Target, Base> {
        id: object::new(ctx),
        target_balance: initial_tokens.into_balance(),
        base_balance: zero(),
        exchange_rate,
        max_withdrawal_pct,
    };
    // Make the faucet shared so anyone can call donate/swap.
    transfer::share_object(faucet);
}

/// Adds more coin Target to the faucet's reserves.
///
/// # Parameters
/// * `faucet` - Faucet to inject coins into
/// * `target_coin` - Coin Target to add to reserves
public fun inject<Target, Base>(faucet: &mut BiFaucet<Target, Base>, target_coin: Coin<Target>) {
    faucet.target_balance.join(target_coin.into_balance());
}

/// Mints coin Target in exchange for coin Base at the fixed exchange rate.
/// Limited to withdrawal_pct of total reserves per transaction.
///
/// # Parameters
/// * `self` - Faucet to mint from
/// * `base_coin` - Coin Base to exchange
/// * `ctx` - Transaction context
#[allow(lint(self_transfer))]
public fun mint<Target, Base>(
    self: &mut BiFaucet<Target, Base>,
    mut base_coin: Coin<Base>,
    ctx: &mut TxContext,
) {
    let (max_mint, _) = self.max_withdrawal();
    let collateral = min(max_mint/self.exchange_rate, base_coin.value());
    let deposit = base_coin.split(collateral, ctx).into_balance();

    self.base_balance.join(deposit);

    if (base_coin.value() > 0) {
        transfer::public_transfer(base_coin, ctx.sender());
    } else {
        base_coin.destroy_zero();
    };

    transfer::public_transfer(
        self.target_balance.split(collateral*self.exchange_rate).into_coin(ctx),
        ctx.sender(),
    );
}

/// Refunds coin Base in exchange for returning coin Target at the fixed exchange rate.
/// Limited to withdrawal_pct of total reserves per transaction.
///
/// # Parameters
/// * `self` - Faucet to refund from
/// * `target_coin` - Coin Target to return
/// * `ctx` - Transaction context
#[allow(lint(self_transfer))]
public fun refund<Target, Base>(
    self: &mut BiFaucet<Target, Base>,
    mut target_coin: Coin<Target>,
    ctx: &mut TxContext,
) {
    // return at most 10% of Target
    let (_, max_collateral) = self.max_withdrawal();
    let allowed_collateral = min(max_collateral, target_coin.value()/self.exchange_rate);
    let deposit = target_coin.split(allowed_collateral*self.exchange_rate, ctx).into_balance();

    self.target_balance.join(deposit);

    if (target_coin.value() > 0) {
        transfer::public_transfer(target_coin, ctx.sender());
    } else {
        target_coin.destroy_zero();
    };

    transfer::public_transfer(
        self.base_balance.split(allowed_collateral).into_coin(ctx),
        ctx.sender(),
    )
}

/// Returns the maximum withdrawal amounts for both coin types based on withdrawal_pct.
///
/// # Returns
/// * `(u64, u64)` - (max coin Target withdrawal, max coin Base withdrawal)
public(package) fun max_withdrawal<Target, Base>(self: &BiFaucet<Target, Base>): (u64, u64) {
    (
        (self.target_balance.value() / MAX_PCT) * self.max_withdrawal_pct,
        (self.base_balance.value() / MAX_PCT) * self.max_withdrawal_pct,
    )
}

#[test_only]
/// Returns current balances and parameters of the faucet for testing.
///
/// # Returns
/// * `(u64,u64,u64,u64)` - (reserve Target amount, reserve Base amount, exchange rate, withdrawal percentage)
public fun get_balance_for_testing<Target, Base>(
    self: &BiFaucet<Target, Base>,
): (u64, u64, u64, u64) {
    (
        self.target_balance.value(),
        self.base_balance.value(),
        self.exchange_rate,
        self.max_withdrawal_pct,
    )
}
