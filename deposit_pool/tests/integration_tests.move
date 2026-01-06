#[test_only]
module deposit_pool::integration_tests;

use deposit_pool::deposit_pool::{Self, DepositPool, Receipt};
use deposit_pool::reward_pool::{Self as reward_pool, RewardPool};
use std::option::none;
use sui::clock;
use sui::coin;
use sui::test_scenario as ts;
use sui::token::{Self, TokenPolicy};

const ADMIN: address = @0xA11ce;
const USER: address = @0xB0B;
const Base_APY: u16 = 5;
const Deposit: u64 = 1000000000;
const Lock_DAY: u32 = 365;
const MS_PER_DAY: u64 = 86400000;
const DEFAULT_DECIMAL: u8 = 2;
const INITIAL_REWARD_SUPPLY: u64 = 100000000000;

// 1 Loyalty = 10 Reward
const LOYALTY_RER_UNIT: u64 = 1;
const REWARD_PER_UNIT: u64 = 10;

public struct Loyalty has drop {}
public struct Base has drop {}
public struct Reward has drop {}

#[test]
fun test_withdraw_redeem_and_redeposit_in_same_transaction() {
    let mut scenario = ts::begin(ADMIN);
    let loyalty_cap = coin::create_treasury_cap_for_testing<Loyalty>(scenario.ctx());

    deposit_pool::new<Base, Loyalty>(
        loyalty_cap,
        Base_APY,
        none(),
        true,
        0,
        scenario.ctx(),
    );

    // Initialize reward pool
    let reward_coins = coin::mint_for_testing<Reward>(INITIAL_REWARD_SUPPLY, scenario.ctx());
    reward_pool::new<Loyalty, Reward>(
        reward_coins,
        LOYALTY_RER_UNIT,
        REWARD_PER_UNIT,
        scenario.ctx(),
    );

    // Setup token policy for Loyalty token
    scenario.next_tx(ADMIN);
    let loyalty_cap = coin::create_treasury_cap_for_testing<Loyalty>(scenario.ctx());
    let (mut policy, policy_cap) = token::new_policy(&loyalty_cap, scenario.ctx());

    token::add_rule_for_action<Loyalty, reward_pool::RewardProgram>(
        &mut policy,
        &policy_cap,
        token::spend_action(),
        scenario.ctx(),
    );

    token::share_policy(policy);
    transfer::public_transfer(policy_cap, ADMIN);
    transfer::public_freeze_object(loyalty_cap);

    scenario.next_tx(ADMIN);
    let mut pool = ts::take_shared<DepositPool<Base, Loyalty>>(&scenario);
    let mut admin_cap = ts::take_from_address<deposit_pool::AdminCap>(&scenario, ADMIN);

    // Add lock terms
    pool.upsert_lock_term(&mut admin_cap, Lock_DAY, Base_APY * 2);

    // enable wrapper for stroing receipt
    pool.enable_receipt_wrapper(&mut admin_cap);

    ts::return_to_address(ADMIN, admin_cap);

    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, 0);

    // First deposit
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

    // Advance clock past maturity
    clock.increment_for_testing(Lock_DAY as u64 * MS_PER_DAY);

    // Withdraw, redeem loyalty tokens via reward pool, and redeposit base coins in same transaction
    scenario.next_tx(USER);
    {
        let receipt = ts::take_from_address<Receipt>(&scenario, USER);

        // Withdraw: get base coins and loyalty token rewards
        let (coin_base_opt, loyalty_tokens_opt) = pool.do_withdrawal(
            receipt,
            &clock,
            scenario.ctx(),
        );

        let coin_base = coin_base_opt.destroy_some();
        let loyalty_tokens = loyalty_tokens_opt.destroy_some();

        // Verify withdrawal amounts
        assert!(coin::value(&coin_base) == Deposit, 1);

        // Calculate expected loyalty token reward
        let expected_reward =
            (((Deposit as u128) * (2 * Base_APY as u128)) / 10_u128.pow(DEFAULT_DECIMAL)) * (Lock_DAY as u128) / 365;
        assert!(loyalty_tokens.value() == (expected_reward as u64), 2);

        // Redeem loyalty tokens via reward pool
        let mut reward_pool = ts::take_shared<RewardPool<Loyalty, Reward>>(&scenario);
        let mut policy = ts::take_shared<TokenPolicy<Loyalty>>(&scenario);

        let reward = reward_pool.do_claim(loyalty_tokens, &mut policy, none(), scenario.ctx());

        assert!(reward.value() == (expected_reward as u64)*10, 2);
        reward.burn_for_testing();

        // Redeposit the base coins for another lock period
        let receipt = pool.do_deposit(
            coin_base,
            Lock_DAY,
            none(),
            &clock,
            scenario.ctx(),
        );

        // Transfer the new receipt to the user
        let wrapper = pool.receipt_to_wrapper(receipt, scenario.ctx());
        // now wrapper can be transferred publicly
        transfer::public_transfer(wrapper, USER);

        ts::return_shared(pool);
        ts::return_shared(policy);
        ts::return_shared(reward_pool);
    };

    clock.destroy_for_testing();
    scenario.end();
}
