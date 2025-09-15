#[test_only]
module deposit_pool::test_deposit_pool;

use deposit_pool::deposit_pool::{Self, AdminCap, DepositPool,Receipt,ENotSupportEarlyWithdrawal};
use sui::test_scenario::{Self as ts, Scenario};
use sui::coin::{Self,create_treasury_cap_for_testing};
use sui::clock::{Self};
use sui::coin::Coin;
use sui::token::Token;

const ADMIN: address = @0xA11ce;
const USER: address = @0xB0B;
const Base_APY: u8 = 5;
const MS_PER_DAY: u64 = 86400000;

public struct Loyalty has drop {}
public struct Base has drop {}


fun init_deposit_pool(ealry_withdrawal: bool): Scenario {
    let mut scenario = ts::begin(ADMIN);
    // Create treasury cap for Loyalty token
    let loyalty_cap = create_treasury_cap_for_testing<Loyalty>(scenario.ctx());

    // Initialize pool
    deposit_pool::initiate<Base, Loyalty>(
        loyalty_cap,
        Base_APY,
        ealry_withdrawal, // allow early withdrawal
        scenario.ctx()
    );

    scenario
}

#[test]
fun test_pool_initialization() {
    let mut scenario = init_deposit_pool(true);
    
    ts::next_tx(&mut scenario, ADMIN);
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
fun test_deposit_and_withdrawal() {
    let mut scenario = init_deposit_pool(true);
    
    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);
    
    scenario.next_tx( USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_Base = coin::mint_for_testing<Base>(1000, scenario.ctx());
        
        deposit_pool::deposit(
            &mut pool,
            coin_Base,
            30, // 30 days term
            &clock,
            USER,
            scenario.ctx()
        );
        
        ts::return_shared(pool);
    };

    // Advance clock past term
    clock::increment_for_testing(&mut clock, MS_PER_DAY * 31);
    
    scenario.next_tx( USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);
        
        deposit_pool::withdrawal(
            &mut pool,
            receipt,
            &clock,
            scenario.ctx()
        );
        
        ts::return_shared(pool);
    };
    
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ENotSupportEarlyWithdrawal)]
fun test_early_withdrawal_not_allowed() {
    let mut scenario = init_deposit_pool(false);
    
    let clock = clock::create_for_testing(scenario.ctx());
    

    scenario.next_tx( ADMIN);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    {
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);
        
        deposit_pool::upsert_lock_term(
            &mut pool,
            &mut admin_cap,
            30,
            10, // 10% APY for 30 day term
        );
        
        ts::return_to_address(ADMIN, admin_cap);
    };
    scenario.next_tx( USER);
    {
        let coin_Base = coin::mint_for_testing<Base>(1000, scenario.ctx());
        
        deposit_pool::deposit(
            &mut pool,
            coin_Base,
            30,
            &clock,
            USER,
            scenario.ctx()
        );
        
    };
    
    scenario.next_tx( USER);
    {
        let receipt = scenario.take_from_sender<Receipt>();
        
        // Should fail - trying to withdraw early
        deposit_pool::withdrawal(
            &mut pool,
            receipt,
            &clock,
            scenario.ctx()
        );
        
    };
    
    ts::return_shared(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_admin_functions() {
    let mut scenario = init_deposit_pool(true);
    
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);
        
        deposit_pool::upsert_lock_term(
            &mut pool,
            &mut admin_cap,
            60,
            10, // 10% APY for 60 day term
        );
        
        deposit_pool::delete_lock_term(
            &mut pool,
            &mut admin_cap,
            60,
        );
        
        ts::return_to_address(ADMIN, admin_cap);
        ts::return_shared(pool);
    };
    
    ts::end(scenario);
}

#[test]
fun test_early_withdrawal_allowed() {
    let mut scenario = init_deposit_pool(true);
    
    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);
    
    let deposit_amount = 1000;

    scenario.next_tx( ADMIN);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    {
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);
        
        deposit_pool::upsert_lock_term(
            &mut pool,
            &mut admin_cap,
            30,
            10, // 10% APY for 30 day term
        );
        
        ts::return_to_address(ADMIN, admin_cap);
    };
    
    scenario.next_tx( USER);
    {
        let coin_base = coin::mint_for_testing<Base>(deposit_amount, scenario.ctx());
        
        deposit_pool::deposit(
            &mut pool,
            coin_base,
            30, // 30 days term
            &clock,
            USER,
            scenario.ctx()
        );
        
    };

    // Advance clock but not past term (15 days)
    clock::increment_for_testing(&mut clock, MS_PER_DAY * 15);
    
    scenario.next_tx( USER);
    {
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);
        
        deposit_pool::withdrawal(
            &mut pool,
            receipt,
            &clock,
            scenario.ctx()
        );

        scenario.next_tx(USER);

         // Verify user received their base tokens back
        let returned_coin = ts::take_from_address<Coin<Base>>(&scenario, USER);
        assert!(coin::value(&returned_coin) == deposit_amount, 1);
        
        scenario.next_tx(USER);
        // Verify no loyalty tokens were issued
        assert!(!ts::has_most_recent_for_address<Token<Loyalty>>(USER), 2);
        
        ts::return_to_address(USER, returned_coin);
    };
    
    
    ts::return_shared(pool);
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_withdrawal_with_rewards() {
    let mut scenario = init_deposit_pool(true);
    
    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);
    
    let deposit_amount = 1000;
    let lock_days = 30;
    
    scenario.next_tx( USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_base = coin::mint_for_testing<Base>(deposit_amount, scenario.ctx());
        
        deposit_pool::deposit(
            &mut pool,
            coin_base,
            lock_days,
            &clock,
            USER,
            scenario.ctx()
        );
        
        ts::return_shared(pool);
    };

    // Advance clock past term (31 days)
    clock::increment_for_testing(&mut clock, MS_PER_DAY * 31);
    
    scenario.next_tx( USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);
        
        deposit_pool::withdrawal(
            &mut pool,
            receipt,
            &clock,
            scenario.ctx()
        );

        scenario.next_tx( USER);
        
        // Verify base tokens returned
        let returned_coin = ts::take_from_address<Coin<Base>>(&scenario, USER);
        assert!(coin::value(&returned_coin) == deposit_amount, 1);
        
        // Verify loyalty tokens were issued
        assert!(ts::has_most_recent_for_address<Token<Loyalty>>(USER), 2);
        let loyalty_tokens = ts::take_from_address<Token<Loyalty>>(&scenario, USER);
        
        // Calculate expected rewards (deposit_amount * APY * days / 365)
        // Base_APY is 5%
        let expected_rewards = ((((deposit_amount as u128) * (Base_APY as u128)).divide_and_round_up(100)) * 31).divide_and_round_up( 365);
        assert!(loyalty_tokens.value() == (expected_rewards as u64), 3);
        
        ts::return_to_address(USER, returned_coin);
        ts::return_to_address(USER, loyalty_tokens);
        ts::return_shared(pool);
    };
    
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}


#[test]
fun test_withdrawal_honors_original_apy() {
    let mut scenario = init_deposit_pool(true);
    
    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);
    
    let deposit_amount = 1000;
    let lock_days = 60;
    let higher_apy = Base_APY * 2; // Double the base APY
    
    // First set a higher APY term as admin
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);
        
        deposit_pool::upsert_lock_term(
            &mut pool,
            &mut admin_cap,
            lock_days,
            higher_apy,
        );
        
        ts::return_to_address(ADMIN, admin_cap);
        ts::return_shared(pool);
    };
    
    // User deposits with the higher APY term
    scenario.next_tx( USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_base = coin::mint_for_testing<Base>(deposit_amount, scenario.ctx());
        
        deposit_pool::deposit(
            &mut pool,
            coin_base,
            lock_days,
            &clock,
            USER,
            scenario.ctx()
        );
        
        ts::return_shared(pool);
    };
    
    // Admin removes the term
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);
        
        deposit_pool::delete_lock_term(
            &mut pool,
            &mut admin_cap,
            lock_days,
        );
        
        ts::return_to_address(ADMIN, admin_cap);
        ts::return_shared(pool);
    };
    
    // Advance clock past term
    clock::increment_for_testing(&mut clock, MS_PER_DAY * (lock_days + 1));
    
    // User withdraws - should get rewards based on original higher APY
    scenario.next_tx( USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);
        
        deposit_pool::withdrawal(
            &mut pool,
            receipt,
            &clock,
            scenario.ctx()
        );
        
        scenario.next_tx( USER);

        // Verify base tokens returned
        let returned_coin = ts::take_from_address<Coin<Base>>(&scenario, USER);
        assert!(coin::value(&returned_coin) == deposit_amount, 1);
        
        // Verify loyalty tokens were issued at original higher APY
        assert!(ts::has_most_recent_for_address<Token<Loyalty>>(USER), 2);
        let loyalty_tokens = ts::take_from_address<Token<Loyalty>>(&scenario, USER);
        
        // Calculate expected rewards with original higher APY
        // (deposit_amount * higher_apy * days / 365)
        let expected_rewards = ((((deposit_amount as u128) * (higher_apy as u128) ).divide_and_round_up(100)) * (lock_days as u128 )).divide_and_round_up(365);
        assert!(loyalty_tokens.value() == (expected_rewards as u64), 3);
        
        ts::return_to_address(USER, returned_coin);
        ts::return_to_address(USER, loyalty_tokens);
        ts::return_shared(pool);
    };
    
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}