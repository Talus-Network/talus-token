module dependency::test;

use std::vector::destroy;
use sui::coin::Coin;
use talus::us::US;

entry fun half(coin: &mut Coin<US>, ctx: &mut TxContext) {
    destroy!(coin.divide_into_n<US>(2, ctx), |c| transfer::public_transfer(c, ctx.sender()));
}
