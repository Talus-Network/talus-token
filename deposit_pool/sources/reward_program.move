/// The reward program module define basic reward pools and allows users to claim rewards
/// by spending loyalty tokens. Pools can be refreshed with more rewards, and events
/// are emitted for transparency.
module deposit_pool::reward_program;

use std::string::String;
use sui::balance::Balance;
use sui::coin::Coin;
use sui::event;
use sui::object::id;
use sui::token::{Token, spend, add_approval, confirm_request_mut, TokenPolicy};

/// Error code for insufficient pool balance when claiming rewards
const EPoolInsufficient: u64 = 0;

/// Event emitted when the reward pool is refreshed with new rewards
public struct ProgramFreshEvent has copy, drop {
    pool: ID,
    amount: u64,
}

/// Event emitted when a user redeems a reward
public struct RedeemEvent has copy, drop {
    name: String,
    amount: u64,
    user: address,
}

/// Marker struct for reward program approval
public struct RewardProgram has drop {}

/// Reward pool holding reward tokens and the exchange rate
public struct RewardPool<phantom Loyalty, phantom Reward> has key, store {
    id: UID,
    /// Balance of reward tokens available for claiming
    balance: Balance<Reward>,
    /// Number of loyalty tokens required per reward token
    rate: u32,
}

/// Creates a new reward pool with an initial balance and rate
entry fun new_reward_pool<Loyalty, Reward>(coin: Coin<Reward>, rate: u32, ctx: &mut TxContext) {
    transfer::share_object(RewardPool<Loyalty, Reward> {
        id: object::new(ctx),
        balance: coin.into_balance(),
        rate: rate,
    });
}

/// Adds more rewards to the pool and emits an event
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

/// Claims rewards by spending loyalty tokens. Transfers reward tokens to the user
/// and emits a redeem event.
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
