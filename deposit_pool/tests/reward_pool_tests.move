#[test_only]
module deposit_pool::test_reward_pool;

use deposit_pool::reward_pool::{
    Self,
    RewardPool,
    RewardProgram,
    new_reward_pool,
    revoke_pool,
    update_rate,
    E_NOT_ADMIN,
    AdminCap
};
use sui::coin::{Self, TreasuryCap, create_treasury_cap_for_testing, Coin};
use sui::test_scenario::{Self as ts, Scenario};
use sui::token::{Self, TokenPolicy, Token};

// Test coin types
public struct Loyalty has drop {}
public struct Reward has drop {}

const ADMIN: address = @0xAD;
const USER: address = @0xB0B;
const INITIAL_SUPPLY: u64 = 1000000;
const RATE: u32 = 10; // 10 Loyalty = 1 Reward

fun init_reward_pool<T>(): (Scenario, TreasuryCap<T>) {
    let mut scenario = ts::begin(ADMIN);

    // Create treasury cap for Loyalty token
    let loyalty_cap = create_treasury_cap_for_testing<T>(scenario.ctx());

    // Create Reward tokens
    let reward_coin = coin::mint_for_testing<Reward>(
        INITIAL_SUPPLY,
        scenario.ctx(),
    );

    // Create Reward pool
    new_reward_pool<T, Reward>(
        reward_coin,
        RATE,
        scenario.ctx(),
    );

    // Create token policy
    let (mut policy, policy_cap) = token::new_policy(&loyalty_cap, scenario.ctx());
    token::add_rule_for_action<T, RewardProgram>(
        &mut policy,
        &policy_cap,
        token::spend_action(),
        scenario.ctx(),
    );

    token::share_policy(policy);
    transfer::public_transfer(policy_cap, ADMIN);

    (scenario, loyalty_cap)
}

#[test]
fun test_create_reward_pool() {
    let (mut scenario, _cap) = init_reward_pool<Loyalty>();

    scenario.next_tx(ADMIN);
    {
        // Verify pool exists and has correct balance
        let pool = ts::take_shared<RewardPool<Loyalty, Reward>>(&scenario);
        ts::return_shared(pool);
    };

    transfer::public_freeze_object(_cap);
    ts::end(scenario);
}

#[test]
fun test_reward_fresh() {
    let (mut scenario, _cap) = init_reward_pool<Loyalty>();

    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<RewardPool<Loyalty, Reward>>(&scenario);
        let fresh_coins = coin::mint_for_testing<Reward>(500, scenario.ctx());

        reward_pool::reward_fresh(
            &mut pool,
            fresh_coins,
        );

        ts::return_shared(pool);
    };

    transfer::public_freeze_object(_cap);
    ts::end(scenario);
}

#[test]
fun test_claim_rewards() {
    let (mut scenario, mut loyalty_cap) = init_reward_pool();

    let test_mint = 1000;
    // Mint loyalty tokens for user
    scenario.next_tx(ADMIN);
    {
        let loyalty_tokens = token::mint_for_testing<Loyalty>(
            test_mint, // Amount of loyalty tokens
            scenario.ctx(),
        );
        let req = token::transfer(loyalty_tokens, USER, scenario.ctx());

        token::confirm_with_treasury_cap(&mut loyalty_cap, req, scenario.ctx());
    };

    // User claims Rewards
    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<RewardPool<Loyalty, Reward>>(&scenario);
        let mut policy = ts::take_shared<TokenPolicy<Loyalty>>(&scenario);
        let loyalty_tokens = ts::take_from_address<Token<Loyalty>>(&scenario, USER);

        let expected_reward = test_mint / (RATE as u64);

        reward_pool::claim(
            &mut pool,
            loyalty_tokens,
            &mut policy,
            scenario.ctx(),
        );

        scenario.next_tx(USER);

        // Verify Reward tokens received
        let received_rewards = ts::take_from_address<Coin<Reward>>(&scenario, USER);
        assert!(received_rewards.value() == expected_reward, 1);

        // Verify pool balance decreased
        ts::return_to_address(USER, received_rewards);
        ts::return_shared(policy);
        ts::return_shared(pool);
    };
    transfer::public_freeze_object(loyalty_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = reward_pool::E_POOL_INSUFFICIENT)]
fun test_claim_insufficient_pool() {
    let (mut scenario, _cap) = init_reward_pool<Loyalty>();

    // Try to claim more than available
    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<RewardPool<Loyalty, Reward>>(&scenario);
        let mut policy = ts::take_shared<TokenPolicy<Loyalty>>(&scenario);
        let loyalty_tokens = token::mint_for_testing(
            INITIAL_SUPPLY * (RATE as u64) + 1,
            scenario.ctx(),
        );

        // This should fail due to insufficient Rewards in pool
        reward_pool::claim(
            &mut pool,
            loyalty_tokens,
            &mut policy,
            scenario.ctx(),
        );

        ts::return_shared(policy);
        ts::return_shared(pool);
    };

    transfer::public_freeze_object(_cap);
    ts::end(scenario);
}

#[test]
fun test_revoke_with_admin() {
    let (mut scenario, _cap) = init_reward_pool<Loyalty>();

    scenario.next_tx(ADMIN);
    {
        // Take ownership of the pool and the admin cap and revoke (should succeed)
        let pool = ts::take_shared<RewardPool<Loyalty, Reward>>(&scenario);
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

        revoke_pool(
            pool,
            &mut admin_cap,
            scenario.ctx(),
        );

        scenario.next_tx(ADMIN);
        // Admin should receive the pool's reward coins
        let received = ts::take_from_address<Coin<Reward>>(&scenario, ADMIN);
        assert!(received.value() == INITIAL_SUPPLY, 1);

        // Return objects back to address space
        ts::return_to_address(ADMIN, received);
        ts::return_to_address(ADMIN, admin_cap);
    };
    transfer::public_freeze_object(_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = E_NOT_ADMIN)]
fun test_revoke_with_wrong_admin() {
    let (mut scenario, _cap) = init_reward_pool<Loyalty>();

    // Create a second reward pool under a different address to obtain a different AdminCap
    let other: address = @0xE0;
    scenario.next_tx(other);
    {
        let reward_coin2 = coin::mint_for_testing<Reward>(10, scenario.ctx());
        new_reward_pool<Loyalty, Reward>(reward_coin2, RATE, scenario.ctx());
    };
    scenario.next_tx(ADMIN);
    {
        let second_pool = ts::take_shared<RewardPool<Loyalty, Reward>>(&scenario);
        let mut first_admin = scenario.take_from_sender<AdminCap>();

        revoke_pool(
            second_pool,
            &mut first_admin,
            scenario.ctx(),
        );

        // In case of unexpected success, return the wrong_admin back
        scenario.return_to_sender(first_admin);
    };
    transfer::public_freeze_object(_cap);
    ts::end(scenario);
}

#[test]
fun test_update_exchange_rate() {
    let new_rate: u32 = 20; // new exchange rate for tests

    let (mut scenario, mut loyalty_cap) = init_reward_pool<Loyalty>();

    // Admin updates the exchange rate
    scenario.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<RewardPool<Loyalty, Reward>>(&scenario);
        let mut admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

        // Update rate to NEW_RATE
        update_rate(
            &mut pool,
            &mut admin_cap,
            new_rate,
        );

        ts::return_shared(pool);
        ts::return_to_address(ADMIN, admin_cap);
    };

    // Mint loyalty tokens for user
    let test_mint = 1000;
    scenario.next_tx(ADMIN);
    {
        let loyalty_tokens = token::mint_for_testing<Loyalty>(
            test_mint,
            scenario.ctx(),
        );
        let req = token::transfer(loyalty_tokens, USER, scenario.ctx());
        token::confirm_with_treasury_cap(&mut loyalty_cap, req, scenario.ctx());
    };

    // User claims rewards under the updated rate
    scenario.next_tx(USER);
    {
        let mut pool = ts::take_shared<RewardPool<Loyalty, Reward>>(&scenario);
        let mut policy = ts::take_shared<TokenPolicy<Loyalty>>(&scenario);
        let loyalty_tokens = ts::take_from_address<Token<Loyalty>>(&scenario, USER);

        let expected_reward = test_mint / (new_rate as u64);

        reward_pool::claim(
            &mut pool,
            loyalty_tokens,
            &mut policy,
            scenario.ctx(),
        );

        scenario.next_tx(USER);

        let received_rewards = ts::take_from_address<Coin<Reward>>(&scenario, USER);
        assert!(received_rewards.value() == expected_reward, 1);

        ts::return_to_address(USER, received_rewards);
        ts::return_shared(policy);
        ts::return_shared(pool);
    };
    transfer::public_freeze_object(loyalty_cap);
    ts::end(scenario);
}
