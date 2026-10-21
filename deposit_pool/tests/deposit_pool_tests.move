#[test_only]
module deposit_pool::test_deposit_pool;

use deposit_pool::deposit_pool::{
    Self,
    AdminCap,
    DepositPool,
    Receipt,
    new_vesting,
    VestingCreatedEvent,
    VestingStoppedEvent,
    vesting_options_length_for_testing,
    vesting_created_event_matches_for_testing,
    ENotSupportEarlyWithdrawal,
    EPendingWithdrawal,
    ERemovingDefaultTerm,
    EApyMismatched,
    ENotSupportExtendTerm,
    EInvalidExtendTerm,
    ENotAdmin,
    EInvalidVestingPlan,
    ESealedVestingPool,
    EVestingStopNotAllowed,
    EVestingAlreadyStopped,
    EVestingStopped,
};
use std::bcs;
use std::option::{none, some};
use std::vector;
use sui::clock::{Self, Clock};
use sui::coin::{Self, create_treasury_cap_for_testing, Coin};
use sui::event;
use sui::object;
use sui::test_scenario::{Self as ts, Scenario};
use sui::token::{Token, TokenPolicyCap};
use sui::transfer;

const ADMIN: address = @0xA11ce;
const USER: address = @0xB0B;
const NEW_ADMIN: address = @0xC0FFEE;
const Base_APY: u16 = 5;
const Deposit: u64 = 1000000000;
const Lock_DAY: u32 = 60;
const Pending_DAY: u32 = 7;
const MS_PER_DAY: u64 = 86400000;
const DEFAULT_DECIMAL: u8 = 2;
const MAX_U64: u64 = 18446744073709551615;

public struct Loyalty has drop {}
public struct Base has drop {}
public struct OtherBase has drop {}
public struct RewardPolicy has drop {}

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
fun test_vesting_creation_transfers_fixed_zero_apy_receipts() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1000);
    create_test_vesting(&mut scenario, &clock, 600, true);
    assert!(event::events_by_type<VestingCreatedEvent>().length() == 1, 0);

    scenario.next_tx(ADMIN);
    let admin = scenario.take_from_sender<AdminCap>();
    scenario.return_to_sender(admin);
    let pool = scenario.take_shared<DepositPool<Base, Loyalty>>();
    assert!(vesting_options_length_for_testing(&pool) == 4, 0);
    ts::return_shared(pool);

    scenario.next_tx(USER);
    let first = ts::take_from_address<Receipt>(&scenario, USER);
    let second = ts::take_from_address<Receipt>(&scenario, USER);
    let third = ts::take_from_address<Receipt>(&scenario, USER);
    ts::return_to_address(USER, first);
    ts::return_to_address(USER, second);
    ts::return_to_address(USER, third);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_future_cliff_only_vesting_is_claimable_at_start() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1000);
    create_test_vesting_plan(
        &mut scenario,
        &clock,
        600,
        2000,
        600,
        0,
        vector[],
        true,
    );
    assert!(!ts::has_most_recent_for_address<Coin<Base>>(USER), 0);

    scenario.next_tx(USER);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    let receipt = ts::take_from_address<Receipt>(&scenario, USER);
    clock::set_for_testing(&mut clock, 2000);
    pool.withdraw(receipt, &clock, scenario.ctx());
    ts::return_shared(pool);

    scenario.next_tx(USER);
    let claimed = ts::take_from_address<Coin<Base>>(&scenario, USER);
    assert!(coin::value(&claimed) == 600, 1);
    coin::burn_for_testing(claimed);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_equal_clock_start_accepts_irregular_dates_and_emits_scalar_event_data() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1000);
    create_test_vesting_plan(
        &mut scenario,
        &clock,
        500,
        1000,
        300,
        100,
        vector[1001u64, 1041],
        true,
    );
    let mut created_events = event::events_by_type<VestingCreatedEvent>();
    let created_event = vector::pop_back(&mut created_events);
    assert!(
        vesting_created_event_matches_for_testing(
            created_event,
            500,
            vector[1001u64, 1041],
            300,
            100,
        ),
        0,
    );
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_zero_cliff_plan_has_only_later_receipt() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1000);
    create_test_vesting_plan(
        &mut scenario,
        &clock,
        600,
        2000,
        0,
        600,
        vector[3000u64],
        true,
    );

    scenario.next_tx(USER);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    let receipt = ts::take_from_address<Receipt>(&scenario, USER);
    assert!(!ts::has_most_recent_for_address<Receipt>(USER), 0);
    clock::set_for_testing(&mut clock, 3000);
    pool.withdraw(receipt, &clock, scenario.ctx());
    ts::return_shared(pool);

    scenario.next_tx(USER);
    let claimed = ts::take_from_address<Coin<Base>>(&scenario, USER);
    assert!(coin::value(&claimed) == 600, 1);
    coin::burn_for_testing(claimed);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EInvalidVestingPlan)]
fun test_vesting_rejects_empty_plan() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());
    create_test_vesting_plan(
        &mut scenario,
        &clock,
        1,
        1000,
        0,
        0,
        vector[],
        true,
    );
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EInvalidVestingPlan)]
fun test_vesting_rejects_past_schedule_start() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1000);
    create_test_vesting_plan(
        &mut scenario,
        &clock,
        2,
        999,
        1,
        1,
        vector[2000u64],
        true,
    );
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EInvalidVestingPlan)]
fun test_vesting_rejects_maturity_equal_to_start() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());
    create_test_vesting_plan(
        &mut scenario,
        &clock,
        1,
        1000,
        0,
        1,
        vector[1000u64],
        true,
    );
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EInvalidVestingPlan)]
fun test_vesting_rejects_duplicate_maturities() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());
    create_test_vesting_plan(
        &mut scenario,
        &clock,
        2,
        1000,
        0,
        1,
        vector[2000u64, 2000],
        true,
    );
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EInvalidVestingPlan)]
fun test_vesting_rejects_out_of_order_maturities() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());
    create_test_vesting_plan(
        &mut scenario,
        &clock,
        2,
        1000,
        0,
        1,
        vector[2002u64, 2001],
        true,
    );
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EInvalidVestingPlan)]
fun test_vesting_rejects_zero_later_amount() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());
    create_test_vesting_plan(
        &mut scenario,
        &clock,
        1,
        1000,
        0,
        0,
        vector[2000u64],
        true,
    );
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure]
fun test_vesting_multiplication_overflow_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());
    create_test_vesting_plan(
        &mut scenario,
        &clock,
        MAX_U64,
        1000,
        0,
        MAX_U64,
        vector[2000u64, 3000],
        true,
    );
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure]
fun test_vesting_addition_overflow_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());
    create_test_vesting_plan(
        &mut scenario,
        &clock,
        MAX_U64,
        1000,
        MAX_U64,
        1,
        vector[2000u64],
        true,
    );
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EInvalidVestingPlan)]
fun test_vesting_rejects_more_than_256_total_receipts_including_cliff() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut maturities_ms = vector[];
    let mut i = 0;
    while (i < 256) {
        vector::push_back(&mut maturities_ms, 1001 + i);
        i = i + 1;
    };
    create_test_vesting_plan(
        &mut scenario,
        &clock,
        257,
        1000,
        1,
        1,
        maturities_ms,
        true,
    );
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_vesting_accepts_256_total_receipts_including_cliff() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut maturities_ms = vector[];
    let mut i = 0;
    while (i < 255) {
        vector::push_back(&mut maturities_ms, 1001 + i);
        i = i + 1;
    };
    create_test_vesting_plan(
        &mut scenario,
        &clock,
        256,
        1000,
        1,
        1,
        maturities_ms,
        true,
    );
    assert!(event::events_by_type<VestingCreatedEvent>().length() == 1, 0);
    scenario.next_tx(USER);
    let mut i = 0;
    while (i < 256) {
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);
        ts::return_to_address(USER, receipt);
        i = i + 1;
    };
    assert!(!ts::has_most_recent_for_address<Receipt>(USER), 1);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EInvalidVestingPlan)]
fun test_vesting_creation_rejects_funding_mismatch() {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());
    create_test_vesting_plan(
        &mut scenario,
        &clock,
        599,
        1000,
        0,
        200,
        vector[2000u64, 3000, 4000],
        true,
    );
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = ENotSupportEarlyWithdrawal)]
fun test_vesting_receipt_cannot_be_withdrawn_before_installment_maturity() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1999);
    create_test_vesting(&mut scenario, &clock, 600, true);

    scenario.next_tx(USER);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    let receipt = ts::take_from_address<Receipt>(&scenario, USER);
    pool.withdraw(receipt, &clock, scenario.ctx());
    ts::return_shared(pool);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = ESealedVestingPool)]
fun test_vesting_pool_rejects_direct_deposit() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1000);
    create_test_vesting(&mut scenario, &clock, 600, true);

    scenario.next_tx(USER);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    let funding = coin::mint_for_testing<Base>(1, scenario.ctx());
    pool.deposit(funding, 0, USER, none(), &clock, scenario.ctx());
    ts::return_shared(pool);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EVestingStopNotAllowed)]
fun test_vesting_stop_requires_opt_in() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1000);
    create_test_vesting(&mut scenario, &clock, 600, false);

    scenario.next_tx(ADMIN);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    let admin = ts::take_from_address<AdminCap>(&scenario, ADMIN);
    pool.stop_vesting(&admin, &clock, scenario.ctx());
    ts::return_to_address(ADMIN, admin);
    ts::return_shared(pool);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_vesting_stop_returns_matured_unclaimed_principal() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 2000);
    create_test_vesting(&mut scenario, &clock, 600, true);

    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let admin = ts::take_from_address<AdminCap>(&scenario, ADMIN);
        pool.stop_vesting(&admin, &clock, scenario.ctx());
        assert!(event::events_by_type<VestingStoppedEvent>().length() == 1, 0);
        ts::return_to_address(ADMIN, admin);
        ts::return_shared(pool);
    };

    scenario.next_tx(ADMIN);
    let refund = ts::take_from_address<Coin<Base>>(&scenario, ADMIN);
    assert!(coin::value(&refund) == 600, 0);
    coin::burn_for_testing(refund);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_transferred_matching_admin_cap_stops_and_receives_refund() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1000);
    create_test_vesting(&mut scenario, &clock, 600, true);

    scenario.next_tx(ADMIN);
    let admin = ts::take_from_address<AdminCap>(&scenario, ADMIN);
    transfer::public_transfer(admin, NEW_ADMIN);

    scenario.next_tx(NEW_ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let admin = ts::take_from_address<AdminCap>(&scenario, NEW_ADMIN);
        pool.stop_vesting(&admin, &clock, scenario.ctx());

        let stopped_events = event::events_by_type<VestingStoppedEvent>();
        assert!(vector::length(&stopped_events) == 1, 0);
        assert!(
            vesting_stopped_event_sender_matches_for_testing(
                vector::borrow(&stopped_events, 0),
                &pool,
                &admin,
                NEW_ADMIN,
            ),
            1,
        );

        ts::return_to_address(NEW_ADMIN, admin);
        ts::return_shared(pool);
    };

    scenario.next_tx(ADMIN);
    assert!(!ts::has_most_recent_for_address<Coin<Base>>(ADMIN), 2);

    scenario.next_tx(NEW_ADMIN);
    let refund = ts::take_from_address<Coin<Base>>(&scenario, NEW_ADMIN);
    assert!(coin::value(&refund) == 600, 3);
    coin::burn_for_testing(refund);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = ENotAdmin)]
fun test_vesting_stop_rejects_wrong_admin_cap() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1000);

    let unrelated_cap = create_treasury_cap_for_testing<Loyalty>(scenario.ctx());
    deposit_pool::new<OtherBase, Loyalty>(
        unrelated_cap,
        Base_APY,
        none(),
        false,
        0,
        scenario.ctx(),
    );
    scenario.next_tx(ADMIN);
    let unrelated_admin = ts::take_from_address<AdminCap>(&scenario, ADMIN);
    transfer::public_transfer(unrelated_admin, USER);

    scenario.next_tx(ADMIN);
    create_test_vesting(&mut scenario, &clock, 600, true);

    scenario.next_tx(USER);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    let wrong_admin = ts::take_from_address<AdminCap>(&scenario, USER);
    pool.stop_vesting(&wrong_admin, &clock, scenario.ctx());
    ts::return_to_address(USER, wrong_admin);
    ts::return_shared(pool);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EVestingAlreadyStopped)]
fun test_vesting_stop_rejects_repeated_stop() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1000);
    create_test_vesting(&mut scenario, &clock, 600, true);

    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let admin = ts::take_from_address<AdminCap>(&scenario, ADMIN);
        pool.stop_vesting(&admin, &clock, scenario.ctx());
        ts::return_to_address(ADMIN, admin);
        ts::return_shared(pool);
    };

    scenario.next_tx(ADMIN);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    let admin = ts::take_from_address<AdminCap>(&scenario, ADMIN);
    pool.stop_vesting(&admin, &clock, scenario.ctx());
    ts::return_to_address(ADMIN, admin);
    ts::return_shared(pool);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = ESealedVestingPool)]
fun test_vesting_receipt_cannot_upgrade_term() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1000);
    create_test_vesting(&mut scenario, &clock, 600, true);

    scenario.next_tx(USER);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    let mut receipt = ts::take_from_address<Receipt>(&scenario, USER);
    pool.upgrade_term(&mut receipt, 1, none(), &clock);
    ts::return_to_address(USER, receipt);
    ts::return_shared(pool);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_partial_vesting_claim_then_stop_conserves_funding() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1000);
    create_test_vesting(&mut scenario, &clock, 600, true);
    clock::set_for_testing(&mut clock, 5000);

    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);
        pool.withdraw(receipt, &clock, scenario.ctx());
        ts::return_shared(pool);
    };

    scenario.next_tx(USER);
    let claimed_coin = ts::take_from_address<Coin<Base>>(&scenario, USER);
    let claimed_amount = coin::value(&claimed_coin);
    assert!(claimed_amount > 0 && claimed_amount < 600, 1);
    coin::burn_for_testing(claimed_coin);

    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let admin = ts::take_from_address<AdminCap>(&scenario, ADMIN);
        pool.stop_vesting(&admin, &clock, scenario.ctx());
        ts::return_to_address(ADMIN, admin);
        ts::return_shared(pool);
    };

    scenario.next_tx(ADMIN);
    let refund = ts::take_from_address<Coin<Base>>(&scenario, ADMIN);
    assert!(claimed_amount + coin::value(&refund) == 600, 2);
    coin::burn_for_testing(refund);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EVestingStopped)]
fun test_stopped_vesting_receipt_cannot_be_withdrawn() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1000);
    create_test_vesting(&mut scenario, &clock, 600, true);

    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let admin = ts::take_from_address<AdminCap>(&scenario, ADMIN);
        pool.stop_vesting(&admin, &clock, scenario.ctx());
        ts::return_to_address(ADMIN, admin);
        ts::return_shared(pool);
    };

    scenario.next_tx(USER);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    let receipt = ts::take_from_address<Receipt>(&scenario, USER);
    pool.withdraw(receipt, &clock, scenario.ctx());
    ts::return_shared(pool);
    clock.destroy_for_testing();
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

#[test]
#[expected_failure(abort_code = ESealedVestingPool)]
fun test_vesting_pool_rejects_reward_program_attachment() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1000);
    create_test_vesting(&mut scenario, &clock, 600, true);

    scenario.next_tx(ADMIN);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    let mut admin = ts::take_from_address<AdminCap>(&scenario, ADMIN);
    pool.add_reward_program<RewardPolicy, Base, Loyalty>(&mut admin, scenario.ctx());
    ts::return_to_address(ADMIN, admin);
    ts::return_shared(pool);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_normal_pool_accepts_reward_program() {
    let mut scenario = init_deposit_pool(true, 0);

    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let mut admin = ts::take_from_address<AdminCap>(&scenario, ADMIN);
        pool.add_reward_program<RewardPolicy, Base, Loyalty>(&mut admin, scenario.ctx());
        ts::return_to_address(ADMIN, admin);
        ts::return_shared(pool);
    };

    scenario.next_tx(ADMIN);
    assert!(ts::has_most_recent_for_address<TokenPolicyCap<Loyalty>>(ADMIN), 0);
    scenario.end();
}

#[test]
fun test_vesting_claims_skip_reward_mint_for_cliff_and_later_rows() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1000);
    create_test_vesting_plan(
        &mut scenario,
        &clock,
        5,
        2000,
        2,
        3,
        vector[3000u64],
        true,
    );
    clock::set_for_testing(&mut clock, 2000);

    scenario.next_tx(USER);
    {
        let later_id = ts::most_recent_id_for_address<Receipt>(USER).destroy_some();
        let later_receipt = ts::take_from_address_by_id<Receipt>(&scenario, USER, later_id);
        let cliff_id = ts::most_recent_id_for_address<Receipt>(USER).destroy_some();
        ts::return_to_address(USER, later_receipt);
        let cliff_receipt = ts::take_from_address_by_id<Receipt>(&scenario, USER, cliff_id);
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        pool.withdraw(cliff_receipt, &clock, scenario.ctx());
        ts::return_shared(pool);
    };

    scenario.next_tx(USER);
    let cliff_principal = ts::take_from_address<Coin<Base>>(&scenario, USER);
    assert!(coin::value(&cliff_principal) == 2, 0);
    assert!(!ts::has_most_recent_for_address<Token<Loyalty>>(USER), 1);
    coin::burn_for_testing(cliff_principal);

    let later_id = ts::most_recent_id_for_address<Receipt>(USER).destroy_some();
    assert!(ts::has_most_recent_for_address<Receipt>(USER), 2);
    clock::set_for_testing(&mut clock, 3000);

    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
        let receipt = ts::take_from_address_by_id<Receipt>(&scenario, USER, later_id);
        pool.withdraw(receipt, &clock, scenario.ctx());
        ts::return_shared(pool);
    };

    scenario.next_tx(USER);
    let delayed_principal = ts::take_from_address<Coin<Base>>(&scenario, USER);
    assert!(coin::value(&delayed_principal) == 3, 3);
    assert!(!ts::has_most_recent_for_address<Token<Loyalty>>(USER), 4);
    coin::burn_for_testing(delayed_principal);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = ENotSupportEarlyWithdrawal)]
fun test_later_vesting_receipt_is_unavailable_at_cliff_maturity() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 1000);
    create_test_vesting_plan(
        &mut scenario,
        &clock,
        5,
        2000,
        2,
        3,
        vector[3000u64],
        true,
    );
    clock::set_for_testing(&mut clock, 2000);

    scenario.next_tx(USER);
    let later_id = ts::most_recent_id_for_address<Receipt>(USER).destroy_some();
    let receipt = ts::take_from_address_by_id<Receipt>(&scenario, USER, later_id);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    pool.withdraw(receipt, &clock, scenario.ctx());
    ts::return_shared(pool);
    clock.destroy_for_testing();
    scenario.end();
}

fun create_test_vesting(
    scenario: &mut Scenario,
    clock: &Clock,
    funding_amount: u64,
    stop_allowed: bool,
) {
    let schedule_start_ms = clock.timestamp_ms() + 1000;
    let maturities_ms = vector[
        schedule_start_ms + 1000,
        schedule_start_ms + 2000,
        schedule_start_ms + 3000,
    ];
    create_test_vesting_plan(
        scenario,
        clock,
        funding_amount,
        schedule_start_ms,
        0,
        200,
        maturities_ms,
        stop_allowed,
    );
}
fun create_test_vesting_plan(
    scenario: &mut Scenario,
    clock: &Clock,
    funding_amount: u64,
    schedule_start_ms: u64,
    cliff_amount: u64,
    vest_amount: u64,
    maturities_ms: vector<u64>,
    stop_allowed: bool,
) {
    let loyalty_cap = create_treasury_cap_for_testing<Loyalty>(scenario.ctx());
    let funding = coin::mint_for_testing<Base>(funding_amount, scenario.ctx());
    new_vesting(
        loyalty_cap,
        funding,
        USER,
        schedule_start_ms,
        cliff_amount,
        vest_amount,
        maturities_ms,
        stop_allowed,
        clock,
        scenario.ctx(),
    );
}

fun vesting_stopped_event_sender_matches_for_testing(
    stopped_event: &VestingStoppedEvent,
    pool: &DepositPool<Base, Loyalty>,
    admin: &AdminCap,
    expected_sender: address,
): bool {
    let stopped_event_bytes = bcs::to_bytes(stopped_event);
    let pool_id = object::id(pool);
    let admin_id = object::id(admin);
    let pool_id_bytes = bcs::to_bytes(&pool_id);
    let admin_id_bytes = bcs::to_bytes(&admin_id);
    let expected_sender_bytes = bcs::to_bytes(&expected_sender);
    let sender_offset = vector::length(&pool_id_bytes) + vector::length(&admin_id_bytes);

    if (
        vector::length(&stopped_event_bytes)
            < sender_offset + vector::length(&expected_sender_bytes)
    ) {
        return false
    };

    let mut i = 0;
    while (i < vector::length(&expected_sender_bytes)) {
        if (
            *vector::borrow(&stopped_event_bytes, sender_offset + i)
                != *vector::borrow(&expected_sender_bytes, i)
        ) {
            return false
        };
        i = i + 1;
    };

    true
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
