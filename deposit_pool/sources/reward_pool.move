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
/// Error when exchange rate is not valid
const EInvalidExchangeRate: u64 = 2;
/// Error when return is not reach expectation
const ERewardNotAsExpected: u64 = 2;

public struct AdminCap has key, store {
    id: UID,
}

/// `loyalty_amount` loyalty token is equivilant to `reward_amount` reward coins
public struct ExchangeRate has drop, store {
    loyalty_amount: u64,
    reward_amount: u64,
}

/// Event emitted when the reward pool is refreshed with new rewards
public struct PoolRefreshedEvent has copy, drop {
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
    /// Exchange rate between loyalty token and reward coin
    exchange_rate: ExchangeRate,
    /// ID of the admin capability
    admin_cap_id: ID,
}

/// Creates a new reward pool with an initial balance and rate
entry fun new<Loyalty, Reward>(
    coin: Coin<Reward>,
    loyalty_amount: u64,
    reward_amount: u64,
    ctx: &mut TxContext,
) {
    let admin = AdminCap {
        id: object::new(ctx),
    };

    transfer::share_object(RewardPool<Loyalty, Reward> {
        id: object::new(ctx),
        balance: coin.into_balance(),
        exchange_rate: new_safe_exchange_rate(loyalty_amount, reward_amount),
        admin_cap_id: id(&admin),
    });

    transfer::transfer(admin, ctx.sender());
}

/// Adds an additional coin to the pool reward balance and emits an event
entry fun refresh<Loyalty, Reward>(pool: &mut RewardPool<Loyalty, Reward>, coin: Coin<Reward>) {
    pool.balance.join(coin.into_balance());

    // emit event for latest pool balance
    event::emit(PoolRefreshedEvent {
        pool_id: id(pool),
        amount: pool.balance.value(),
    });
}

/// Claims rewards by spending loyalty tokens. Transfers reward tokens to the user
/// and emits a redeem event.
#[allow(lint(self_transfer))]
public fun claim<Loyalty, Reward>(
    pool: &mut RewardPool<Loyalty, Reward>,
    token: Token<Loyalty>,
    policy: &mut TokenPolicy<Loyalty>,
    expected_return: Option<u64>,
    ctx: &mut TxContext,
) {
    let claim_amount = pool.exchange_rate.exchange_amount(token.value());

    // add expect return constraint
    // default claim amount is non-zero unless the user explicitly claim he expect a return value of zero.
    assert!(expected_return.destroy_or!(1)<= claim_amount, ERewardNotAsExpected);
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
public fun revoke<Loyalty, Reward>(
    pool: RewardPool<Loyalty, Reward>,
    admin_cap: &mut AdminCap,
    ctx: &mut TxContext,
) {
    assert!(pool.admin_cap_id == id(admin_cap), ENotAdmin);

    let RewardPool { id, balance, .. } = pool;
    id.delete();
    transfer::public_transfer(balance.into_coin(ctx), ctx.sender());
}

public fun update_exchange_rate<Loyalty, Reward>(
    pool: &mut RewardPool<Loyalty, Reward>,
    admin_cap: &mut AdminCap,
    new_loyalty_amount: u64,
    new_reward_amount: u64,
) {
    assert!(pool.admin_cap_id == id(admin_cap), ENotAdmin);

    pool.exchange_rate = new_safe_exchange_rate(new_loyalty_amount, new_reward_amount)
}

public fun new_safe_exchange_rate(loyalty_amount: u64, reward_amount: u64): ExchangeRate {
    assert!(loyalty_amount!=0, EInvalidExchangeRate);
    assert!(reward_amount!=0, EInvalidExchangeRate);

    ExchangeRate { loyalty_amount: loyalty_amount, reward_amount: reward_amount }
}

public fun exchange_amount(self: &ExchangeRate, spent_loyalty: u64): u64 {
    // the amount must be u64.
    // if abort, contact the pool admin to update the rate or reduce the token amount.
    ((self.reward_amount as u128)*(spent_loyalty as u128)/(self.loyalty_amount as u128))
        .try_as_u64()
        .extract()
}
