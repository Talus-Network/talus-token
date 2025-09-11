#[test_only]
module loyalty_pool::test;

use loyalty_pool::loyalty_pool::{initiate, AdminCap, LoyaltyPool};
use sui::coin::create_treasury_cap_for_testing;
use sui::test_scenario as test;

public struct Loyalty has drop {}
public struct Base has drop {}

#[test]
fun test_init() {
    let user = @0xa11ce;
    let test_apy = 10;
    let mut test = test::begin(user);

    test.next_tx(user);

    let loyalty_cap = create_treasury_cap_for_testing<Loyalty>(test.ctx());

    initiate<Base, Loyalty>(loyalty_cap, test_apy, test.ctx());

    test.next_tx(user);

    let admin_cap = test.take_from_sender<AdminCap>();
    let pool = test.take_shared<LoyaltyPool<Base, Loyalty>>();

    // ensure object created
    test.return_to_sender(admin_cap);
    test::return_shared(pool);
    test.end();
}
