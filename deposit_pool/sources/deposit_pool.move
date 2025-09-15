module deposit_pool::deposit_pool;

use sui::balance::{zero, Balance};
use sui::clock::Clock;
use sui::coin::{TreasuryCap, Coin};
use sui::table::{Self, Table};
use sui::bag::{Self,Bag};
use sui::token;

const ENotAdmin: u64 = 0;

const ENotUpgrade: u64 = 1;

const EWrongVersion: u64 = 2;

const EWrongPool: u64 = 3;

const ENotSupportEarlyWithdrawal:u64 = 4;

const VERSION: u64 = 1;

const MS_PER_DAY:u64 = 86400000;

const KEY_SUPPORT_EARLY_WITHDRAWAL:u8 = 1;

public struct AdminCap has key, store {
    id: UID,
}

public struct DepositPool<phantom Base, phantom Loyalty> has key {
    id: UID,
    balance: Balance<Base>,
    treasury_cap: TreasuryCap<Loyalty>,
    return_rates: Table<u64, u8>,
    admin: ID,
    version: u64,
    options: Bag,
}

public struct Receipt has key {
    id: UID,
    pool_id: ID,
    amount: u64,
    issue: u64,
    term: u64,
    apy: u8,
}

entry fun initiate<Base, Loyalty>(
    treasury_cap: TreasuryCap<Loyalty>,
    base_apy: u8,
    ealry_withdrawal:bool,
    ctx: &mut TxContext,
) {
    let admin = AdminCap {
        id: object::new(ctx),
    };
    let mut pool = DepositPool<Base, Loyalty> {
        id: object::new(ctx),
        balance: zero<Base>(),
        treasury_cap: treasury_cap,
        admin: object::id(&admin),
        return_rates: table::new(ctx),
        version: VERSION,
        options: bag::new(ctx)
    };

    pool.options.add(KEY_SUPPORT_EARLY_WITHDRAWAL,ealry_withdrawal);

    pool.return_rates.add(0, base_apy);
    transfer::share_object(pool);

    transfer::transfer(admin, ctx.sender());
}

entry fun deposit<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    coin: Coin<Base>,
    term: u64,
    clock: &Clock,
    recipient: address,
    ctx: &mut TxContext,
) {
    assert!(pool.version == VERSION, EWrongVersion);

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

entry fun withdrawal<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    receipt: Receipt,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(pool.version == VERSION, EWrongVersion);
    assert!(receipt.pool_id == object::id(pool), EWrongPool);

    // consume receipt
    let Receipt { id, .., amount, issue, term, apy } = receipt;
    if (clock.timestamp_ms()>= term) {
        let token = token::mint<Loyalty>(
            &mut pool.treasury_cap,
            calculate_return(amount, (clock.timestamp_ms()-issue).divide_and_round_up(MS_PER_DAY), apy),
            ctx,
        );
        let req = token::transfer(token, ctx.sender(), ctx);

        token::confirm_with_treasury_cap(&mut pool.treasury_cap, req, ctx);
    }
    else {
        assert!(pool.options.borrow(KEY_SUPPORT_EARLY_WITHDRAWAL)==true,ENotSupportEarlyWithdrawal)
    };
    
    id.delete();

    // return base
    transfer::public_transfer(pool.balance.split(amount).into_coin(ctx), ctx.sender());
}

#[allow(unused_mut_parameter)]
entry fun upsert_lock_term<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    admin: &mut AdminCap,
    days: u64,
    apy: u8,
) {
    assert!(pool.admin == object::id(admin), ENotAdmin);
    assert!(pool.version == VERSION, EWrongVersion);
    // lock_term in ms
    if (pool.return_rates.contains(days)) {
        pool.return_rates.remove(days);
    };

    pool.return_rates.add(days, apy)
}

#[allow(unused_mut_parameter)]
entry fun delete_lock_term<Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    admin: &mut AdminCap,
    days: u64,
) {
    assert!(pool.admin == object::id(admin), ENotAdmin);
    assert!(pool.version == VERSION, EWrongVersion);
    // lock_term in ms
    pool.return_rates.remove(days);
}

#[allow(unused_mut_parameter)]
entry fun add_reward_program<Policy: drop, Base, Loyalty>(
    pool: &mut DepositPool<Base, Loyalty>,
    admin: &mut AdminCap,
    ctx: &mut TxContext,
) {
    assert!(pool.admin == object::id(admin), ENotAdmin);
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

entry fun migrate<Base, Loyalty>(pool: &mut DepositPool<Base, Loyalty>, admin: &AdminCap) {
    assert!(pool.admin == object::id(admin), ENotAdmin);
    assert!(pool.version < VERSION, ENotUpgrade);
    pool.version = VERSION;
}

fun calculate_return(amount: u64, term: u64, apy: u8): u64 {
    let yearly_return = (amount as u128 * (apy as u128)).divide_and_round_up(100);
    (term as u128 * yearly_return).divide_and_round_up(365).try_as_u64().extract()
}
