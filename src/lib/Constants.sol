// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/**
 * @title Constants
 * @notice Shared constants for Morpho Vault V2 deployments on Ethereum Mainnet
 */
library Constants {
    // ============ TOKENS ============

    // Loan Tokens
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // Collateral Tokens
    address internal constant ST_USDS = 0x99CD4Ec3f88A45940936F469E4bB72A2A701EEB9;
    address internal constant S_USDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // ============ PROTOCOL ADDRESSES ============

    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant IRM_ADAPTIVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;

    // ============ FACTORIES & REGISTRY ============

    address internal constant ORACLE_FACTORY = 0x3A7bB36Ee3f3eE32A60e9f2b33c1e5f2E83ad766;
    address internal constant VAULT_V2_FACTORY = 0xA1D94F746dEfa1928926b84fB2596c06926C0405;
    address internal constant ADAPTER_FACTORY = 0x32BB1c0D48D8b1B3363e86eeB9A0300BAd61ccc1;
    address internal constant ADAPTER_REGISTRY = 0x3696c5eAe4a7Ffd04Ea163564571E9CD8Ed9364e;

    // ============ CHAINLINK PRICE FEEDS ============

    address internal constant CHAINLINK_CBBTC_USD = 0x2665701293fCbEB223D11A08D826563EDcCE423A;
    address internal constant CHAINLINK_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address internal constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant CHAINLINK_USDS_USD = 0xfF30586cD0F29eD462364C7e81375FC0C71219b1;
    address internal constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address internal constant CHAINLINK_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    // Morpho wstETH/stETH exchange rate adapter (Chainlink-compatible interface)
    address internal constant MORPHO_WSTETH_STETH_ADAPTER = 0x905b7dAbCD3Ce6B792D874e303D336424Cdb1421;

    // ============ LLTV VALUES ============

    uint256 internal constant LLTV_STUSDS = 860000000000000000; // 86%
    uint256 internal constant LLTV_VOLATILE = 860000000000000000; // 86%
    uint256 internal constant LLTV_SAVINGS = 965000000000000000; // 96.5%

    // ============ TOKEN DECIMALS ============

    uint256 internal constant DECIMALS_USDC = 6;
    uint256 internal constant DECIMALS_USDT = 6;
    uint256 internal constant DECIMALS_USDS = 18;
    uint256 internal constant DECIMALS_STUSDS = 18;
    uint256 internal constant DECIMALS_SUSDS = 18;
    uint256 internal constant DECIMALS_CBBTC = 8;
    uint256 internal constant DECIMALS_WSTETH = 18;
    uint256 internal constant DECIMALS_WETH = 18;

    // ============ ROLE ADDRESSES ============

    address internal constant SKY_MONEY_CURATOR = 0x3F32bC09d41eE699844F8296e806417D6bf61Bba;
    address internal constant ALLOCATOR_FLAGSHIP = 0xE4d5F54CE1830d5eCC49751021F306CFE7a52649;

    // ============ DEPLOYMENT PARAMS ============

    uint256 internal constant INITIAL_DEAD_DEPOSIT = 1e18; // 1 USDS
    uint256 internal constant INITIAL_DEAD_DEPOSIT_6DEC = 1e6; // 1 USDC or 1 USDT
    uint256 internal constant MAX_RATE = 63419583967; // 200% APR
    uint256 internal constant TIMELOCK_LOW = 3 days;
    uint256 internal constant TIMELOCK_HIGH = 7 days;
}
