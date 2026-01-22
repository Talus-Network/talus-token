/// The deposit holder module allows users to delegate their wrapped receipts to an admin.
/// The admin can withdraw, claim rewards, and optionally redeposit on behalf of users.
/// Only the original depositor can receive the base tokens and rewards.
module deposit_agent::deposit_agent;

use DepositPool::deposit_pool::{
    DepositPool,
    ReceiptWrapper,
    wrapper_to_receipt,
    receipt_to_wrapper
};
use DepositPool::reward_pool::RewardPool;
use std::option::{some, none};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;
use sui::object::id;
use sui::table::{Self, Table};

// ===================== Error Codes ================
/// Error when caller is not the admin
const ENotAdmin: u64 = 0;
/// Error when receipt not found in delegator
const EReceiptNotFound: u64 = 1;
/// Error when caller is not the depositor
const ENotDepositor: u64 = 2;
/// Error when reward pool is not configured
const ERewardPoolNotConfigured: u64 = 3;
/// Error when deposit pool is not configured
const EDepositPoolNotConfigured: u64 = 4;
/// Error when deposit pool is not configured
const EHarvestWithNoReward: u64 = 5;

// ===================== Structs ================

/// Admin capability for the deposit holder
public struct AdminCap has key, store {
    id: UID,
}

/// Holds information about a stored receipt
public struct ReceiptRecord has drop, store {
    /// ID of the wrapped receipt
    receipt_id: ID,
    /// Address of the original depositor
    depositor: address,
    /// term
    term: u32,
    /// APY
    expected_apy: Option<u16>,
    /// return
    expected_return: Option<u64>,
    /// deposit_pool id
    deposit_pool_id: ID,
    // reward_pool id
    reward_pool_id: ID,
    /// Redeposit the reward
    redeposit: bool,
}

/// The main delegator object that stores wrapped receipts
public struct Delegator<phantom Base, phantom Loyalty, phantom Reward> has key {
    id: UID,
    /// ID of the admin capability
    admin_cap_id: sui::object::ID,
    /// Table mapping receipt IDs to their records
    receipt_records: Table<sui::object::ID, ReceiptRecord>,
    /// ID of the configured deposit pool
    deposit_pool_id: std::option::Option<sui::object::ID>,
    /// ID of the configured reward pool
    reward_pool_id: std::option::Option<sui::object::ID>,
}

/// Event emitted when a receipt is stored in the delegator
public struct ReceiptStoredEvent has copy, drop {
    delegator_id: sui::object::ID,
    receipt_id: sui::object::ID,
    depositor: address,
    amount: u64,
}

/// Event emitted when a receipt is withdrawn from the delegator
public struct ReceiptWithdrawnEvent has copy, drop {
    delegator_id: sui::object::ID,
    receipt_id: sui::object::ID,
    depositor: address,
}

/// Event emitted when admin performs withdraw, claim, and optional redeposit
public struct SuccessfulHarvesting has copy, drop {
    delegator_id: sui::object::ID,
    receipt_id: sui::object::ID,
    depositor: address,
    base_amount: u64,
    reward_amount: u64,
    redeposit: bool,
}

/// Event emitted when admin performs withdraw, claim, and optional redeposit
public struct HarvestPending has copy, drop {
    delegator_id: sui::object::ID,
    receipt_id: sui::object::ID,
}

// ===================== Functions ================

/// Creates a new delegator with the given admin capability
entry fun new<Base, Loyalty, Reward>(ctx: &mut TxContext) {
    let admin = AdminCap {
        id: object::new(ctx),
    };

    let delegator = Delegator<Base, Loyalty, Reward> {
        id: object::new(ctx),
        admin_cap_id: id(&admin),
        receipt_records: table::new(ctx),
        deposit_pool_id: none(),
        reward_pool_id: none(),
    };

    transfer::share_object(delegator);
    transfer::transfer(admin, ctx.sender());
}

/// Stores a wrapped receipt in the delegator
/// Anyone can call this to deposit their wrapped receipt
public entry fun delegate_deposit<Base, Loyalty, Reward>(
    delegator: &mut Delegator<Base, Loyalty, Reward>,
    deposit_pool: &mut DepositPool<Base, Loyalty>,
    reward_pool: &mut RewardPool<Loyalty, Base>,
    coin: Coin<Base>,
    term: u32,
    recipient: address,
    expected_apy: Option<u16>,
    expected_return: Option<u64>,
    clock: &Clock,
    redeposit: bool,
    ctx: &mut TxContext,
) {
    let depositor = recipient;
    let amount = coin.balance().value();
    let receipt = deposit_pool.do_deposit(coin, term, expected_apy, clock, ctx);
    let wrapped_receipt = deposit_pool.receipt_to_wrapper(receipt, ctx);
    let receipt_id = id(&wrapped_receipt);

    // Store the receipt record
    delegator
        .receipt_records
        .add(
            receipt_id,
            ReceiptRecord {
                receipt_id,
                depositor,
                term,
                expected_apy,
                expected_return,
                deposit_pool_id: id(deposit_pool),
                reward_pool_id: id(reward_pool),
                redeposit,
            },
        );

    // Store the actual wrapped receipt as a dynamic field
    sui::dynamic_field::add(&mut delegator.id, receipt_id, wrapped_receipt);

    event::emit(ReceiptStoredEvent {
        delegator_id: id(delegator),
        receipt_id,
        depositor,
        amount,
    });
}

/// Admin configures the deposit pool for this delegator
public entry fun configure_deposit_pool<Base, Loyalty, Reward>(
    delegator: &mut Delegator<Base, Loyalty, Reward>,
    admin: &AdminCap,
    pool: &DepositPool<Base, Loyalty>,
) {
    assert!(delegator.admin_cap_id == id(admin), ENotAdmin);
    delegator.deposit_pool_id = some(id(pool));
}

/// Admin configures the reward pool for this delegator
public entry fun configure_reward_pool<Base, Loyalty, Reward>(
    delegator: &mut Delegator<Base, Loyalty, Reward>,
    admin: &AdminCap,
    pool: &RewardPool<Loyalty, Reward>,
) {
    assert!(delegator.admin_cap_id == id(admin), ENotAdmin);
    delegator.reward_pool_id = some(id(pool));
}

public fun auto_renewal<Base, Loyalty>(
    delegator: &mut Delegator<Base, Loyalty, Base>,
    admin: &AdminCap,
    receipt_id: sui::object::ID,
    deposit_pool: &mut DepositPool<Base, Loyalty>,
    reward_pool: &mut RewardPool<Loyalty, Base>,
    policy: &mut sui::token::TokenPolicy<Loyalty>,
    expected_reward: Option<u64>,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    let (base, reward) = delegator.delegated_harvest(
        admin,
        receipt_id,
        deposit_pool,
        reward_pool,
        policy,
        expected_reward,
        clock,
        ctx,
    );

    if (base.is_none()) {
        // pending period, wait next triggering
        base.destroy_none();
        reward.destroy_none();
        event::emit(HarvestPending {
            delegator_id: id(delegator),
            receipt_id,
        })
    } else {
        let receipt = delegator
            .receipt_records
            .remove(
                receipt_id,
            );

        let mut total = base.destroy_some();
        let base_amount = total.balance().value();
        let mut reward_amount = 0;
        reward.destroy!(|r| { reward_amount = r.balance().value(); if (receipt.redeposit) {
                total.join(r)
            } else {
                transfer::public_transfer(r, receipt.depositor)
            } });

        delegate_deposit(
            delegator,
            deposit_pool,
            reward_pool,
            total,
            receipt.term,
            receipt.depositor,
            receipt.expected_apy,
            receipt.expected_return,
            clock,
            receipt.redeposit,
            ctx,
        );

        event::emit(SuccessfulHarvesting {
            delegator_id: id(delegator),
            receipt_id,
            depositor: receipt.depositor,
            base_amount,
            reward_amount,
            redeposit: receipt.redeposit,
        })
    }
}

/// an harvest including withdraws base/loyalty and always claims rewards
public fun delegated_harvest<Base, Loyalty, Reward>(
    delegator: &mut Delegator<Base, Loyalty, Reward>,
    admin: &AdminCap,
    receipt_id: sui::object::ID,
    deposit_pool: &mut DepositPool<Base, Loyalty>,
    reward_pool: &mut RewardPool<Loyalty, Reward>,
    policy: &mut sui::token::TokenPolicy<Loyalty>,
    expected_reward: Option<u64>,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
): (Option<Coin<Base>>, Option<Coin<Reward>>) {
    assert!(delegator.admin_cap_id == id(admin), ENotAdmin);
    assert!(delegator.receipt_records.contains(receipt_id), EReceiptNotFound);
    assert!(delegator.deposit_pool_id == some(id(deposit_pool)), EDepositPoolNotConfigured);
    assert!(delegator.reward_pool_id == some(id(reward_pool)), ERewardPoolNotConfigured);

    let wrapped_receipt: ReceiptWrapper = sui::dynamic_field::remove(
        &mut delegator.id,
        receipt_id,
    );

    // Convert wrapper back to receipt
    let receipt = deposit_pool.wrapper_to_receipt(wrapped_receipt, ctx);

    // Perform withdrawal to get base and loyalty tokens
    let (base_coin, loyalty_token, receipt) = deposit_pool.do_withdrawal(receipt, clock, ctx);

    let mut _base_amount: u64 = 0;
    let mut _reward_amount: u64 = 0;

    // if it is pending, then store the receipt again
    if (base_coin.is_none()) {
        // unsuccessful withdrawl due to pending
        base_coin.destroy_none();
        loyalty_token.destroy_none();
        let wrapped_receipt = deposit_pool.receipt_to_wrapper(receipt.destroy_some(), ctx);
        // Restore the actual wrapped receipt as a dynamic field
        sui::dynamic_field::add(&mut delegator.id, receipt_id, wrapped_receipt);
        return (none(), none())
    };

    // receipt should be none
    receipt.destroy_none();
    if (loyalty_token.is_none()) {
        loyalty_token.destroy_none();
        expected_reward.destroy!(|n| assert!(n==0, EHarvestWithNoReward));
        return (base_coin, none())
    } else {
        let loyalty = loyalty_token.destroy_some();
        let reward = reward_pool.do_claim(loyalty, policy, expected_reward, ctx);
        return (base_coin, some(reward))
    }
}

/// User withdraws their stored receipt
/// Only the original depositor can call this
public entry fun user_withdraw_receipt<Base, Loyalty, Reward>(
    delegator: &mut Delegator<Base, Loyalty, Reward>,
    receipt_id: sui::object::ID,
    ctx: &mut TxContext,
) {
    assert!(delegator.receipt_records.contains(receipt_id), EReceiptNotFound);

    let record = delegator.receipt_records.remove(receipt_id);
    assert!(record.depositor == ctx.sender(), ENotDepositor);

    let wrapped_receipt: ReceiptWrapper = sui::dynamic_field::remove(
        &mut delegator.id,
        receipt_id,
    );

    sui::transfer::public_transfer(wrapped_receipt, record.depositor);
}

/// Allows a user to check if their receipt is stored in the delegator
public fun has_receipt<Base, Loyalty, Reward>(
    delegator: &Delegator<Base, Loyalty, Reward>,
    receipt_id: sui::object::ID,
): bool {
    delegator.receipt_records.contains(receipt_id)
}

/// Gets the depositor address for a receipt
public fun get_depositor<Base, Loyalty, Reward>(
    delegator: &Delegator<Base, Loyalty, Reward>,
    receipt_id: sui::object::ID,
): std::option::Option<address> {
    if (delegator.receipt_records.contains(receipt_id)) {
        some(delegator.receipt_records[receipt_id].depositor)
    } else {
        none()
    }
}

/// Get the configured deposit pool ID
public fun get_deposit_pool_id<Base, Loyalty, Reward>(
    delegator: &Delegator<Base, Loyalty, Reward>,
): std::option::Option<sui::object::ID> {
    delegator.deposit_pool_id
}

/// Get the configured reward pool ID
public fun get_reward_pool_id<Base, Loyalty, Reward>(
    delegator: &Delegator<Base, Loyalty, Reward>,
): std::option::Option<sui::object::ID> {
    delegator.reward_pool_id
}
