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
const ENotAdmin: u64 = 0;
/// Error when trying to upgrade from current version
const ENotUpgrade: u64 = 1;
/// Error when version mismatch is detected
const EWrongVersion: u64 = 2;
/// Error when receipt is from different pool
const EWrongPool: u64 = 3;
/// Error when early withdrawal is not supported
const ENotSupportEarlyWithdrawal: u64 = 4;
/// Error when withdrawal is still in pending state
const EPendingWithdrawal: u64 = 5;

// ====================== Const =================
/// Current version of the contract
const VERSION: u64 = 1;
/// Milliseconds in one day (<2^27)
const MS_PER_DAY: u64 = 86400000;
const MAX_PCT: u128 = 100;
const DAY_PER_YEAR: u128 = 365;

/// Option key for early withdrawal support
const KEY_SUPPORT_EARLY_WITHDRAWAL: u8 = 1;
/// Option key for withdrawal pending window
const KEY_WITHDRAWAL_PENDING: u8 = 2;

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
    return_rates: Table<u32, u8>,
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
entry fun new<Base, Loyalty>(
    treasury_cap: TreasuryCap<Loyalty>,
    base_apy: u8,
    early_withdrawal: bool,
    withdrawal_pending: u32,
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
/// term refers to the number of days needed to pass for valid return value
public fun deposit<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    coin: Coin<Base>,
    term: u32,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(pool.version == VERSION, EWrongVersion);

    let (lock_term, apy) = if (pool.return_rates.contains(term)) {
        (term as u64, pool.return_rates.borrow(term))
    } else {
        (0, pool.return_rates.borrow(0))
    };

    transfer::transfer(
        Receipt {
            id: object::new(ctx),
            pool_id: object::id(pool),
            amount: coin.value(),
            issue: clock.timestamp_ms(),
            term: clock.timestamp_ms()+(lock_term as u64)*MS_PER_DAY, // secure within u64
            apy: *apy,
        },
        recipient,
    );

    pool.balance.join(coin.into_balance());
}

/// Withdraws base tokens and claims loyalty tokens if eligible
entry fun withdraw<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    receipt: Receipt,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(pool.version == VERSION, EWrongVersion);
    assert!(receipt.pool_id == object::id(pool), EWrongPool);

    // Check eligible for execute withdrawal
    if (pool.options.borrow(KEY_SUPPORT_EARLY_WITHDRAWAL)!= true) {
        assert!(clock.timestamp_ms() > receipt.term, ENotSupportEarlyWithdrawal);
    };

    if (pool.options.contains(KEY_WITHDRAWAL_PENDING)) {
        if (df::exists_(&pool.id, id(&receipt))) {
            // ensure pending is passed.
            assert!(*df::borrow(&pool.id, id(&receipt))<=clock.timestamp_ms(), EPendingWithdrawal);
        } else {
            // add pending and finish the call.
            df::add(
                &mut pool.id,
                id(&receipt),
                clock.timestamp_ms() +((*pool.options.borrow<u8,u32>(KEY_WITHDRAWAL_PENDING) )as u64)*MS_PER_DAY,
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
    days: u32,
    apy: u8,
) {
    assert!(pool.admin_cap_id == object::id(admin), ENotAdmin);
    assert!(pool.version == VERSION, EWrongVersion);
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
    assert!(pool.version == VERSION, EWrongVersion);
    assert!(receipt.pool_id == object::id(pool), EWrongPool);
    // lock_term in ms
    df::remove<_, u64>(&mut pool.id, id(receipt));
}

#[allow(unused_mut_parameter)]
public fun delete_lock_term<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    admin: &mut AdminCap,
    days: u32,
) {
    assert!(pool.admin_cap_id == object::id(admin), ENotAdmin);
    assert!(pool.version == VERSION, EWrongVersion);
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
    assert!(pool.admin_cap_id == object::id(admin), ENotAdmin);
    assert!(pool.version == VERSION, EWrongVersion);

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
    assert!(pool.admin_cap_id == object::id(admin), ENotAdmin);
    assert!(pool.version < VERSION, ENotUpgrade);
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
        df::remove(&mut pool.id, receipt_id) - ((*pool.options.borrow<u8,u32>(KEY_WITHDRAWAL_PENDING) )as u64) * MS_PER_DAY - issue_time
    } else {
        clock.timestamp_ms() - issue_time
    }.divide_and_round_up(MS_PER_DAY); // <u32

    let yearly_return = (amount as u128 * (apy as u128)).divide_and_round_up(MAX_PCT); // <u65
    (eligible_term as u128 * yearly_return)
        .divide_and_round_up(DAY_PER_YEAR)
        .try_as_u64()
        .destroy_or!(0)
    // in a conrner case, eligible term * yearly return is larger than u64, so we stop issue token to not block the execution. It is a liveness consideration, so the project side should compensate the case manually.
}
