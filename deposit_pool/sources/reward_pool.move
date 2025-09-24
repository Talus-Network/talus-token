/// The reward pool module define basic reward pools and allows users to claim rewards
/// by spending loyalty tokens. Pools can be refreshed with more rewards, and events
/// are emitted for transparency.
module deposit_pool::reward_pool;

use std::string::String;
use sui::balance::Balance;
use sui::coin::Coin;
use sui::event;
use sui::object::id;
use sui::token::{Token, spend, add_approval, confirm_request_mut, TokenPolicy};

/// Error code for insufficient pool balance when claiming rewards
const EPoolInsufficient: u64 = 0;
/// Error when caller is not the admin
const ENotAdmin: u64 = 1;

public struct AdminCap has key, store {
    id: UID,
}

/// Event emitted when the reward pool is refreshed with new rewards
public struct PoolFreshedEvent has copy, drop {
    pool_id: ID,
    amount: u64,
}

/// Event emitted when a user redeems a reward
public struct RewardRedeemedEvent has copy, drop {
    token_name: String,
    amount: u64,
    user_address: address,
}

/// Marker struct for reward pool approval
public struct RewardProgram has drop {}

/// Reward pool holding reward tokens and the exchange rate
public struct RewardPool<phantom Loyalty, phantom Reward> has key, store {
    id: UID,
    /// Balance of reward tokens available for claiming
    balance: Balance<Reward>,
    /// Number of loyalty tokens required per reward token
    exchange_rate: u32,
    /// ID of the admin capability
    admin_cap_id: ID,
}

/// Creates a new reward pool with an initial balance and rate
entry fun new<Loyalty, Reward>(coin: Coin<Reward>, rate: u32, ctx: &mut TxContext) {
    let admin = AdminCap {
        id: object::new(ctx),
    };

    transfer::share_object(RewardPool<Loyalty, Reward> {
        id: object::new(ctx),
        balance: coin.into_balance(),
        exchange_rate: rate,
        admin_cap_id: id(&admin),
    });

    transfer::transfer(admin, ctx.sender());
}

/// Adds more rewards to the pool and emits an event
entry fun reward_fresh<Loyalty, Reward>(
    pool: &mut RewardPool<Loyalty, Reward>,
    coin: Coin<Reward>,
) {
    event::emit(PoolFreshedEvent {
        pool_id: id(pool),
        amount: coin.value(),
    });

    pool.balance.join(coin.into_balance());
}

/// Claims rewards by spending loyalty tokens. Transfers reward tokens to the user
/// and emits a redeem event.
#[allow(lint(self_transfer))]
public fun claim<Loyalty, Reward>(
    pool: &mut RewardPool<Loyalty, Reward>,
    token: Token<Loyalty>,
    policy: &mut TokenPolicy<Loyalty>,
    ctx: &mut TxContext,
) {
    let claim_amount = token.value()/(pool.exchange_rate as u64);

    assert!(claim_amount <= pool.balance.value(), EPoolInsufficient);

    let mut req = spend(token, ctx);
    add_approval(RewardProgram {}, &mut req, ctx);

    let (token_name, amount, user_address, _) = confirm_request_mut(policy, req, ctx);

    transfer::public_transfer(pool.balance.split(claim_amount).into_coin(ctx), ctx.sender());
    event::emit(RewardRedeemedEvent {
        token_name,
        amount,
        user_address,
    });
}

#[allow(lint(self_transfer))]
public fun revoke_pool<Loyalty, Reward>(
    pool: RewardPool<Loyalty, Reward>,
    admin_cap: &mut AdminCap,
    ctx: &mut TxContext,
) {
    assert!(pool.admin_cap_id == id(admin_cap), ENotAdmin);

    let RewardPool { id, balance, .. } = pool;
    id.delete();
    transfer::public_transfer(balance.into_coin(ctx), ctx.sender());
}

public fun update_rate<Loyalty, Reward>(
    pool: &mut RewardPool<Loyalty, Reward>,
    admin_cap: &mut AdminCap,
    new_rate: u32,
) {
    assert!(pool.admin_cap_id == id(admin_cap), ENotAdmin);

    pool.exchange_rate = new_rate
}
