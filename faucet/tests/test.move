#[test_only]
module faucet::faucet_tests;

use faucet::faucet::{Self, BiFaucet};
use std::unit_test::assert_eq;
use sui::coin::mint_for_testing;
use sui::test_scenario::{Self as ts, ctx};

// Test coin types
public struct USDC {}
public struct ETH {}

#[test]
fun test_initiate() {
    let owner = @0xA;
    let mut scenario = ts::begin(owner);
    let init = 10_000_000_000;
    let rate = 1_000;
    let withdrawal_pct = 10;

    // Create initial coins
    let initial_usdc = mint_for_testing<USDC>(init, scenario.ctx());

    // Initialize faucet
    faucet::new<USDC, ETH>(initial_usdc, rate, withdrawal_pct, scenario.ctx());

    // Verify faucet exists and has correct initial balance
    scenario.next_tx(owner);
    {
        let faucet = ts::take_shared<BiFaucet<USDC, ETH>>(&scenario);
        let (balance_target, balance_base, rate, ratio) = faucet.get_balance_for_testing();
        assert_eq!(balance_target, init);
        assert_eq!(balance_base, 0);
        assert_eq!(rate, rate);
        assert_eq!(ratio, withdrawal_pct);
        ts::return_shared(faucet);
    };

    ts::end(scenario);
}

#[test]
fun test_inject() {
    let owner = @0xA;
    let mut scenario = ts::begin(owner);
    let init = 5_000_000_000;
    let rate = 1_000;
    let withdrawal_pct = 10;

    // Create initial coins
    let initial_usdc = mint_for_testing<USDC>(init, scenario.ctx());

    // Initialize faucet
    faucet::new<USDC, ETH>(initial_usdc, rate, withdrawal_pct, scenario.ctx());

    // Verify faucet exists and has correct initial balance
    scenario.next_tx(owner);
    {
        let mut faucet = ts::take_shared<BiFaucet<USDC, ETH>>(&scenario);
        // Create initial coins
        let inject_coin = mint_for_testing<USDC>(init, scenario.ctx());

        // Initialize faucet
        faucet.inject(inject_coin);

        let (balance_target, balance_base, rate, ratio) = faucet.get_balance_for_testing();
        assert_eq!(balance_target, init*2);
        assert_eq!(balance_base, 0);
        assert_eq!(rate, rate);
        assert_eq!(ratio, withdrawal_pct);
        ts::return_shared(faucet);
    };

    ts::end(scenario);
}

#[test, expected_failure]
fun test_over_pct() {
    let owner = @0xA;
    let mut scenario = ts::begin(owner);
    let init = 10_000_000_000;
    let rate = 1_000;
    let withdrawal_pct = 101;

    // Create initial coins
    let initial_usdc = mint_for_testing<USDC>(init, scenario.ctx());

    // Initialize faucet
    faucet::new<USDC, ETH>(initial_usdc, rate, withdrawal_pct, scenario.ctx());
    ts::end(scenario);
}

#[test]
fun test_max_mintable() {
    let owner = @0xA;
    let mut scenario = ts::begin(owner);
    let init_target = 10_000_000_000;
    let rate = 3;
    let max_base = 1_000_000;
    let mut withdrawal_pct = 10;
    while (withdrawal_pct < 100) {
        // Create initial coins
        let initial_usdc = mint_for_testing<USDC>(init_target, scenario.ctx());

        // Initialize faucet
        faucet::new<USDC, ETH>(initial_usdc, rate, withdrawal_pct, scenario.ctx());
        scenario.next_tx(owner);
        let mut faucet = ts::take_shared<BiFaucet<USDC, ETH>>(&scenario);
        let eth_coin = mint_for_testing<ETH>(max_base, scenario.ctx());

        faucet::mint<USDC, ETH>(&mut faucet, eth_coin, scenario.ctx());

        // Verify faucet exists and has correct initial balance
        scenario.next_tx(owner);
        {
            let (balance_target, balance_base, _, _) = faucet.get_balance_for_testing();
            let (max_mint, max_withdrawal) = faucet.max_withdrawal();

            assert_eq!(balance_target*withdrawal_pct/100, max_mint);
            assert_eq!(balance_base*withdrawal_pct/100, max_withdrawal);
        };

        ts::return_shared(faucet);
        withdrawal_pct = withdrawal_pct + 10;
    };

    ts::end(scenario);
}

#[test]
fun test_over_mint() {
    let owner = @0xA;
    let user = @0xB;
    let mut scenario = ts::begin(owner);
    let init = 10_000_000_000;
    let rate = 1_000;
    let withdrawal_pct = 10;

    // Setup faucet with initial USDC
    let initial_usdc = mint_for_testing<USDC>(init, scenario.ctx());
    faucet::new<USDC, ETH>(initial_usdc, rate, withdrawal_pct, scenario.ctx());

    // User mints with ETH
    ts::next_tx(&mut scenario, user);
    {
        let mut faucet = ts::take_shared<BiFaucet<USDC, ETH>>(&scenario);

        let (max_mint, _) = faucet.max_withdrawal();

        // mint 1 more than allowed
        let over_mint = max_mint.divide_and_round_up(rate)+1;
        let eth_coin = mint_for_testing<ETH>(over_mint, scenario.ctx());

        faucet::mint<USDC, ETH>(&mut faucet, eth_coin, scenario.ctx());

        // should mint max_mint
        let (balance_target, balance_base, _, _) = faucet.get_balance_for_testing();
        assert_eq!(balance_target, init-max_mint);
        assert_eq!(balance_base, max_mint/rate);
        ts::return_shared(faucet);
    };
    ts::end(scenario);
}

#[test]
fun test_mint() {
    let owner = @0xA;
    let user = @0xB;
    let mut scenario = ts::begin(owner);
    let init = 10_000_000_000;
    let rate = 1_000;
    let withdrawal_pct = 10;

    // Setup faucet with initial USDC
    let initial_usdc = mint_for_testing<USDC>(init, scenario.ctx());
    faucet::new<USDC, ETH>(initial_usdc, rate, withdrawal_pct, scenario.ctx());

    // User mints with ETH
    ts::next_tx(&mut scenario, user);
    {
        let mut faucet = ts::take_shared<BiFaucet<USDC, ETH>>(&scenario);

        let (max_mint, _) = faucet.max_withdrawal();

        let eth_coin = mint_for_testing<ETH>(max_mint/rate, scenario.ctx());

        faucet::mint<USDC, ETH>(&mut faucet, eth_coin, scenario.ctx());
        let (balance_target, balance_base, _, _) = faucet.get_balance_for_testing();
        assert_eq!(balance_target, init - max_mint);
        assert_eq!(balance_base, max_mint/rate);

        ts::return_shared(faucet);
    };

    ts::end(scenario);
}
#[test]
fun test_over_refund() {
    let owner = @0xA;
    let user = @0xB;
    let mut scenario = ts::begin(owner);

    let init = 9_000_000_000;
    let rate = 1_000;
    let mint = 100;
    let withdrawal_pct = 10;

    // Setup faucet with initial USDC and ETH
    let initial_usdc = mint_for_testing<USDC>(init, scenario.ctx());
    faucet::new<USDC, ETH>(initial_usdc, rate, withdrawal_pct, scenario.ctx());

    ts::next_tx(&mut scenario, user);
    {
        let mut faucet = ts::take_shared<BiFaucet<USDC, ETH>>(&scenario);
        let eth_coin = mint_for_testing<ETH>(mint, scenario.ctx());
        faucet::mint<USDC, ETH>(&mut faucet, eth_coin, scenario.ctx());

        let (_, max_refund) = faucet.max_withdrawal();

        // technically, can withdrawal max_refund +1
        let usdc_coin = mint_for_testing<USDC>((max_refund+1)*rate, scenario.ctx());
        faucet::refund<USDC, ETH>(&mut faucet, usdc_coin, scenario.ctx());

        let (balance_target, balance_base, _, _) = faucet.get_balance_for_testing();
        // Verify balances
        assert_eq!(balance_target, init-(mint-max_refund)*rate); // 1000 + 200
        assert_eq!(balance_base, mint-max_refund); // 100 - 100

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
    faucet::new<USDC, ETH>(initial_usdc, rate, withdrawal_pct, scenario.ctx());

    ts::next_tx(&mut scenario, user);
    {
        let mut faucet = ts::take_shared<BiFaucet<USDC, ETH>>(&scenario);
        let eth_coin = mint_for_testing<ETH>(mint, scenario.ctx());
        faucet::mint<USDC, ETH>(&mut faucet, eth_coin, scenario.ctx());

        let (_, max_refund) = faucet.max_withdrawal();
        let usdc_coin = mint_for_testing<USDC>(max_refund*rate, scenario.ctx());
        faucet::refund<USDC, ETH>(&mut faucet, usdc_coin, scenario.ctx());

        let (balance_target, balance_base, _, _) = faucet.get_balance_for_testing();
        // Verify balances
        assert_eq!(balance_target, init-rate*(mint-max_refund)); // 1000 + 200
        assert_eq!(balance_base, mint-max_refund); // 100 - 100

        ts::return_shared(faucet);
    };

    ts::end(scenario);
}
