#[test_only]
module deposit_pool::test_deposit_pool;

use deposit_pool::deposit_pool::{Self, AdminCap, DepositPool,Receipt,ENotSupportEarlyWithdrawal,EPendingWithdrawal};
use sui::test_scenario::{Self as ts, Scenario};
use sui::coin::{Self,create_treasury_cap_for_testing};
use sui::clock::{Self};
use sui::coin::Coin;
use sui::token::Token;

const ADMIN: address = @0xA11ce;
const USER: address = @0xB0B;
const Base_APY: u8 = 5;
const Deposit:u64 = 1000000000;
const Lock_DAY:u64 = 60;
const Pending_DAY:u64 =7;
const MS_PER_DAY: u64 = 86400000;

public struct Loyalty has drop {}
public struct Base has drop {}



#[test]
fun test_pool_initialization() {
    let mut scenario = init_deposit_pool(true,0);
    
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
    let mut scenario = init_deposit_pool(true,0);
    
    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);
    
    scenario.next_tx( USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_Base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());
        
        deposit_pool::deposit(
            &mut pool,
            coin_Base,
            Lock_DAY,
            &clock,
            USER,
            scenario.ctx()
        );
        
        ts::return_shared(pool);
    };

    // Advance clock past term
    clock.increment_for_testing( MS_PER_DAY * 31);
    
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
    let mut scenario = init_deposit_pool(false,0);
    
    let clock = clock::create_for_testing(scenario.ctx());
    

    scenario.next_tx( ADMIN);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    add_lock_term_for_testing(&mut scenario, &mut pool, Lock_DAY,Base_APY);
    scenario.next_tx( USER);
    {
        let coin_Base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());
        
        deposit_pool::deposit(
            &mut pool,
            coin_Base,
            Lock_DAY,
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
    let mut scenario = init_deposit_pool(true,0);
    
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
    let mut scenario = init_deposit_pool(true,0);
    
    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);

    scenario.next_tx( ADMIN);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    add_lock_term_for_testing(&mut scenario, &mut pool, Lock_DAY,Base_APY);
    
    scenario.next_tx( USER);
    {
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());
        
        deposit_pool::deposit(
            &mut pool,
            coin_base,
            Lock_DAY,
            &clock,
            USER,
            scenario.ctx()
        );
        
    };

    // Advance clock but not past term (15 days)
    clock.increment_for_testing( MS_PER_DAY * 15);
    
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
        assert!(coin::value(&returned_coin) == Deposit, 1);
        
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
    let mut scenario = init_deposit_pool(true,0);
    
    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);
    
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);

    add_lock_term_for_testing(&mut scenario, &mut pool, Lock_DAY,Base_APY*2);
    
    scenario.next_tx( USER);
    {
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());
        
        deposit_pool::deposit(
            &mut pool,
            coin_base,
            Lock_DAY,
            &clock,
            USER,
            scenario.ctx()
        );
        
        // Advance clock past term (60 days)
        clock.increment_for_testing( MS_PER_DAY * Lock_DAY);
    
        scenario.next_tx( USER);
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
        assert!(coin::value(&returned_coin) == Deposit, 1);
        
        // Verify loyalty tokens were issued
        assert!(ts::has_most_recent_for_address<Token<Loyalty>>(USER), 2);
        let loyalty_tokens = ts::take_from_address<Token<Loyalty>>(&scenario, USER);
        
        // Calculate expected rewards (deposit_amount * APY * days / 365)
        // Base_APY is 5%
        let expected_rewards = ((((Deposit as u128) * (2* Base_APY as u128)).divide_and_round_up(100)) * (Lock_DAY as u128)).divide_and_round_up( 365);
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
    let mut scenario = init_deposit_pool(true,0);
    
    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);
    
    let higher_apy = Base_APY * 2; // Double the base APY
    
    // First set a higher APY term as admin
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);
        
        deposit_pool::upsert_lock_term(
            &mut pool,
            &mut admin_cap,
            Lock_DAY,
            higher_apy,
        );
        
        ts::return_to_address(ADMIN, admin_cap);
        ts::return_shared(pool);
    };
    
    // User deposits with the higher APY term
    scenario.next_tx( USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());
        
        deposit_pool::deposit(
            &mut pool,
            coin_base,
            Lock_DAY,
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
            Lock_DAY,
        );
        
        ts::return_to_address(ADMIN, admin_cap);
        ts::return_shared(pool);
    };
    
    // Advance clock past term
    clock.increment_for_testing( MS_PER_DAY * (Lock_DAY + 1));
    
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
        assert!(coin::value(&returned_coin) == Deposit, 1);
        
        // Verify loyalty tokens were issued at original higher APY
        assert!(ts::has_most_recent_for_address<Token<Loyalty>>(USER), 2);
        let loyalty_tokens = ts::take_from_address<Token<Loyalty>>(&scenario, USER);
        
        // Calculate expected rewards with original higher APY
        // (deposit_amount * higher_apy * days / 365)
        let expected_rewards = ((((Deposit as u128) * (higher_apy as u128) ).divide_and_round_up(100)) * ((Lock_DAY+1) as u128 )).divide_and_round_up(365);
        assert!(loyalty_tokens.value() == (expected_rewards as u64), 3);
        
        ts::return_to_address(USER, returned_coin);
        ts::return_to_address(USER, loyalty_tokens);
        ts::return_shared(pool);
    };
    
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
fun test_withdrawal_pending_with_early_withdrawal() {
    let mut scenario = init_deposit_pool(true, Pending_DAY); 
    // Enable withdrawal pending for Pending_DAY days
    
    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);
    
    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());
        
        deposit_pool::deposit(
            &mut pool,
            coin_base,
            Lock_DAY,
            &clock,
            USER,
            scenario.ctx()
        );

        scenario.next_tx(USER);
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);
        
        deposit_pool::withdrawal(
            &mut pool,
            receipt,
            &clock,
            scenario.ctx()
        );
        
        scenario.next_tx(USER);
        // Advance clock past the pending period (38 days)
        clock.increment_for_testing( MS_PER_DAY * Pending_DAY);

        // need to pick receipt again
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);
        
        deposit_pool::withdrawal(
            &mut pool,
            receipt,
            &clock,
            scenario.ctx()
        );

        scenario.next_tx(USER);
        // Verify base tokens returned
        let returned_coin = ts::take_from_address<Coin<Base>>(&scenario, USER);
        assert!(coin::value(&returned_coin) == Deposit, 1);
        // early withdrawl, no token return 
        assert!(!ts::has_most_recent_for_sender<Token<Loyalty>>(&scenario),2);
        returned_coin.burn_for_testing();
        ts::return_shared(pool);
    };
    
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = EPendingWithdrawal)]
fun test_withdrawal_pending_before_pending_finished() {
    let mut scenario = init_deposit_pool(true, Pending_DAY); // Enable withdrawal pending for Pending_DAY days
    
    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);

       scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());
        
        deposit_pool::deposit(
            &mut pool,
            coin_base,
            Lock_DAY,
            &clock,
            USER,
            scenario.ctx()
        );

        scenario.next_tx(USER);
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);
        
        deposit_pool::withdrawal(
            &mut pool,
            receipt,
            &clock,
            scenario.ctx()
        );
        
        scenario.next_tx(USER);
        // Advance clock past the pending period (less than Pending_DAY days)
        clock.increment_for_testing( MS_PER_DAY * 6);


        // need to pick receipt again
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
fun test_early_withdrawal_with_pending() {
    let mut scenario = init_deposit_pool(false, Pending_DAY); // Enable withdrawal pending for Pending_DAY days
    
    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);
    
    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());
        
        deposit_pool::deposit(
            &mut pool,
            coin_base,
            Lock_DAY, 
            &clock,
            USER,
            scenario.ctx()
        );
        
        
        scenario.next_tx(USER);
        
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);
        
        // Attempt to withdraw early
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
fun test_enable_withdrawal_pending_finish_lock_term() {
    let mut scenario = init_deposit_pool(true, Pending_DAY); // Enable withdrawal pending for Pending_DAY days
    
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    add_lock_term_for_testing(&mut scenario, &mut pool, Lock_DAY,Base_APY*2);
    
    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);
    
    scenario.next_tx(USER);
    {

        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());
        
        deposit_pool::deposit(
            &mut pool,
            coin_base,
            Lock_DAY, // 60 days term
            &clock,
            USER,
            scenario.ctx()
        );
        
        // Advance clock past the pending period (8 days)
        clock.increment_for_testing( MS_PER_DAY * 8);
    
        scenario.next_tx(USER);

        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());
        
        deposit_pool::deposit(
            &mut pool,
            coin_base,
            Lock_DAY, // 60 days term
            &clock,
            USER,
            scenario.ctx()
        );


        scenario.next_tx(USER);
        // Advance clock past the lock period (61 days)
        clock.increment_for_testing( MS_PER_DAY * (Lock_DAY+1));
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);
        
        deposit_pool::withdrawal(
            &mut pool,
            receipt,
            &clock,
            scenario.ctx()
        );
        
        scenario.next_tx(USER);
        // Advance clock past the pending period (Pending_DAY days)
        clock.increment_for_testing( MS_PER_DAY * Pending_DAY);

        // need to pick receipt again
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);
        
        deposit_pool::withdrawal(
            &mut pool,
            receipt,
            &clock,
            scenario.ctx()
        );

        scenario.next_tx(USER);
        // Verify base tokens returned
        let returned_coin = ts::take_from_address<Coin<Base>>(&scenario, USER);
        assert!(coin::value(&returned_coin) == Deposit, 1);
        // properly withdrawal
        let reward = ts::take_from_address<Token<Loyalty>>(&scenario, USER);
        let expected_rewards = ((((Deposit as u128) * (2*Base_APY as u128) ).divide_and_round_up(100)) * (1+Lock_DAY as u128 )).divide_and_round_up(365);
        assert!(reward.value()==expected_rewards as u64, 2);

        reward.burn_for_testing();
        returned_coin.burn_for_testing();
        ts::return_shared(pool);
    };
    
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}


#[test]
fun test_cancel_pending_withdrawal() {
    let mut scenario = init_deposit_pool(true, Pending_DAY); // Enable withdrawal pending for Pending_DAY days
    
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    add_lock_term_for_testing(&mut scenario, &mut pool, Lock_DAY,Base_APY*2);

    // Setup clock
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);
    
    scenario.next_tx(USER);
    {
        let coin_base = coin::mint_for_testing<Base>(Deposit, scenario.ctx());
        
        deposit_pool::deposit(
            &mut pool,
            coin_base,
            Lock_DAY,
            &clock,
            USER,
            scenario.ctx()
        );

        scenario.next_tx(USER);
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);
        
        // Initiate withdrawal, which will go into pending state, but with no token
        deposit_pool::withdrawal(
            &mut pool,
            receipt,
            &clock,
            scenario.ctx()
        );

        // Now cancel the pending withdrawal
        scenario.next_tx(USER);
        clock.increment_for_testing(Lock_DAY*MS_PER_DAY);

        let mut receipt = ts::take_from_address<Receipt>(&scenario, USER);
        deposit_pool::cancel_pending_withdrawal(&mut pool, &mut receipt);

        scenario.next_tx(USER);
        deposit_pool::withdrawal(
            &mut pool,
            receipt,
            &clock,
            scenario.ctx()
        );
        // now should be able to claim tokens


        // Now the user should be able to withdraw their tokens again
        scenario.next_tx(USER);
        
        clock.increment_for_testing(MS_PER_DAY*Pending_DAY);
        
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);
        deposit_pool::withdrawal(
            &mut pool,
            receipt,
            &clock,
            scenario.ctx()
        );

        scenario.next_tx(USER);
        // Verify base tokens returned
        let returned_coin = ts::take_from_address<Coin<Base>>(&scenario, USER);
        assert!(coin::value(&returned_coin) == Deposit, 1);
        
        let reward = ts::take_from_address<Token<Loyalty>>(&scenario, USER);
        let expected_rewards = ((((Deposit as u128) * (2*Base_APY as u128) ).divide_and_round_up(100)) * (Lock_DAY as u128) ).divide_and_round_up(365);
        assert!(reward.value()==expected_rewards as u64, 2);

        returned_coin.burn_for_testing();
        reward.burn_for_testing();
        ts::return_shared(pool);
    };
    
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}


fun init_deposit_pool(ealry_withdrawal: bool, pending: u64): Scenario {
    let mut scenario = ts::begin(ADMIN);
    // Create treasury cap for Loyalty token
    let loyalty_cap = create_treasury_cap_for_testing<Loyalty>(scenario.ctx());
    

    // Initialize pool
    deposit_pool::initiate<Base, Loyalty>(
        loyalty_cap,
        Base_APY,
        ealry_withdrawal, 
        pending,// allow early withdrawal
        scenario.ctx()
    );
    scenario.next_tx(ADMIN);

    scenario
}


fun add_lock_term_for_testing(scenario: &mut Scenario, pool:&mut DepositPool<Base,Loyalty>, lock_days:u64, apy:u8) 
{
    scenario.next_tx(USER);

    let mut admin_cap = ts::take_from_address<AdminCap>(scenario, ADMIN);
        
    deposit_pool::upsert_lock_term(
        pool,
        &mut admin_cap,
        lock_days,
        apy,
    );
    
    ts::return_to_address(ADMIN, admin_cap);
}