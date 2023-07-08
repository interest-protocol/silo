module silo::silo_core {
    use std::ascii::{String};

  use sui::object::{Self, UID, ID};
  use sui::package::{Self, Publisher};
  use sui::object_table::{Self, ObjectTable};
  use sui::balance::{Self, Balance};
  use sui::vec_map::{Self, VecMap};
  use sui::clock::{Self, Clock};
  use sui::transfer;
  use sui::tx_context::{Self, TxContext};
  use sui::coin::{Self, Coin};
  use sui::event::{emit};

  use silo::rebase::{Self, Rebase};
  use silo::math::{d_fdiv, d_fmul_u256, double_scalar, d_fmul};
  use silo::lib::{are_types_sorted, get_type_name_string};

  const ERROR_NO_ADDRESS_ZERO: u64 = 0;
  const ERROR_UNSORTED_TYPES: u64 = 1;
  const ERROR_FLASH_LOAN_UNDERWAY: u64 = 2;

  // OTW
  struct SILO_CORE has drop {}

  struct SiloStorage has key {
    id: UID,
    registry: VecMap<String, ID>,
    publisher: Publisher,
  }

  struct Account has key, store {
    id: UID,
    principal: u64,
    shares: u64,
    collateral_rewards: u64,
    loan_rewards: u64,
    collateral_enabled: bool,
    collateral_rewards_paid: u256,
    loan_rewards_paid: u256
  }

  struct CoinData has store {
    ipx_per_ms: u64,
    // Liquidation
    penalty_fee: u256,
    protocol_percentage: u256,
    // IPX rewards
    accrued_collateral_rewards_per_share: u256,
    accrued_loan_rewards_per_share: u256,
    // Properly calculate rewards and loan amounts
    decimals_factor: u64,
    ltv: u256,
    // Protocol Revenue Data
    reserve_factor: u256,
    total_reserves: u64,
    // Loan Data
    accrued_timestamp: u64,
    collateral_rebase: Rebase,
    loan_rebase: Rebase,
    // Interest rate data
    base_rate_per_ms: u256,
    multiplier_per_ms: u256,
    jump_multiplier_per_ms: u256,
    kink: u256 
  }

  struct SiloMarket<phantom X, phantom Y> has drop {}

  struct Silo<phantom X, phantom Y> has key {
    id: UID,
    accounts_x: ObjectTable<address, Account>,
    accounts_y: ObjectTable<address, Account>,
    balance_x: Balance<X>,
    balance_y: Balance<Y>,
    coin_x_data: CoinData,
    coin_y_data: CoinData,
    lock: bool,
  }

  struct SiloAdminCap has key {
    id: UID
  }

  // Events
  struct NewAdmin has copy, drop {
    admin: address
  }

  struct NewSilo<phantom X, phantom Y> has copy, drop {
    silo_id: ID
  }

  struct Deposit<phantom Silo, phantom Coin> has copy, drop {
    silo_id: ID,
    shares: u64,
    value: u64,
    pending_rewards: u256,
    sender: address
  }

  fun init(witness: SILO_CORE, ctx: &mut TxContext) {
    transfer::transfer(
      SiloAdminCap {
        id: object::new(ctx)
      },
      tx_context::sender(ctx)
    );

    transfer::share_object(
      SiloStorage {
        id: object::new(ctx),
        registry: vec_map::empty(),
        publisher: package::claim<SILO_CORE>(witness, ctx),
      }
    )
  }

  public(friend) fun deposit_x<X, Y>(
    market: &mut Silo<X, Y>, 
    clock_object: &Clock,
    asset: Coin<X>,
    sender: address,
    ctx: &mut TxContext
  ) {
   assert!(!market.lock, ERROR_FLASH_LOAN_UNDERWAY);

    // We need to register his account on the first deposit call, if it does not exist.
    init_account(&mut market.accounts_x, sender, ctx);

    let cash = balance::value(&market.balance_x);

    accrue_internal(&mut market.coin_x_data, clock_object, cash);

    let account = object_table::borrow_mut(&mut market.accounts_x, sender);

    let pending_rewards = 0;

    if (account.shares > 0) 
        pending_rewards = (
          ((account.shares as u256) * 
          market.coin_x_data.accrued_collateral_rewards_per_share) / 
          (market.coin_x_data.decimals_factor as u256)) - 
          account.collateral_rewards_paid;
      
      // Save the value of the coin being deposited in memory
      let asset_value = coin::value(&asset);

      // Update the collateral rebase. 
      // We round down to give the edge to the protocol
      let shares = rebase::add_elastic(&mut market.coin_x_data.collateral_rebase, asset_value, false);

      // Deposit the Coin<T> in the market
      balance::join(&mut market.balance_x, coin::into_balance(asset));

      // Assign the additional shares to the sender
      account.shares = account.shares + shares;
      // Consider all rewards earned by the sender paid
      account.collateral_rewards_paid = ((account.shares as u256) * market.coin_x_data.accrued_collateral_rewards_per_share) / (market.coin_x_data.decimals_factor as u256);

      // Update the rewards
      account.collateral_rewards = account.collateral_rewards + (pending_rewards as u64);

      emit(
        Deposit<SiloMarket<X, Y>, X> {
          silo_id: object::uid_to_inner(&market.id),
          shares,
          value: asset_value,
          pending_rewards,
          sender
        }
      );
  }

  fun init_account(accounts_table: &mut ObjectTable<address, Account>, user: address, ctx: &mut TxContext) {
    if (!object_table::contains(accounts_table, user)) {
          object_table::add(
            accounts_table,
            user,
            Account {
              id: object::new(ctx),
              principal: 0,
              shares: 0,
              collateral_rewards: 0,
              loan_rewards: 0,
              collateral_rewards_paid: 0,
              loan_rewards_paid: 0,
              collateral_enabled: false
            }
        );
    };
  }

  fun accrue_internal(coin_data: &mut CoinData, clock_object: &Clock, cash: u64) {
    let current_timestamp_ms = clock::timestamp_ms(clock_object);
    let timestamp_ms_delta = current_timestamp_ms - coin_data.accrued_timestamp;
    let total_reserves = coin_data.total_reserves;
    let loan_elastic = rebase::elastic(&coin_data.loan_rebase);

    // If no time has passed since the last update, there is nothing to do.
    if (timestamp_ms_delta == 0) return;

    // Calculate the interest rate % accumulated per millisecond since the last update
    let interest_rate = timestamp_ms_delta * get_borrow_rate_per_ms(
          coin_data,
          cash,
          loan_elastic,
          total_reserves
        );


    // Calculate the total interest rate amount earned by the protocol
    let interest_rate_amount = d_fmul(interest_rate, rebase::elastic(&coin_data.loan_rebase));
    // Calculate how much interest rate will be given to the reserves
    let reserve_interest_rate_amount = d_fmul_u256(interest_rate_amount, coin_data.reserve_factor);

    // Increase the total borrows by the interest rate amount
    rebase::increase_elastic(&mut coin_data.loan_rebase, (interest_rate_amount as u64));
    // Increase the total amount earned 
    rebase::increase_elastic(&mut coin_data.collateral_rebase, (interest_rate_amount - reserve_interest_rate_amount as u64));

    // Update the accrued timestamp
    coin_data.accrued_timestamp = current_timestamp_ms;
    // Update the reserves
    coin_data.total_reserves = coin_data.total_reserves + (reserve_interest_rate_amount as u64);

    // Total IPX rewards accumulated since the last update
    let rewards = (timestamp_ms_delta as u256) * (coin_data.ipx_per_ms as u256);

    // Split the rewards evenly between loans and collateral
    let collateral_rewards = rewards / 2; 
    let loan_rewards = rewards - collateral_rewards;

    // Get the total shares amount of the market
    let total_shares = rebase::base(&coin_data.collateral_rebase);
    // Get the total borrow amount of the market
    let total_principal = rebase::base(&coin_data.loan_rebase);

    // Update the total rewards per share.

    // Avoid zero division
    if (total_shares != 0)
      coin_data.accrued_collateral_rewards_per_share = coin_data.accrued_collateral_rewards_per_share + ((collateral_rewards * (coin_data.decimals_factor as u256)) / (total_shares as u256));

    // Avoid zero division
    if (total_principal != 0)  
      coin_data.accrued_loan_rewards_per_share = coin_data.accrued_loan_rewards_per_share + ((loan_rewards * (coin_data.decimals_factor as u256)) / (total_principal as u256));    
  }

  entry public fun create_silo<X, Y>(
    _: &SiloAdminCap,
    storage: &mut SiloStorage,
    coin_x_data: CoinData,
    coin_y_data: CoinData,
    ctx: &mut TxContext
    ) {
      assert!(are_types_sorted<X, Y>(), ERROR_UNSORTED_TYPES);

      // Only one Silo per 2 coins
      let key = get_type_name_string<SiloMarket<X, Y>>();

      let id = object::new(ctx);

      let inner_id = object::uid_to_inner(&id);

      // Save the ID to retrieve off chain
      vec_map::insert(&mut storage.registry, key, inner_id);

      let silo = Silo<X, Y>{
        id,
        accounts_x: object_table::new(ctx),
        accounts_y: object_table::new(ctx),
        balance_x: balance::zero<X>(),
        balance_y: balance::zero<Y>(),
        coin_x_data,
        coin_y_data,
        lock: false,
      };

      transfer::share_object(silo);

       emit(NewSilo<X, Y> { silo_id: inner_id });
  }

    /**
  * @dev It returns the interest rate amount per millisecond given a market
  * @param coin_data {CoinData}
  * @param cash The current liquidity of said market
  * @param total_borrow_amount The total borrow amount of said market
  * @param reserves The total protocol reserves amount for said market
  * @return u64 The interest rate amount to charge every millisecond
  */
  public fun get_borrow_rate_per_ms(
    coin_data: &CoinData,
    cash: u64,
    total_borrow_amount: u64,
    reserves: u64
  ): u64 {
    (get_borrow_rate_per_ms_internal(coin_data, cash, total_borrow_amount, reserves) as u64)
  }

  /**
  * @dev It returns the interest rate amount earned by liquidity suppliers per millisecond
  * @param coin_data {CoinData}
  * @param cash The current liquidity of said market
  * @param total_borrow_amount The total borrow amount of said market
  * @param reserves The total protocol reserves amount for said market
  * @param reserve_factor
  * @return u64 The interest rate amount to pay liquidity suppliers every millisecond  
  */
  public fun get_supply_rate_per_ms(
    coin_data: &CoinData,
    cash: u64,
    total_borrow_amount: u64,
    reserves: u64,
    reserve_factor: u256
  ): u64 {
    let borrow_rate = d_fmul_u256((get_borrow_rate_per_ms_internal(coin_data, cash, total_borrow_amount, reserves) as u256), double_scalar() - reserve_factor);

    (d_fmul_u256(get_utilization_rate_internal(cash, total_borrow_amount, reserves), borrow_rate) as u64)
  }

  /**
  * @dev It holds the logic that calculates the interest rate amount per millisecond given a market
  * @param coin_data {CoinData}
  * @param cash The current liquidity of said market
  * @param total_borrow_amount The total borrow amount of said market
  * @param reserves The total protocol reserves amount for said market
  * @return u64 The interest rate amount to charge every millisecond
  */
  fun get_borrow_rate_per_ms_internal(
    coin_data: &CoinData,
    cash: u64,
    total_borrow_amount: u64,
    reserves: u64
    ): u64 {
      let utilization_rate = get_utilization_rate_internal(cash, total_borrow_amount, reserves);

      if (coin_data.kink >= utilization_rate) {
        (d_fmul_u256(utilization_rate, coin_data.multiplier_per_ms) + coin_data.base_rate_per_ms as u64)
      } else {
        let normal_rate = d_fmul_u256(coin_data.kink, coin_data.multiplier_per_ms) + coin_data.base_rate_per_ms;

        let excess_utilization = utilization_rate - coin_data.kink;
        
        (d_fmul_u256(excess_utilization, coin_data.jump_multiplier_per_ms) + normal_rate as u64)
      }
    }

  /**
  * @dev It returns the % that a market is being based on Supply, Borrow, Reserves in 1e18 scale
  * @param cash The current liquidity of said market
  * @param total_borrow_amount The total borrow amount of said market
  * @param reserves The total protocol reserves amount for said market
  * @return u256 The utilization rate in 1e18 scale
  */
  fun get_utilization_rate_internal(cash: u64, total_borrow_amount: u64, reserves: u64): u256 {
    if (total_borrow_amount == 0) { 0 } else { 
      d_fdiv(total_borrow_amount, (cash + total_borrow_amount) - reserves)
     }
  }

    /**
  * @notice It allows the admin to transfer the rights to a new admin
  * @param admin_cap The SiloAdminCap
  * @param new_admin The address f the new admin
  * Requirements: 
  * - The new_admin cannot be the address zero.
  */
  entry public fun transfer_admin_cap(
    admin_cap: SiloAdminCap, 
    new_admin: address
  ) {
    assert!(new_admin != @0x0, ERROR_NO_ADDRESS_ZERO);
    transfer::transfer(admin_cap, new_admin);
    emit(NewAdmin { admin: new_admin });
  }
}