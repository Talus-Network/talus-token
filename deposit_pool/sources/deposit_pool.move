/// The deposit pool module allows users to deposit base tokens and earn loyalty tokens as rewards.
/// Users can lock their tokens for different time periods with varying APY rates.
module deposit_pool::deposit_pool;

use sui::bag::{Self, Bag};
use sui::balance::{zero, Balance};
use sui::clock::Clock;
use sui::coin::{TreasuryCap, Coin};
use sui::dynamic_field as df;
use sui::object::id;
use sui::table::{Self, Table};
use sui::token;

// ===================== Error Codes================
/// Error when caller is not the admin
const E_NOT_ADMIN: u64 = 0;
/// Error when trying to upgrade from current version
const E_NOT_UPGRADE: u64 = 1;
/// Error when version mismatch is detected
const E_WRONG_VERSION: u64 = 2;
/// Error when receipt is from different pool
const E_WRONG_POOL: u64 = 3;
/// Error when early withdrawal is not supported
const E_NOT_SUPPORT_EARLY_WITHDRAWAL: u64 = 4;
/// Error when withdrawal is still in pending state
const E_PENDING_WITHDRAWAL: u64 = 5;

// ====================== Const =================
/// Current version of the contract
const VERSION: u64 = 1;
/// Milliseconds in one day
const MS_PER_DAY: u64 = 86400000;
/// Option key for early withdrawal support
const KEY_SUPPORT_EARLY_WITHDRAWAL: u8 = 1;
const KEY_WITHDRAWAL_PENDING: u8 = 2; // Fixed typo in WITNDRWAL

public struct AdminCap has key, store {
    id: UID,
}

/// Main pool object that holds deposits and manages loyalty token distribution
public struct DepositPool<phantom Base, phantom Loyalty> has key {
    id: UID,
    /// Balance of base tokens in the pool
    balance: Balance<Base>,
    /// Treasury capability for minting loyalty tokens
    treasury_cap: TreasuryCap<Loyalty>,
    /// Mapping of lock periods to APY rates
    return_rates: Table<u64, u8>,
    /// ID of the admin capability
    admin_cap_id: ID,
    /// Contract version
    version: u64,
    /// Additional pool options
    options: Bag,
}

/// Receipt given to users when they deposit tokens
public struct Receipt has key {
    id: UID,
    /// ID of the pool where deposit was made
    pool_id: ID,
    /// Amount of base tokens deposited
    amount: u64,
    /// Timestamp when deposit was made
    issue: u64,
    /// Timestamp when lock period ends
    term: u64,
    /// APY rate for this deposit
    apy: u8,
}

/// Initializes a new deposit pool with base APY and configuration
entry fun initiate<Base, Loyalty>(
    treasury_cap: TreasuryCap<Loyalty>,
    base_apy: u8,
    early_withdrawal: bool, // Fixed typo in ealry_withdrawal
    withdrawal_pending: u64, // Fixed typo in witndrawal_pending
    ctx: &mut TxContext,
) {
    let admin = AdminCap {
        id: object::new(ctx),
    };
    let mut pool = DepositPool<Base, Loyalty> {
        id: object::new(ctx),
        balance: zero<Base>(),
        treasury_cap: treasury_cap,
        admin_cap_id: object::id(&admin),
        return_rates: table::new(ctx),
        version: VERSION,
        options: bag::new(ctx),
    };

    pool.options.add(KEY_SUPPORT_EARLY_WITHDRAWAL, early_withdrawal);

    if (withdrawal_pending > 0) {
        pool.options.add(KEY_WITHDRAWAL_PENDING, withdrawal_pending);
    };

    pool.return_rates.add(0, base_apy);
    transfer::share_object(pool);

    transfer::transfer(admin, ctx.sender());
}

/// Deposits base tokens into the pool and receives a receipt
public fun deposit<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    coin: Coin<Base>,
    term: u64,
    clock: &Clock,
    recipient: address,
    ctx: &mut TxContext,
) {
    assert!(pool.version == VERSION, E_WRONG_VERSION);

    let (lock_term, apy) = if (pool.return_rates.contains(term)) {
        (term, pool.return_rates.borrow(term))
    } else {
        (0, pool.return_rates.borrow(0))
    };

    transfer::transfer(
        Receipt {
            id: object::new(ctx),
            pool_id: object::id(pool),
            amount: coin.value(),
            issue: clock.timestamp_ms(),
            term: clock.timestamp_ms()+lock_term*MS_PER_DAY,
            apy: *apy,
        },
        recipient,
    );

    pool.balance.join(coin.into_balance());
}

/// Withdraws base tokens and claims loyalty tokens if eligible
entry fun withdrawal<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    receipt: Receipt,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(pool.version == VERSION, E_WRONG_VERSION);
    assert!(receipt.pool_id == object::id(pool), E_WRONG_POOL);

    // Check eligible for execute withdrawal
    if (pool.options.borrow(KEY_SUPPORT_EARLY_WITHDRAWAL)!= true) {
        assert!(clock.timestamp_ms() > receipt.term, E_NOT_SUPPORT_EARLY_WITHDRAWAL);
    };

    if (pool.options.contains(KEY_WITHDRAWAL_PENDING)) {
        if (df::exists_(&pool.id, id(&receipt))) {
            // ensure pending is passed.
            assert!(
                *df::borrow(&pool.id, id(&receipt))<=clock.timestamp_ms(),
                E_PENDING_WITHDRAWAL,
            );
        } else {
            // add pending and finish the call.
            df::add(
                &mut pool.id,
                id(&receipt),
                clock.timestamp_ms() +*pool.options.borrow(KEY_WITHDRAWAL_PENDING)*MS_PER_DAY,
            );
            transfer::transfer(receipt, ctx.sender());
            return
        }
    };

    // consume receipt
    let Receipt { id, .., amount, issue, term, apy } = receipt;
    let token_amount = calculate_token_amount(pool, clock, id.to_inner(), amount, term, issue, apy);
    if (token_amount>0) {
        let token = token::mint<Loyalty>(
            &mut pool.treasury_cap,
            token_amount,
            ctx,
        );
        let req = token::transfer(token, ctx.sender(), ctx);

        token::confirm_with_treasury_cap(&mut pool.treasury_cap, req, ctx);
    };

    id.delete();

    // return base
    transfer::public_transfer(pool.balance.split(amount).into_coin(ctx), ctx.sender());
}

/// Updates or adds a new lock term period with corresponding APY
#[allow(unused_mut_parameter)]
public fun upsert_lock_term<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    admin: &mut AdminCap,
    days: u64,
    apy: u8,
) {
    assert!(pool.admin_cap_id == object::id(admin), E_NOT_ADMIN);
    assert!(pool.version == VERSION, E_WRONG_VERSION);
    // lock_term in ms
    if (pool.return_rates.contains(days)) {
        pool.return_rates.remove(days);
    };

    pool.return_rates.add(days, apy)
}

/// Cancels a pending withdrawal request
public fun cancel_pending_withdrawal<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    receipt: &mut Receipt,
) {
    assert!(pool.version == VERSION, E_WRONG_VERSION);
    assert!(receipt.pool_id == object::id(pool), E_WRONG_POOL);
    // lock_term in ms
    df::remove<_, u64>(&mut pool.id, id(receipt));
}

#[allow(unused_mut_parameter)]
public fun delete_lock_term<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    admin: &mut AdminCap,
    days: u64,
) {
    assert!(pool.admin_cap_id == object::id(admin), E_NOT_ADMIN);
    assert!(pool.version == VERSION, E_WRONG_VERSION);
    // lock_term in ms
    pool.return_rates.remove(days);
}

/// Adds a new reward pool policy for loyalty tokens
#[allow(unused_mut_parameter, lint(self_transfer))]
public fun add_reward_program<Policy: drop, Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    admin: &mut AdminCap,
    ctx: &mut TxContext,
) {
    assert!(pool.admin_cap_id == object::id(admin), E_NOT_ADMIN);
    assert!(pool.version == VERSION, E_WRONG_VERSION);

    let (mut policy, policy_cap) = token::new_policy(&pool.treasury_cap, ctx);

    // but we constrain spend by this shop:
    token::add_rule_for_action<Loyalty, Policy>(
        &mut policy,
        &policy_cap,
        token::spend_action(),
        ctx,
    );

    token::share_policy(policy);
    transfer::public_transfer(policy_cap, tx_context::sender(ctx));
}

/// Upgrades the pool to a new version
entry fun migrate<Base, Loyalty>(pool: &mut DepositPool<Base, Loyalty>, admin: &AdminCap) {
    assert!(pool.admin_cap_id == object::id(admin), E_NOT_ADMIN);
    assert!(pool.version < VERSION, E_NOT_UPGRADE);
    pool.version = VERSION;
}

/// Calculates the amount of loyalty tokens to be minted based on deposit terms
fun calculate_token_amount<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    clock: &Clock,
    receipt_id: ID,
    amount: u64,
    lock_term: u64,
    issue_time: u64, // Changed from issue to issue_time
    apy: u8,
): u64 {
    // no additional token anyway
    if (clock.timestamp_ms()< lock_term) {
        return 0
    };

    let eligible_term: u64 = if (pool.options.contains(KEY_WITHDRAWAL_PENDING)) {
        df::remove(&mut pool.id, receipt_id) - *pool.options.borrow(KEY_WITHDRAWAL_PENDING) * MS_PER_DAY - issue_time
    } else {
        clock.timestamp_ms() - issue_time
    }.divide_and_round_up(MS_PER_DAY);

    let yearly_return = (amount as u128 * (apy as u128)).divide_and_round_up(100);
    (eligible_term as u128 * yearly_return).divide_and_round_up(365).try_as_u64().extract()
}
