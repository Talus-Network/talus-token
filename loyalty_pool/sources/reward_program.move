module loyalty_pool::reward_program;

use std::string::String;
use sui::balance::Balance;
use sui::coin::Coin;
use sui::event;
use sui::object::id;
use sui::token::{Token, spend, add_approval, confirm_request_mut, TokenPolicy};

const EPoolInsufficient: u64 = 0;

public struct ProgramFreshEvent has copy, drop {
    pool: ID,
    amount: u64,
}

public struct RedeemEvent has copy, drop {
    name: String,
    amount: u64,
    user: address,
}

public struct RewardProgram has drop {}

public struct RewardPool<phantom Loyalty, phantom Reward> has key, store {
    id: UID,
    balance: Balance<Reward>,
    rate: u32,
}

entry fun new_reward_pool<Loyalty, Reward>(coin: Coin<Reward>, rate: u32, ctx: &mut TxContext) {
    transfer::share_object(RewardPool<Loyalty, Reward> {
        id: object::new(ctx),
        balance: coin.into_balance(),
        rate: rate,
    });
}

entry fun reward_fresh<Loyalty, Reward>(
    pool: &mut RewardPool<Loyalty, Reward>,
    coin: Coin<Reward>,
) {
    event::emit(ProgramFreshEvent {
        pool: id(pool),
        amount: coin.value(),
    });

    pool.balance.join(coin.into_balance());
}

/// Buy a gift for 10 tokens. The `Gift` is received, and the `Token` is
/// spent (stored in the `ActionRequest`'s `burned_balance` field).
entry fun claim<Loyalty, Reward>(
    pool: &mut RewardPool<Loyalty, Reward>,
    token: Token<Loyalty>,
    policy: &mut TokenPolicy<Loyalty>,
    ctx: &mut TxContext,
) {
    let claim = token.value().divide_and_round_up(pool.rate as u64);

    assert!(claim <= pool.balance.value(), EPoolInsufficient);

    let mut req = spend(token, ctx);
    add_approval(RewardProgram {}, &mut req, ctx);

    let (name, amount, user, _) = confirm_request_mut(policy, req, ctx);

    transfer::public_transfer(pool.balance.split(claim).into_coin(ctx), ctx.sender());
    event::emit(RedeemEvent {
        name,
        amount,
        user,
    });
}
