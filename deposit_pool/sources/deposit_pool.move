/// The deposit pool module allows users to deposit base tokens and earn loyalty tokens as rewards.
/// Users can lock their tokens for different time periods with varying APY rates.
module deposit_pool::deposit_pool;

use std::u128::pow;
use sui::bag::{Self, Bag};
use sui::balance::{zero, Balance};
use sui::clock::Clock;
use sui::coin::{TreasuryCap, Coin};
use sui::dynamic_field as df;
use sui::event;
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
/// Error when admin mistakenly removed the default term;
const ERemovingDefaultTerm: u64 = 6;
/// Error when user choose a term with apy less than expectation;
const EApyMismatched: u64 = 7;
/// Error when user tries to extend term when the pool not support it;
const ENotSupportExtendTerm: u64 = 8;
/// Error when user tries to extend term with wrong parameters;
const EInvalidExtendTerm: u64 = 9;
/// A vesting plan is malformed or exceeds the supported receipt count.
const EInvalidVestingPlan: u64 = 10;
/// A fixed vesting pool cannot be changed through staking operations.
const ESealedVestingPool: u64 = 11;
/// Stop is only available on a vesting pool.
const ENotVestingPool: u64 = 12;
/// This vesting pool was not created with stop permission.
const EVestingStopNotAllowed: u64 = 13;
/// This vesting pool has already been stopped.
const EVestingAlreadyStopped: u64 = 14;
/// This receipt belongs to a stopped vesting pool.
const EVestingStopped: u64 = 15;

// ====================== Const =================
/// Current version of the contract
const VERSION: u64 = 2;
/// Milliseconds in one day (<2^27)
const MS_PER_DAY: u64 = 86400000;
const DAY_PER_YEAR: u128 = 365;

/// Option key for early withdrawal support (bool), requrired.
const KEY_SUPPORT_EARLY_WITHDRAWAL: u8 = 1;

/// Option key for withdrawal pending window (days: u32), optional.
const KEY_WITHDRAWAL_PENDING: u8 = 2;

/// Option key for enable upgrade the term for higher apy (bool), optional.
const KEY_SUPPORT_TERM_EXTENSION: u8 = 3;

/// Vesting marker and immutable stop permission/state stored in the options Bag.
const KEY_IS_VESTING: u8 = 4;
const KEY_VESTING_STOP_ALLOWED: u8 = 5;
const KEY_VESTING_STOPPED: u8 = 6;
// Schedule and accounting metadata lives in authenticated events and receipt fields.

/// Bound object creation and event payload size for a single vesting allocation.
const MAX_VESTING_RECEIPTS: u64 = 256;

public struct VestingCreatedEvent has copy, drop {
    pool_id: ID,
    admin_cap_id: ID,
    creator: address,
    recipient: address,
    created_at_ms: u64,
    schedule_start_ms: u64,
    stop_allowed: bool,
    receipt_ids: vector<ID>,
    amounts: u64,
    maturities_ms: vector<u64>,
    cliff_amount: u64,
    vest_amount: u64,
}

public struct VestingStoppedEvent has copy, drop {
    pool_id: ID,
    admin_cap_id: ID,
    stopped_by: address,
    stopped_at_ms: u64,
    refunded_amount: u64,
}

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
    // immutable unit of return rate, apy:= rate/(10**decimal)
    rate_decimal: u8,
    /// Mapping of lock periods to APY rates
    return_rates: Table<u32, u16>,
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
    issue_at_ms: u64,
    /// Timestamp when lock period ends
    mature_at_ms: u64,
    /// a shifted apy, need to be divided by 10**`pool.rate_decimal`
    apy: u16,
}

/// Initializes a new deposit pool with base APY and configuration
entry fun new<Base, Loyalty>(
    treasury_cap: TreasuryCap<Loyalty>,
    base_apy: u16,
    rate_decimal: Option<u8>,
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
        rate_decimal: rate_decimal.destroy_or!(2),
        return_rates: table::new(ctx),
        version: VERSION,
        options: bag::new(ctx),
    };

    pool.options.add(KEY_SUPPORT_EARLY_WITHDRAWAL, early_withdrawal);

    if (withdrawal_pending > 0) {
        pool.options.add(KEY_WITHDRAWAL_PENDING, withdrawal_pending as u64 *MS_PER_DAY);
    };

    pool.return_rates.add(0, base_apy);
    transfer::share_object(pool);

    transfer::transfer(admin, ctx.sender());
}

/// Creates and fully funds a fixed, zero-APY vesting allocation.
/// A positive `cliff_amount` creates a receipt at `schedule_start_ms`; each
/// later maturity releases `vest_amount` and must be later than the start.
public fun new_vesting<Base, Loyalty>(
    treasury_cap: TreasuryCap<Loyalty>,
    funding: Coin<Base>,
    recipient: address,
    schedule_start_ms: u64,
    cliff_amount: u64,
    vest_amount: u64,
    maturities_ms: vector<u64>,
    stop_allowed: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let vesting_terms = vector::length(&maturities_ms);
    let has_cliff = cliff_amount > 0;
    let max_later_receipts = if (has_cliff) {
        MAX_VESTING_RECEIPTS - 1
    } else {
        MAX_VESTING_RECEIPTS
    };
    assert!(vesting_terms <= max_later_receipts, EInvalidVestingPlan);
    if (vesting_terms > 0) {
        assert!(vest_amount > 0, EInvalidVestingPlan);
    } else {
        assert!(vest_amount == 0, EInvalidVestingPlan);
    };

    let total_amount = cliff_amount + (vesting_terms * vest_amount);
    assert!(
        total_amount > 0 && total_amount == funding.value(),
        EInvalidVestingPlan,
    );

    let now_ms = clock.timestamp_ms();
    assert!(schedule_start_ms >= now_ms, EInvalidVestingPlan);

    let admin = AdminCap {
        id: object::new(ctx),
    };
    let mut options = bag::new(ctx);
    options.add(KEY_SUPPORT_EARLY_WITHDRAWAL, false);
    options.add(KEY_IS_VESTING, true);
    options.add(KEY_VESTING_STOP_ALLOWED, stop_allowed);
    options.add(KEY_VESTING_STOPPED, false);

    let mut return_rates = table::new(ctx);
    return_rates.add(0, 0);
    let mut pool = DepositPool<Base, Loyalty> {
        id: object::new(ctx),
        balance: funding.into_balance(),
        treasury_cap: treasury_cap,
        admin_cap_id: object::id(&admin),
        rate_decimal: 2,
        return_rates: return_rates,
        version: VERSION,
        options: options,
    };

    let pool_id = object::id(&pool);
    let admin_cap_id = object::id(&admin);
    let mut receipt_ids: vector<ID> = vector[];

    // Validate the full plan and total before creating/transferring any objects.

    if (has_cliff) {
        let receipt = Receipt {
            id: object::new(ctx),
            pool_id: pool_id,
            amount: cliff_amount,
            issue_at_ms: now_ms,
            mature_at_ms: schedule_start_ms,
            apy: 0,
        };
        receipt_ids.push_back(object::id(&receipt));
        transfer::transfer(receipt, recipient);
    };

    let mut previous_maturity_ms = schedule_start_ms;
    maturities_ms.do_ref!(|time| {
        assert!(*time > previous_maturity_ms, EInvalidVestingPlan);

        let receipt = Receipt {
            id: object::new(ctx),
            pool_id: pool_id,
            amount: vest_amount,
            issue_at_ms: now_ms,
            mature_at_ms: *time,
            apy: 0,
        };
        receipt_ids.push_back(object::id(&receipt));
        transfer::transfer(receipt, recipient);
        previous_maturity_ms = *time;
    });

    event::emit(VestingCreatedEvent {
        pool_id: pool_id,
        admin_cap_id: admin_cap_id,
        creator: ctx.sender(),
        recipient: recipient,
        created_at_ms: now_ms,
        schedule_start_ms: schedule_start_ms,
        stop_allowed: stop_allowed,
        receipt_ids: receipt_ids,
        amounts: total_amount,
        maturities_ms: maturities_ms,
        cliff_amount,
        vest_amount,
    });

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
    expected_apy: Option<u16>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(pool.version == VERSION, EWrongVersion);
    assert!(!pool.options.contains(KEY_IS_VESTING), ESealedVestingPool);

    let (lock_term, apy) = if (pool.return_rates.contains(term)) {
        (term as u64, pool.return_rates[term])
    } else {
        (0, pool.return_rates[0])
    };

    // if expected_apy has some value, ensure fetched apy is higer.
    assert!(expected_apy.destroy_or!(0)<=apy, EApyMismatched);

    transfer::transfer(
        Receipt {
            id: object::new(ctx),
            pool_id: object::id(pool),
            amount: coin.value(),
            issue_at_ms: clock.timestamp_ms(),
            mature_at_ms: clock.timestamp_ms()+(lock_term as u64)*MS_PER_DAY, // secure within u64
            apy: apy,
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
    if (pool.options.contains(KEY_VESTING_STOPPED)) {
        assert!(!pool.options[KEY_VESTING_STOPPED], EVestingStopped);
    };

    // Check eligible for execute withdrawal. Option always exists as this immutable option
    // was added during pool creation
    if (!pool.options[KEY_SUPPORT_EARLY_WITHDRAWAL]) {
        assert!(clock.timestamp_ms() >= receipt.mature_at_ms, ENotSupportEarlyWithdrawal);
    };

    // Check if withdrawl requirement pending window.
    if (pool.options.contains(KEY_WITHDRAWAL_PENDING)) {
        // if pending exists
        if (df::exists_(&pool.id, id(&receipt))) {
            // ensure pending is passed.
            assert!(*df::borrow(&pool.id, id(&receipt))<=clock.timestamp_ms(), EPendingWithdrawal);
        } else {
            // add pending and finish the call.
            df::add(
                &mut pool.id,
                id(&receipt),
                clock.timestamp_ms() + pool.options[KEY_WITHDRAWAL_PENDING],
            );
            transfer::transfer(receipt, ctx.sender());
            return
        }
    };

    // consume receipt
    let Receipt { id, .., amount, issue_at_ms, mature_at_ms, apy } = receipt;
    if (!pool.options.contains(KEY_IS_VESTING)) {
        let token_amount = pool.calculate_token_amount(
            clock,
            id.to_inner(),
            amount,
            mature_at_ms,
            issue_at_ms,
            apy,
        );
        if (token_amount>0) {
            let token = token::mint<Loyalty>(
                &mut pool.treasury_cap,
                token_amount,
                ctx,
            );
            let req = token::transfer(token, ctx.sender(), ctx);

            token::confirm_with_treasury_cap(&mut pool.treasury_cap, req, ctx);
        };
    };

    id.delete();

    // return base
    transfer::public_transfer(pool.balance.split(amount).into_coin(ctx), ctx.sender());
}

/// Stops an opted-in vesting pool and returns its complete remaining balance to
/// the address that supplied the matching AdminCap.
public fun stop_vesting<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    admin: &AdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(pool.admin_cap_id == object::id(admin), ENotAdmin);
    assert!(pool.version == VERSION, EWrongVersion);
    assert!(pool.options.contains(KEY_IS_VESTING), ENotVestingPool);
    assert!(pool.options[KEY_VESTING_STOP_ALLOWED], EVestingStopNotAllowed);
    assert!(!pool.options[KEY_VESTING_STOPPED], EVestingAlreadyStopped);

    let stopped_at_ms = clock.timestamp_ms();
    let refunded_amount = pool.balance.value();
    *bag::borrow_mut<u8, bool>(&mut pool.options, KEY_VESTING_STOPPED) = true;

    if (refunded_amount > 0) {
        transfer::public_transfer(
            pool.balance.split(refunded_amount).into_coin(ctx),
            ctx.sender(),
        );
    };

    event::emit(VestingStoppedEvent {
        pool_id: object::id(pool),
        admin_cap_id: object::id(admin),
        stopped_by: ctx.sender(),
        stopped_at_ms: stopped_at_ms,
        refunded_amount: refunded_amount,
    });
}

#[test_only]
public fun vesting_options_length_for_testing<Base, Loyalty>(
    pool: &DepositPool<Base, Loyalty>,
): u64 {
    bag::length(&pool.options)
}

#[test_only]
public fun vesting_created_event_matches_for_testing(
    created_event: VestingCreatedEvent,
    expected_total: u64,
    expected_maturities_ms: vector<u64>,
    expected_cliff_amount: u64,
    expected_vest_amount: u64,
): bool {
    if (
        created_event.amounts != expected_total
            || created_event.cliff_amount != expected_cliff_amount
            || created_event.vest_amount != expected_vest_amount
            || vector::length(&created_event.maturities_ms)
                != vector::length(&expected_maturities_ms)
    ) {
        return false
    };

    let mut maturity_index = 0;
    while (maturity_index < vector::length(&expected_maturities_ms)) {
        if (
            *vector::borrow(&created_event.maturities_ms, maturity_index)
                != *vector::borrow(&expected_maturities_ms, maturity_index)
        ) {
            return false
        };
        maturity_index = maturity_index + 1;
    };

    true
}

/// Upgrade the term of premature deposit receipt if support
public fun upgrade_term<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    receipt: &mut Receipt,
    target_term: u32,
    target_apy: Option<u16>,
    clock: &Clock,
) {
    assert!(pool.version == VERSION, EWrongVersion);
    assert!(receipt.pool_id == object::id(pool), EWrongPool);
    assert!(!pool.options.contains(KEY_IS_VESTING), ESealedVestingPool);

    // if option does not exists, directly abort
    assert!(pool.options.contains(KEY_SUPPORT_TERM_EXTENSION), ENotSupportExtendTerm);

    // mature receipt cannot extend, thus if the receipt within withdrwal pending will
    // not get additional benefits. An early withdrawal pending will not get any token
    // so we can safely ignore the withdrawal pending situation.
    assert!(receipt.mature_at_ms > clock.timestamp_ms(), EInvalidExtendTerm);

    // new apy must exists
    let new_apy = pool.return_rates[target_term];

    // To prevent misoperation, if user did not specify the apy, then new apy should be no less than the old one
    // However, user may explicilty choose a lower apy.
    assert!(new_apy>=target_apy.destroy_or!(receipt.apy), EApyMismatched);

    let new_mature_at_ms = receipt.issue_at_ms + (target_term as u64)*MS_PER_DAY;

    // mature term should be increase only.
    assert!(new_mature_at_ms>receipt.mature_at_ms, EInvalidExtendTerm);

    receipt.mature_at_ms = new_mature_at_ms;
    receipt.apy = new_apy;
}

/// Updates or adds a new lock term period with corresponding APY
public fun upsert_lock_term<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    admin: &mut AdminCap,
    days: u32,
    apy: u16,
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
    // if there is no withdrawal record, just abort.
    df::remove<_, u64>(&mut pool.id, id(receipt));
}

public fun delete_lock_term<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    admin: &mut AdminCap,
    days: u32,
) {
    assert!(pool.admin_cap_id == object::id(admin), ENotAdmin);
    assert!(pool.version == VERSION, EWrongVersion);
    assert!(days!=0, ERemovingDefaultTerm);
    // lock_term in ms
    pool.return_rates.remove(days);
}

public fun enable_extending_terms<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    admin: &mut AdminCap,
) {
    assert!(pool.admin_cap_id == object::id(admin), ENotAdmin);
    assert!(pool.version == VERSION, EWrongVersion);

    pool.options.add(KEY_SUPPORT_TERM_EXTENSION, true);
}

public fun disable_extending_terms<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    admin: &mut AdminCap,
) {
    assert!(pool.admin_cap_id == object::id(admin), ENotAdmin);
    assert!(pool.version == VERSION, EWrongVersion);

    // abort if not exists, then no meaning to disable it.
    pool.options.remove<u8, bool>(KEY_SUPPORT_TERM_EXTENSION);
}

/// Adds a new reward pool policy for loyalty tokens
#[allow(lint(self_transfer))]
public fun add_reward_program<Policy: drop, Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    admin: &mut AdminCap,
    ctx: &mut TxContext,
) {
    assert!(pool.admin_cap_id == object::id(admin), ENotAdmin);
    assert!(pool.version == VERSION, EWrongVersion);
    assert!(!pool.options.contains(KEY_IS_VESTING), ESealedVestingPool);

    let (mut policy, policy_cap) = token::new_policy(&pool.treasury_cap, ctx);

    // but we constrain spend by this shop:
    policy.add_rule_for_action<Loyalty, Policy>(
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
    mature_at_ms: u64,
    issue_at_ms: u64,
    apy: u16,
): u64 {
    if (pool.options.contains(KEY_IS_VESTING)) { return 0 };
    let withdraw_at_ms = if (pool.options.contains(KEY_WITHDRAWAL_PENDING)) {
        df::remove(&mut pool.id, receipt_id) - pool.options[KEY_WITHDRAWAL_PENDING]
    } else {
        clock.timestamp_ms()
    };
    // no additional token anyway
    if (withdraw_at_ms < mature_at_ms) {
        return 0
    };

    let eligible_term: u64 = (withdraw_at_ms - issue_at_ms)/MS_PER_DAY; // <u32

    let yearly_return = (amount as u128 * (apy as u128))/(10_u128.pow(pool.rate_decimal)); // <u80
    ((eligible_term as u128 * yearly_return)/DAY_PER_YEAR).try_as_u64().destroy_or!(0)
    // in a corner case, eligible term * yearly return is larger than u64, so we stop issue tokens to not block the execution. It is a liveness consideration, so the project side should compensate the case manually.
}
