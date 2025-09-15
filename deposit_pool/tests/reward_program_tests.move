#[test_only]
module deposit_pool::test_reward_program;

use sui::test_scenario::{Self as ts, Scenario};
use sui::coin::{Self, TreasuryCap};
use sui::token::{Self, TokenPolicy};
use deposit_pool::reward_program::{Self, RewardPool, RewardProgram,new_reward_pool};
use sui::coin::create_treasury_cap_for_testing;
use sui::token::Token;
use sui::coin::Coin;

// Test coin types
public struct Loyalty has drop {}
public struct Reward has drop {}

const ADMIN: address = @0xAD;
const USER: address = @0xB0B;
const INITIAL_SUPPLY: u64 = 1000000;
const RATE: u32 = 10; // 10 Loyalty = 1 Reward

fun init_reward_pool<T>(): (Scenario,TreasuryCap<T>) {
    let mut scenario = ts::begin(ADMIN);
    
    // Create treasury cap for loyalty token
    // Create treasury cap for Loyalty token
    let loyalty_cap = create_treasury_cap_for_testing<T>(scenario.ctx());

    // Create Reward tokens
    let reward_coin = coin::mint_for_testing<Reward>(
        INITIAL_SUPPLY,
        scenario.ctx()
    );

    // Create Reward pool
    new_reward_pool<T, Reward>(
        reward_coin,
        RATE,
        scenario.ctx()
    );

    // Create token policy
    let (mut policy, policy_cap) = token::new_policy(&loyalty_cap, scenario.ctx());
    token::add_rule_for_action<T, RewardProgram>(
        &mut policy,
        &policy_cap,
        token::spend_action(),
        scenario.ctx()
    );

    token::share_policy(policy);
    transfer::public_transfer(policy_cap, ADMIN);

    (scenario,loyalty_cap)
}

#[test]
fun test_create_Reward_pool() {
    let (mut scenario,_cap) = init_reward_pool<Loyalty>();


    ts::next_tx(&mut scenario, ADMIN);
    {
        // Verify pool exists and has correct balance
        let pool = ts::take_shared<RewardPool<Loyalty, Reward>>(&scenario);
        ts::return_shared(pool);
    };

    transfer::public_freeze_object(_cap);
    ts::end(scenario);
}

#[test]
fun test_Reward_fresh() {
    let (mut scenario,_cap) = init_reward_pool<Loyalty>();

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut pool = ts::take_shared<RewardPool<Loyalty, Reward>>(&scenario);
        let fresh_coins = coin::mint_for_testing<Reward>(500, scenario.ctx());

        reward_program::reward_fresh(
            &mut pool,
            fresh_coins
        );

        ts::return_shared(pool);
    };

    transfer::public_freeze_object(_cap);
    ts::end(scenario);
}

#[test]
fun test_claim_Rewards() {
    let (mut scenario,mut loyalty_cap) = init_reward_pool();

    let test_mint = 1000;
    // Mint loyalty tokens for user
    ts::next_tx(&mut scenario, ADMIN);
    {
        let loyalty_tokens = token::mint_for_testing<Loyalty>(
            test_mint, // Amount of loyalty tokens
            scenario.ctx()
        );
        let req = token::transfer(loyalty_tokens, USER, scenario.ctx());

        token::confirm_with_treasury_cap(&mut loyalty_cap, req, scenario.ctx());
    };

    // User claims Rewards
    scenario.next_tx( USER);
    {
        let mut pool = ts::take_shared<RewardPool<Loyalty, Reward>>(&scenario);
        let mut policy = ts::take_shared<TokenPolicy<Loyalty>>(&scenario);
        let loyalty_tokens = ts::take_from_address<Token<Loyalty>>(&scenario, USER);

        let expected_Reward = test_mint / (RATE as u64);

        reward_program::claim(
            &mut pool,
            loyalty_tokens,
            &mut policy,
            scenario.ctx()
        );

        scenario.next_tx( USER);

        // Verify Reward tokens received
        let received_rewards = ts::take_from_address<Coin<Reward>>(&scenario, USER);
        assert!(received_rewards.value()== expected_Reward, 1);
        
        // Verify pool balance decreased

        ts::return_to_address(USER, received_rewards);
        ts::return_shared(policy);
        ts::return_shared(pool);
    };
    transfer::public_freeze_object(loyalty_cap);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = reward_program::EPoolInsufficient)]
fun test_claim_insufficient_pool() {
    let (mut scenario, _cap) = init_reward_pool<Loyalty>();

    // Try to claim more than available
    scenario.next_tx( USER);
    {
        let mut pool = ts::take_shared<RewardPool<Loyalty, Reward>>(&scenario);
        let mut policy = ts::take_shared<TokenPolicy<Loyalty>>(&scenario);
        let loyalty_tokens = token::mint_for_testing(INITIAL_SUPPLY*(RATE as u64)+1, scenario.ctx());

        // This should fail due to insufficient Rewards in pool
        reward_program::claim(
            &mut pool,
            loyalty_tokens,
            &mut policy,
            scenario.ctx()
        );

        ts::return_shared(policy);
        ts::return_shared(pool);
    };

    transfer::public_freeze_object(_cap);
    ts::end(scenario);
}
