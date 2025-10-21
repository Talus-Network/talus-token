#[test_only]
module deposit_pool::test_deposit_pool;

use deposit_pool::deposit_pool::{
    Self,
    AdminCap,
    DepositPool,
    Receipt,
    ENotSupportEarlyWithdrawal,
    EPendingWithdrawal,
    ERemovingDefaultTerm,
    EApyMismatched,
    ENotSupportExtendTerm,
    EInvalidExtendTerm
};
use std::option::{none, some};
use sui::clock;
use sui::coin::{Self, create_treasury_cap_for_testing, Coin};
use sui::test_scenario::{Self as ts, Scenario};
use sui::token::Token;

const ADMIN: address = @0xA11ce;
const USER: address = @0xB0B;
const Base_APY: u16 = 5;
const Deposit: u64 = 1000000000;
const Lock_DAY: u32 = 60;
const Pending_DAY: u32 = 7;
const MS_PER_DAY: u64 = 86400000;
const DEFAULT_DECIMAL: u8 = 2;

public struct Loyalty has drop {}
public struct Base has drop {}

#[test]
fun test_pool_initialization() {
    let mut scenario = init_deposit_pool(true, 0);

    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let pool = scenario.take_shared<DepositPool<Base, Loyalty>>();

        // ensure object created
        scenario.return_to_sender(admin_cap);
        ts::return_shared(pool);
    };

    scenario.end();
}

#[test]
fun test_deposit_and_withdraw_success() {
    let mut scenario = init_deposit_pool(true, 0);

    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);

    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_Base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_Base,
            Lock_DAY,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );

        ts::return_shared(pool);
    };

    // Advance clock past term
    clock.increment_for_testing(MS_PER_DAY * 31);

    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);

        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );

        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = ENotSupportEarlyWithdrawal)]
fun test_early_withdrawal_not_allowed() {
    let mut scenario = init_deposit_pool(false, 0);

    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    add_lock_term_for_testing(&mut scenario, &mut pool, Lock_DAY, Base_APY);
    scenario.next_tx(USER);
    {
        let coin_Base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_Base,
            Lock_DAY,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );
    };

    scenario.next_tx(USER);
    {
        let receipt = scenario.take_from_sender<Receipt>();

        // Should fail - trying to withdraw early
        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );
    };

    ts::return_shared(pool);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_admin_functions() {
    let mut scenario = init_deposit_pool(true, 0);

    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

        pool.upsert_lock_term(
            &mut admin_cap,
            60,
            10, // 10% APY for 60 day term
        );

        pool.delete_lock_term(
            &mut admin_cap,
            60,
        );

        ts::return_to_address(ADMIN, admin_cap);
        ts::return_shared(pool);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = ERemovingDefaultTerm)]
fun test_remove_default_term() {
    let mut scenario = init_deposit_pool(true, 0);

    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

        pool.delete_lock_term(
            &mut admin_cap,
            0,
        );

        ts::return_to_address(ADMIN, admin_cap);
        ts::return_shared(pool);
    };

    scenario.end();
}

#[test]
fun test_early_withdrawal_allowed() {
    let mut scenario = init_deposit_pool(true, 0);

    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);

    scenario.next_tx(ADMIN);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    add_lock_term_for_testing(&mut scenario, &mut pool, Lock_DAY, Base_APY);

    scenario.next_tx(USER);
    {
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            Lock_DAY,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );
    };

    // just before mature
    clock.increment_for_testing(Lock_DAY as u64* MS_PER_DAY - 1);

    scenario.next_tx(USER);
    {
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);

        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);

        // Verify user received their base tokens back
        let returned_coin = ts::take_from_address<Coin<Base>>(&scenario, USER);
        assert!(coin::value(&returned_coin) == Deposit, 1);

        scenario.next_tx(USER);
        // Verify no loyalty tokens were issued
        assert!(!ts::has_most_recent_for_address<Token<Loyalty>>(USER), 2);

        ts::return_to_address(USER, returned_coin);
    };

    ts::return_shared(pool);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_withdrawal_at_mature() {
    let mut scenario = init_deposit_pool(true, 0);

    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);

    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);

    add_lock_term_for_testing(&mut scenario, &mut pool, Lock_DAY, Base_APY*2);

    scenario.next_tx(USER);
    {
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            Lock_DAY,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );

        // Advance clock past term
        clock.increment_for_testing(Lock_DAY as u64 * MS_PER_DAY);

        scenario.next_tx(USER);
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);

        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);

        // Verify base tokens returned
        let returned_coin = ts::take_from_address<Coin<Base>>(&scenario, USER);
        assert!(coin::value(&returned_coin) == Deposit, 1);

        // Verify loyalty tokens were issued
        assert!(ts::has_most_recent_for_address<Token<Loyalty>>(USER), 2);
        let loyalty_tokens = ts::take_from_address<Token<Loyalty>>(&scenario, USER);

        // Calculate expected rewards (deposit_amount * APY * days / 365)
        // Base_APY is 5%
        let expected_rewards =
            (
            (((Deposit as u128) * (2* Base_APY as u128))/10_u128.pow(DEFAULT_DECIMAL)) * (Lock_DAY as u128),
        )/365;
        assert!(loyalty_tokens.value() == (expected_rewards as u64), 3);

        ts::return_to_address(USER, returned_coin);
        ts::return_to_address(USER, loyalty_tokens);
        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_withdrawal_honors_original_apy() {
    let mut scenario = init_deposit_pool(true, 0);

    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);

    let higher_apy = Base_APY * 2; // Double the base APY

    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    // First set a higher APY term as admin
    add_lock_term_for_testing(&mut scenario, &mut pool, Lock_DAY, higher_apy);

    // User deposits with the higher APY term
    scenario.next_tx(USER);
    {
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            Lock_DAY,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );
    };

    // Admin removes the term
    scenario.next_tx(ADMIN);
    {
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

        pool.delete_lock_term(
            &mut admin_cap,
            Lock_DAY,
        );

        ts::return_to_address(ADMIN, admin_cap);
    };

    // Advance clock past term
    clock.increment_for_testing(MS_PER_DAY * (Lock_DAY as u64 + 1));

    // User withdraws - should get rewards based on original higher APY
    scenario.next_tx(USER);
    {
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);

        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);

        // Verify base tokens returned
        let returned_coin = ts::take_from_address<Coin<Base>>(&scenario, USER);
        assert!(coin::value(&returned_coin) == Deposit, 1);

        // Verify loyalty tokens were issued at original higher APY
        assert!(ts::has_most_recent_for_address<Token<Loyalty>>(USER), 2);
        let loyalty_tokens = ts::take_from_address<Token<Loyalty>>(&scenario, USER);

        // Calculate expected rewards with original higher APY
        // (deposit_amount * higher_apy * days / 365)
        let expected_rewards =
            (
            (((Deposit as u128) * (higher_apy as u128) )/10_u128.pow(DEFAULT_DECIMAL)) * ((Lock_DAY+1) as u128 ),
        )/365;
        assert!(loyalty_tokens.value() == (expected_rewards as u64), 3);

        ts::return_to_address(USER, returned_coin);
        ts::return_to_address(USER, loyalty_tokens);
    };

    clock.destroy_for_testing();
    ts::return_shared(pool);
    scenario.end();
}

#[test]
fun test_early_withdrawl_with_pending_allowed() {
    let mut scenario = init_deposit_pool(true, Pending_DAY);
    // Enable withdrawal pending for Pending_DAY days

    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);

    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            Lock_DAY,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);

        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);
        // Advance clock past the pending period (38 days)
        clock.increment_for_testing(Pending_DAY as u64 * MS_PER_DAY);

        // need to pick receipt again
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);

        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);
        // Verify base tokens returned
        let returned_coin = ts::take_from_address<Coin<Base>>(&scenario, USER);
        assert!(coin::value(&returned_coin) == Deposit, 1);
        // early withdrawl, no token return
        assert!(!ts::has_most_recent_for_sender<Token<Loyalty>>(&scenario), 2);
        returned_coin.burn_for_testing();
        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    scenario.end();
}
#[test]
fun test_early_withdrawl_with_pending_allowed_and_withdrawal_after_mature() {
    let mut scenario = init_deposit_pool(true, Pending_DAY);
    // Enable withdrawal pending for Pending_DAY days

    scenario.next_tx(ADMIN);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    add_lock_term_for_testing(&mut scenario, &mut pool, Lock_DAY, Base_APY);

    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);

    scenario.next_tx(USER);
    {
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            Lock_DAY,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);

        // Advance clock just before mature
        clock.increment_for_testing(Lock_DAY as u64 * MS_PER_DAY-1);

        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);
        // Advance clock past the pending period (38 days)
        clock.increment_for_testing(Pending_DAY as u64 * MS_PER_DAY);

        // need to pick receipt again
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);

        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);
        // Verify base tokens returned
        let returned_coin = ts::take_from_address<Coin<Base>>(&scenario, USER);
        assert!(coin::value(&returned_coin) == Deposit, 1);

        // still early withdrawl, no token return
        assert!(!ts::has_most_recent_for_sender<Token<Loyalty>>(&scenario), 2);
        returned_coin.burn_for_testing();
    };

    ts::return_shared(pool);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EPendingWithdrawal)]
fun test_withdrawal_before_pending_finished() {
    let mut scenario = init_deposit_pool(true, Pending_DAY); // Enable withdrawal pending for Pending_DAY days

    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);

    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            Lock_DAY,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);

        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);
        // Advance clock past the pending period (less than Pending_DAY days)
        clock.increment_for_testing(Pending_DAY as u64* MS_PER_DAY -1);

        // need to pick receipt again
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);

        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );

        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = ENotSupportEarlyWithdrawal)]
fun test_early_withdrawal_with_pending_pool_not_allowed() {
    let mut scenario = init_deposit_pool(false, Pending_DAY); // Enable withdrawal pending for Pending_DAY days

    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);

    scenario.next_tx(ADMIN);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    add_lock_term_for_testing(&mut scenario, &mut pool, Lock_DAY, Base_APY);
    scenario.next_tx(USER);
    {
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            Lock_DAY,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);

        let receipt = ts::take_from_address<Receipt>(&scenario, USER);

        // Attempt to withdraw early
        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );
    };

    ts::return_shared(pool);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EApyMismatched)]
fun test_mismatch_deposit_expectation() {
    let mut scenario = init_deposit_pool(true, Pending_DAY); // Enable withdrawal pending for Pending_DAY days

    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);

    scenario.next_tx(ADMIN);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    add_lock_term_for_testing(&mut scenario, &mut pool, Lock_DAY, Base_APY);
    scenario.next_tx(USER);
    {
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            Lock_DAY,
            USER,
            some(Base_APY+1),
            &clock,
            scenario.ctx(),
        );
    };
    ts::return_shared(pool);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_withdrawal_with_pending_at_mature() {
    let mut scenario = init_deposit_pool(true, Pending_DAY); // Enable withdrawal pending for Pending_DAY days

    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    add_lock_term_for_testing(&mut scenario, &mut pool, Lock_DAY, Base_APY*2);

    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);

    scenario.next_tx(USER);
    {
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            Lock_DAY, // 60 days term
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);
        // Advance clock past the lock period (61 days)
        clock.increment_for_testing(Lock_DAY as u64 * MS_PER_DAY);
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);

        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);
        // Advance clock past the pending period (Pending_DAY days)
        clock.increment_for_testing(Pending_DAY as u64 * MS_PER_DAY);

        // need to pick receipt again
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);

        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);
        // Verify base tokens returned
        let returned_coin = ts::take_from_address<Coin<Base>>(&scenario, USER);
        assert!(coin::value(&returned_coin) == Deposit, 1);
        // properly withdrawal
        let reward = ts::take_from_address<Token<Loyalty>>(&scenario, USER);
        let expected_rewards =
            (
            (((Deposit as u128) * (2*Base_APY as u128) )/10_u128.pow(DEFAULT_DECIMAL)) * (Lock_DAY as u128 ),
        )/365;
        assert!(reward.value()==expected_rewards as u64, 2);

        reward.burn_for_testing();
        returned_coin.burn_for_testing();
        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_pool_with_different_decimal() {
    let mut scenario = ts::begin(ADMIN);
    // Create treasury cap for Loyalty token
    let loyalty_cap = create_treasury_cap_for_testing<Loyalty>(scenario.ctx());

    // Initialize pool support apy with unit 0.01%
    let high_decimal = 3;
    let apy = 350; // 3.5%
    deposit_pool::new<Base, Loyalty>(
        loyalty_cap,
        apy,
        some(high_decimal),
        true,
        0,
        scenario.ctx(),
    );
    scenario.next_tx(ADMIN);

    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);

    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);

    scenario.next_tx(USER);
    {
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        // use default apy 3.5%
        pool.deposit(
            coin_base,
            0,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);

        // deposit for 1 year
        clock.increment_for_testing(365 as u64 * MS_PER_DAY);

        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);

        // Verify base tokens returned
        let returned_coin = ts::take_from_address<Coin<Base>>(&scenario, USER);
        assert!(coin::value(&returned_coin) == Deposit, 1);

        // Verify loyalty tokens were issued
        assert!(ts::has_most_recent_for_address<Token<Loyalty>>(USER), 2);
        let loyalty_tokens = ts::take_from_address<Token<Loyalty>>(&scenario, USER);

        // Calculate expected rewards (deposit_amount * APY * days / 365)
        // apy is 3.5%
        let expected_rewards = (Deposit as u128) * (350 as u128)/10_u128.pow(high_decimal);
        assert!(loyalty_tokens.value() == (expected_rewards as u64), 3);

        ts::return_to_address(USER, returned_coin);
        ts::return_to_address(USER, loyalty_tokens);
        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_cancel_pending_withdrawal() {
    let mut scenario = init_deposit_pool(true, Pending_DAY); // Enable withdrawal pending for Pending_DAY days

    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    add_lock_term_for_testing(&mut scenario, &mut pool, Lock_DAY, Base_APY*2);

    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);

    scenario.next_tx(USER);
    {
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            Lock_DAY,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);

        // Initiate withdrawal, which will go into pending state, but with no token
        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );

        // Now cancel the pending withdrawal
        scenario.next_tx(USER);
        clock.increment_for_testing(Lock_DAY as u64*MS_PER_DAY);

        let mut receipt = ts::take_from_address<Receipt>(&scenario, USER);
        pool.cancel_pending_withdrawal(&mut receipt);

        scenario.next_tx(USER);
        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );
        // now should be able to claim tokens

        // Now the user should be able to withdraw their tokens again
        scenario.next_tx(USER);

        clock.increment_for_testing(Pending_DAY as u64 * MS_PER_DAY);

        let receipt = ts::take_from_address<Receipt>(&scenario, USER);
        pool.withdraw(
            receipt,
            &clock,
            scenario.ctx(),
        );

        scenario.next_tx(USER);
        // Verify base tokens returned
        let returned_coin = ts::take_from_address<Coin<Base>>(&scenario, USER);
        assert!(coin::value(&returned_coin) == Deposit, 1);

        let reward = ts::take_from_address<Token<Loyalty>>(&scenario, USER);
        let expected_rewards =
            (
            (((Deposit as u128) * (2*Base_APY as u128) )/10_u128.pow(DEFAULT_DECIMAL)) * (Lock_DAY as u128),
        )/365;
        assert!(reward.value()==expected_rewards as u64, 2);

        returned_coin.burn_for_testing();
        reward.burn_for_testing();
        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    scenario.end();
}

fun init_deposit_pool(ealry_withdrawal: bool, pending: u32): Scenario {
    let mut scenario = ts::begin(ADMIN);
    // Create treasury cap for Loyalty token
    let loyalty_cap = create_treasury_cap_for_testing<Loyalty>(scenario.ctx());

    // Initialize pool
    deposit_pool::new<Base, Loyalty>(
        loyalty_cap,
        Base_APY,
        none(),
        ealry_withdrawal,
        pending, // allow early withdrawal
        scenario.ctx(),
    );
    scenario.next_tx(ADMIN);

    scenario
}

fun add_lock_term_for_testing(
    scenario: &mut Scenario,
    pool: &mut DepositPool<Base, Loyalty>,
    lock_days: u32,
    apy: u16,
) {
    scenario.next_tx(USER);

    let mut admin_cap = ts::take_from_address<AdminCap>(scenario, ADMIN);

    pool.upsert_lock_term(
        &mut admin_cap,
        lock_days,
        apy,
    );

    ts::return_to_address(ADMIN, admin_cap);
}

#[test]
fun test_extend_term_success() {
    let mut scenario = init_deposit_pool(false, 0);
    let mut clock = clock::create_for_testing(scenario.ctx());

    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    scenario.next_tx(ADMIN);
    {
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);
        // Enable term extension
        pool.enable_extending_terms(&mut admin_cap);

        // Add two lock terms
        pool.upsert_lock_term(&mut admin_cap, 30, Base_APY); // 30 days, 5% APY
        pool.upsert_lock_term(&mut admin_cap, 60, Base_APY * 2); // 60 days, 10% APY

        ts::return_to_address(ADMIN, admin_cap);
    };

    // User deposits with 30-day term
    scenario.next_tx(USER);
    let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

    pool.deposit(
        coin_base,
        30, // 30-day term
        USER,
        some(Base_APY),
        &clock,
        scenario.ctx(),
    );

    clock.increment_for_testing(30*MS_PER_DAY-1);
    scenario.next_tx(USER);
    // Upgrade to 60-day term 1 ms before mature
    let mut receipt = ts::take_from_address<Receipt>(&scenario, USER);

    pool.upgrade_term(
        &mut receipt,
        60, // upgrade to 60-day term
        some(Base_APY* 2),
        &clock,
    );

    clock.increment_for_testing(30*MS_PER_DAY+1);
    scenario.next_tx(USER);
    pool.withdraw(receipt, &clock, scenario.ctx());

    scenario.next_tx(USER);
    let returned_coin = ts::take_from_address<Coin<Base>>(&scenario, USER);
    assert!(coin::value(&returned_coin) == Deposit, 1);

    let reward = ts::take_from_address<Token<Loyalty>>(&scenario, USER);
    let expected_rewards =
        (
            (((Deposit as u128) * (2*Base_APY as u128) )/10_u128.pow(DEFAULT_DECIMAL)) * (60 as u128),
        )/365;

    assert!(reward.value()==expected_rewards as u64, 2);

    reward.burn_for_testing();
    returned_coin.burn_for_testing();
    clock.destroy_for_testing();
    ts::return_shared(pool);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = ENotSupportExtendTerm)]
fun test_extend_term_without_enabling() {
    let mut scenario = init_deposit_pool(true, 0);
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

        // Add two lock terms without enabling extension
        pool.upsert_lock_term(&mut admin_cap, 30, Base_APY);
        pool.upsert_lock_term(&mut admin_cap, 60, Base_APY * 2);

        ts::return_to_address(ADMIN, admin_cap);
        ts::return_shared(pool);
    };

    // Try to upgrade term (should fail)
    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            30,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );
        scenario.next_tx(USER);
        let mut receipt = ts::take_from_address<Receipt>(&scenario, USER);

        // This should fail because term extension is not enabled
        pool.upgrade_term(
            &mut receipt,
            60,
            none(),
            &clock,
        );

        ts::return_to_address(USER, receipt);
        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EInvalidExtendTerm)]
fun test_extend_term_after_maturity() {
    let mut scenario = init_deposit_pool(true, 0);
    let mut clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

        pool.enable_extending_terms(&mut admin_cap);
        pool.upsert_lock_term(&mut admin_cap, 30, Base_APY);
        pool.upsert_lock_term(&mut admin_cap, 60, Base_APY * 2);

        ts::return_to_address(ADMIN, admin_cap);
        ts::return_shared(pool);
    };

    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            30,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );

        // Advance clock past maturity
        clock::increment_for_testing(&mut clock, 31 * MS_PER_DAY);
        scenario.next_tx(USER);
        let mut receipt = ts::take_from_address<Receipt>(&scenario, USER);

        // Should fail because receipt is already matured
        pool.upgrade_term(
            &mut receipt,
            60,
            none(),
            &clock,
        );

        ts::return_to_address(USER, receipt);
        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EApyMismatched)]
fun test_extend_term_with_higher_apy() {
    let mut scenario = init_deposit_pool(true, 0);
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

        pool.enable_extending_terms(&mut admin_cap);
        pool.upsert_lock_term(&mut admin_cap, 30, Base_APY);
        pool.upsert_lock_term(&mut admin_cap, 60, Base_APY * 3); // Higher APY term

        ts::return_to_address(ADMIN, admin_cap);
        ts::return_shared(pool);
    };

    // Deposit with lower APY term
    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            30, // 30-day term
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );
        scenario.next_tx(USER);
        let mut receipt = ts::take_from_address<Receipt>(&scenario, USER);

        // Upgrade with high expectation
        pool.upgrade_term(
            &mut receipt,
            60,
            some(Base_APY * 3+1), // too high
            &clock,
        );

        ts::return_to_address(USER, receipt);
        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure]
fun test_extend_term_with_non_listed_apy() {
    let mut scenario = init_deposit_pool(true, 0);
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

        pool.enable_extending_terms(&mut admin_cap);
        pool.upsert_lock_term(&mut admin_cap, 30, Base_APY);
        // Note: 60-day term not added

        ts::return_to_address(ADMIN, admin_cap);
        ts::return_shared(pool);
    };

    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            30,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );
        scenario.next_tx(USER);
        let mut receipt = ts::take_from_address<Receipt>(&scenario, USER);

        // Try to upgrade to non-existent term (should fail)
        pool.upgrade_term(
            &mut receipt,
            60,
            none(),
            &clock,
        );

        ts::return_to_address(USER, receipt);
        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EApyMismatched)]
fun test_extend_term_with_longer_but_lower_apy() {
    let mut scenario = init_deposit_pool(true, 0);
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

        pool.enable_extending_terms(&mut admin_cap);
        pool.upsert_lock_term(&mut admin_cap, 30, Base_APY);
        // Note: 60-day has lower apy
        pool.upsert_lock_term(&mut admin_cap, 60, Base_APY-1);

        ts::return_to_address(ADMIN, admin_cap);
        ts::return_shared(pool);
    };

    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            30,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );
        scenario.next_tx(USER);
        let mut receipt = ts::take_from_address<Receipt>(&scenario, USER);

        // Try to upgrade to a term with lower apy by mistake should fail
        pool.upgrade_term(
            &mut receipt,
            60,
            none(),
            &clock,
        );

        ts::return_to_address(USER, receipt);
        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_extend_term_with_longer_but_expected_lower_apy() {
    let mut scenario = init_deposit_pool(true, 0);
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

        pool.enable_extending_terms(&mut admin_cap);
        pool.upsert_lock_term(&mut admin_cap, 30, Base_APY);
        // Note: 60-day has lower apy
        pool.upsert_lock_term(&mut admin_cap, 60, Base_APY-1);

        ts::return_to_address(ADMIN, admin_cap);
        ts::return_shared(pool);
    };

    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            30,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );
        scenario.next_tx(USER);
        let mut receipt = ts::take_from_address<Receipt>(&scenario, USER);

        // Try to upgrade to a term with lower apy by mistake should fail
        pool.upgrade_term(
            &mut receipt,
            60,
            some(Base_APY-1),
            &clock,
        );

        ts::return_to_address(USER, receipt);
        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = ENotSupportExtendTerm)]
fun test_extend_term_after_disabled() {
    let mut scenario = init_deposit_pool(true, 0);
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

        pool.enable_extending_terms(&mut admin_cap);
        pool.upsert_lock_term(&mut admin_cap, 30, Base_APY);
        pool.upsert_lock_term(&mut admin_cap, 60, Base_APY * 2);

        // Disable term extension after setup
        pool.disable_extending_terms(&mut admin_cap);

        ts::return_to_address(ADMIN, admin_cap);
        ts::return_shared(pool);
    };

    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        pool.deposit(
            coin_base,
            30,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );
        scenario.next_tx(USER);
        let mut receipt = ts::take_from_address<Receipt>(&scenario, USER);

        // Try to upgrade after disabled (should fail)
        pool.upgrade_term(
            &mut receipt,
            60,
            none(),
            &clock,
        );

        ts::return_to_address(USER, receipt);
        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EApyMismatched)]
fun test_upgrade_to_a_lower_term() {
    let mut scenario = init_deposit_pool(true, 0);
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

        pool.enable_extending_terms(&mut admin_cap);
        pool.upsert_lock_term(&mut admin_cap, 60, Base_APY * 2);
        pool.upsert_lock_term(&mut admin_cap, 30, Base_APY);

        ts::return_to_address(ADMIN, admin_cap);
        ts::return_shared(pool);
    };

    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());

        // Deposit with longer term
        pool.deposit(
            coin_base,
            60,
            USER,
            none(),
            &clock,
            scenario.ctx(),
        );
        scenario.next_tx(USER);
        let mut receipt = ts::take_from_address<Receipt>(&scenario, USER);

        // Try to upgrade to shorter term (should fail)
        pool.upgrade_term(
            &mut receipt,
            30,
            none(),
            &clock,
        );

        ts::return_to_address(USER, receipt);
        ts::return_shared(pool);
    };

    clock.destroy_for_testing();
    scenario.end();
}
