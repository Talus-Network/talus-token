#[test_only]
module faucet::faucet_tests;

use sui::test_scenario::{Self as ts, ctx};
use sui::coin::{mint_for_testing,burn_for_testing};
use sui::test_utils::assert_eq;
use faucet::faucet::{Self, BiFaucet};

// Test coin types
public struct USDC {}
public struct ETH {}

#[test]
fun test_initiate() {
    let owner = @0xA;
    let mut scenario = ts::begin(owner);
    let init = 1_000_000;
    let rate = 1_000;
    let withdrawal_pct = 10;
    
    // Create initial coins
    let initial_usdc = mint_for_testing<USDC>(init, scenario.ctx());
    
    // Initialize faucet
    faucet::initiate<USDC, ETH>(initial_usdc, rate, withdrawal_pct,scenario.ctx());
    
    // Verify faucet exists and has correct initial balance
    ts::next_tx(&mut scenario, owner);
    {
        let faucet = ts::take_shared<BiFaucet<USDC, ETH>>(&scenario);
        let (balance_a, balance_b, rate, ratio) = faucet.get_balance_for_testing();
        assert_eq(balance_a, init);
        assert_eq(balance_b, 0);
        assert_eq(rate, rate);
        assert_eq(ratio, withdrawal_pct);
        ts::return_shared(faucet);
    };
    
    ts::end(scenario);
}

#[test]
fun test_over_mint() {
    let owner = @0xA;
    let user = @0xB;
    let mut scenario = ts::begin(owner);
    let init = 1_000_000;
    let rate = 1_000;
    let withdrawal_pct = 10;

    // Setup faucet with initial USDC
    let initial_usdc = mint_for_testing<USDC>(init, scenario.ctx());
    faucet::initiate<USDC, ETH>(initial_usdc, rate, withdrawal_pct,scenario.ctx());
    
    // User mints with ETH
    ts::next_tx(&mut scenario, user);
    {
        let mut faucet = ts::take_shared<BiFaucet<USDC, ETH>>(&scenario);
        
        let (max_mint,_) = faucet.max_withdrawal();

        // mint 1 more than allowed
        let mut eth_coin = mint_for_testing<ETH>(max_mint.divide_and_round_up(rate)+1, scenario.ctx());
        
        faucet::mint<USDC, ETH>(&mut faucet, &mut eth_coin, scenario.ctx());
        
        // should mint max_mint
        let (balance_a, balance_b, _,_) = faucet.get_balance_for_testing();
        assert_eq(balance_a, init-max_mint);
        assert_eq(balance_b, max_mint/rate);
        
        burn_for_testing(eth_coin);
        ts::return_shared(faucet);
    };
    
    ts::end(scenario);
}

#[test]
fun test_mint() {
    let owner = @0xA;
    let user = @0xB;
    let mut scenario = ts::begin(owner);
    let init = 1_000_000;
    let rate = 1_000;
    let withdrawal_pct = 10;
    
    // Setup faucet with initial USDC
    let initial_usdc = mint_for_testing<USDC>(init, scenario.ctx());
    faucet::initiate<USDC, ETH>(initial_usdc, rate, withdrawal_pct,scenario.ctx());
    
    // User mints with ETH
    ts::next_tx(&mut scenario, user);
    {
        let mut faucet = ts::take_shared<BiFaucet<USDC, ETH>>(&scenario);
        
        let (max_mint,_) = faucet.max_withdrawal();

        let mut eth_coin = mint_for_testing<ETH>(max_mint/rate, scenario.ctx());
        
        faucet::mint<USDC, ETH>(&mut faucet, &mut eth_coin, scenario.ctx());
        
        let (balance_a, balance_b, _,_) = faucet.get_balance_for_testing();
        assert_eq(balance_a, init - max_mint);
        assert_eq(balance_b, max_mint/rate);
        
        burn_for_testing(eth_coin);
        ts::return_shared(faucet);
    };
    
    ts::end(scenario);
}
#[test]
fun test_over_refund() {
    let owner = @0xA;
    let user = @0xB;
    let mut scenario = ts::begin(owner);
    
    let init = 1_000_000;
    let rate = 1_000;
    let mint = 100;
    let withdrawal_pct = 10;
    
    
    // Setup faucet with initial USDC and ETH
    let initial_usdc = mint_for_testing<USDC>(init, scenario.ctx());
    faucet::initiate<USDC, ETH>(initial_usdc, rate,withdrawal_pct, scenario.ctx());
    
    ts::next_tx(&mut scenario, user);
    {
        let mut faucet = ts::take_shared<BiFaucet<USDC, ETH>>(&scenario);
        let mut eth_coin = mint_for_testing<ETH>(mint, scenario.ctx());
        faucet::mint<USDC, ETH>(&mut faucet, &mut eth_coin, scenario.ctx());
        
         
        let (_,max_refund) = faucet.max_withdrawal();
        
        // technically, can withdrawal max_refund +1
        let mut usdc_coin = mint_for_testing<USDC>((max_refund+1)*rate, scenario.ctx());
        faucet::refund<USDC, ETH>(&mut faucet, &mut usdc_coin, scenario.ctx());
        
        let (balance_a, balance_b, _,_) = faucet.get_balance_for_testing();
        // Verify balances
        assert_eq(balance_a, init-(mint-max_refund)*rate); // 1000 + 200
        assert_eq(balance_b, mint-max_refund); // 100 - 100
        
        burn_for_testing(eth_coin);
        burn_for_testing(usdc_coin);
        ts::return_shared(faucet);
    };
    
    ts::end(scenario);
}

#[test]
fun test_refund() {
    let owner = @0xA;
    let user = @0xB;
    let mut scenario = ts::begin(owner);
    
    let init = 1_000_000;
    let rate = 1_000;
    let mint = 100;
    let withdrawal_pct = 10;
    
    
    // Setup faucet with initial USDC and ETH
    let initial_usdc = mint_for_testing<USDC>(init, scenario.ctx());
    faucet::initiate<USDC, ETH>(initial_usdc, rate,withdrawal_pct, scenario.ctx());
    
    ts::next_tx(&mut scenario, user);
    {
        let mut faucet = ts::take_shared<BiFaucet<USDC, ETH>>(&scenario);
        let mut eth_coin = mint_for_testing<ETH>(mint, scenario.ctx());
        faucet::mint<USDC, ETH>(&mut faucet, &mut eth_coin, scenario.ctx());
        
        let (_,max_refund) = faucet.max_withdrawal();
        let mut usdc_coin = mint_for_testing<USDC>(max_refund*rate, scenario.ctx());
        faucet::refund<USDC, ETH>(&mut faucet, &mut usdc_coin, scenario.ctx());
        
        let (balance_a, balance_b, _,_) = faucet.get_balance_for_testing();
        // Verify balances
        assert_eq(balance_a, init-rate*(mint-max_refund)); // 1000 + 200
        assert_eq(balance_b, mint-max_refund); // 100 - 100
        
        burn_for_testing(eth_coin);
        burn_for_testing(usdc_coin);
        ts::return_shared(faucet);
    };
    
    ts::end(scenario);
}
