DevNotes.md

- There are N liquidity pools of the same token,
- Each pool has a different price, some are pancake swap, or uni v3, or aerodrome,
- some pools have 40k , 500k, 6m , 10m liquidity

I'm thinking that I might be able to write a smart contract that iterates through the pools,
looking for the largest gap, and then buys the token from the cheapest pool, and sells it to
the most expensive pool all in one transaction, and if the result is not profitable it
automatically reverts.

Maybe it even calculates the max amounnt it could buy from the cheapest pool that would drive
the price up to the other pool and it would only buy the appropriate amount

I'm hoping I can submit the transaction through the flashbots api so that
there's no way for the tx to be frontrun by a MEV bot.

I'm also doing this on Base where gas fees are very cheap so the gas cost of
figuring out the best pool to buy and sell from isn't really a concern.

I could also do flash loans to maxamize my profit

cbBTC on base
0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf

https://uniswapv3book.com/milestone_2/output-amount-calculation.html
https://github.com/Jeiwan/uniswapv3-code

https://atiselsts.github.io/pdfs/uniswap-v3-liquidity-math.pdf
