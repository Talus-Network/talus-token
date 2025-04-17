/// This module implements a bi-directional faucet for exchanging two types of coins
/// at a fixed exchange rate. The faucet allows users to:
/// - Mint coin A using coin B at a fixed exchange rate
/// - Refund coin B by returning coin A
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

use sui::coin::Coin;
use sui::balance::{Balance,zero};
use sui::object::new;
use std::u64::min;

/// Reserve container holding balances of two coin types.
/// Exchange happens at a fixed rate between coin A and coin B.
/// Withdrawals are limited to a percentage of total reserves.
///
/// * `reserve_a` - Balance of coin type A
/// * `reserve_b` - Balance of coin type B  
/// * `exchange_rate` - Number of coin A per coin B
/// * `withdrawal_pct` - Maximum withdrawal percentage per call
public struct BiFaucet<phantom A, phantom B> has key, store {
    id: UID,
    reserve_a: Balance<A>,
    reserve_b: Balance<B>,
    exchange_rate: u64,
    withdrawal_pct:u64,
}

/// Creates a new shared faucet with initial liquidity of coin A.
/// 
/// # Parameters
/// * `initial_a` - Initial deposit of coin A
/// * `exchange_rate` - Number of coin A per coin B
/// * `withdrawal_pct` - Maximum withdrawal percentage per transaction (must be < 100)
/// * `ctx` - Transaction context
public entry fun initiate<A, B>(
    initial_a: Coin<A>,
    exchange_rate: u64,
    withdrawal_pct:u64,
    ctx: &mut TxContext
) {
    assert!(withdrawal_pct < 100,1);
    let faucet = BiFaucet<A, B> {
        id: new(ctx),
        reserve_a: initial_a.into_balance(),
        reserve_b: zero(),
        exchange_rate:exchange_rate,
        withdrawal_pct:withdrawal_pct,
    };
    // Make the faucet shared so anyone can call donate/swap.
    transfer::share_object(faucet);
}

/// Adds more coin A to the faucet's reserves.
///
/// # Parameters
/// * `faucet` - Faucet to inject coins into
/// * `a` - Coin A to add to reserves
public entry fun inject<A,B>(
    faucet: &mut BiFaucet<A,B>,
    a: Coin<A>
) {
    faucet.reserve_a.join(a.into_balance());
}

/// Mints coin A in exchange for coin B at the fixed exchange rate.
/// Limited to withdrawal_pct of total reserves per transaction.
///
/// # Parameters
/// * `self` - Faucet to mint from
/// * `b` - Coin B to exchange
/// * `ctx` - Transaction context
public entry fun mint<A, B>(
    self: &mut BiFaucet<A, B>,
    b:&mut Coin<B>,
    ctx: &mut TxContext
) {
    
    let (max_mint, _) = self.max_withdrawal();
    let collateral = min(max_mint/self.exchange_rate, b.value());
    let deposit = b.split(collateral, ctx).into_balance();
    
    self.reserve_b.join(deposit);
    
    transfer::public_transfer(self.reserve_a.split(collateral*self.exchange_rate).into_coin(ctx), ctx.sender());
}

/// Refunds coin B in exchange for returning coin A at the fixed exchange rate.
/// Limited to withdrawal_pct of total reserves per transaction.
///
/// # Parameters
/// * `self` - Faucet to refund from  
/// * `a` - Coin A to return
/// * `ctx` - Transaction context
public entry fun refund<A, B>(
    self: &mut BiFaucet<A, B>,
    a: &mut Coin<A>,
    ctx: &mut TxContext
) {
    // return at most 10% of A
    let (_, max_collateral) = self.max_withdrawal();
    let allowed_collateral =min(max_collateral, a.value()/self.exchange_rate);
    let deposit = a.split(allowed_collateral*self.exchange_rate, ctx).into_balance();
    
    self.reserve_a.join(deposit);
    
    transfer::public_transfer(self.reserve_b.split(allowed_collateral).into_coin(ctx), ctx.sender());
}

/// Returns the maximum withdrawal amounts for both coin types based on withdrawal_pct.
///
/// # Returns
/// * `(u64, u64)` - (max coin A withdrawal, max coin B withdrawal)
public(package) fun max_withdrawal<A, B>(
    self: & BiFaucet<A, B>,
):(u64,u64){
      ((self.reserve_a.value()*self.withdrawal_pct)/100, self.reserve_b.value()*self.withdrawal_pct/100)
}

#[test_only]
/// Returns current balances and parameters of the faucet for testing.
///
/// # Returns
/// * `(u64,u64,u64,u64)` - (reserve A amount, reserve B amount, exchange rate, withdrawal percentage)
public fun get_balance_for_testing<A,B>(self: &BiFaucet<A,B>): (u64,u64,u64,u64){
    (self.reserve_a.value(), self.reserve_b.value(),self.exchange_rate,self.withdrawal_pct)
}
