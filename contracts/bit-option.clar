;; Project: BitOption - Bitcoin-Powered Options Protocol
;;
;; SUMMARY:
;; BitOptionX is a decentralized options trading protocol
;; built on Stacks, secured by Bitcoin. It enables users
;; to create, exercise, and manage CALL and PUT options
;; using sBTC as collateral.
;;
;; DESCRIPTION:
;; This smart contract implements a non-custodial,
;; collateralized options marketplace designed for Bitcoin
;; holders and DeFi participants on the Stacks blockchain.
;; It integrates with a BTC price oracle, supports
;; time-based expiry and strike pricing, and enforces
;; collateralization and validation rules for secure
;; financial derivatives.
;;
;; Key Features:
;; - Trust-minimized CALL/PUT options on BTC
;; - Oracle-powered real-time pricing
;; - Secure sBTC-based collateralization
;; - Customizable protocol fees and validity windows
;; - Transparent on-chain lifecycle tracking of options

;; CONSTANTS & CONFIGURATION

;; Contract Owner
(define-constant CONTRACT_OWNER tx-sender)

;; Parameter Limits
(define-constant MAX_FEE_BASIS_POINTS u10000) ;; 100% maximum fee
(define-constant MAX_COLLATERAL_RATIO u1000) ;; 1000% maximum collateral
(define-constant MIN_DEPOSIT_AMOUNT u1000) ;; Minimum deposit threshold
(define-constant MAX_DEPOSIT_AMOUNT u100000000000) ;; Maximum deposit cap
(define-constant MIN_VALIDITY_WINDOW u10) ;; Minimum price validity (blocks)
(define-constant MAX_VALIDITY_WINDOW u1440) ;; Maximum price validity (~24 hours)

;; ERROR CODES

(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_INVALID_AMOUNT (err u101))
(define-constant ERR_INSUFFICIENT_BALANCE (err u102))
(define-constant ERR_OPTION_NOT_FOUND (err u103))
(define-constant ERR_OPTION_EXPIRED (err u104))
(define-constant ERR_INVALID_STRIKE_PRICE (err u105))
(define-constant ERR_INVALID_EXPIRY (err u106))
(define-constant ERR_INSUFFICIENT_COLLATERAL (err u107))
(define-constant ERR_OPTION_NOT_EXERCISABLE (err u108))
(define-constant ERR_STALE_PRICE (err u109))
(define-constant ERR_INVALID_PRICE (err u110))
(define-constant ERR_OPTION_NOT_EXPIRED (err u111))
(define-constant ERR_INVALID_PARAMETER (err u112))

;; DATA VARIABLES

;; Protocol Parameters
(define-data-var min-collateral-ratio uint u150) ;; 150% default collateral ratio
(define-data-var platform-fee uint u10) ;; 0.1% platform fee (basis points)
(define-data-var next-option-id uint u0) ;; Option ID counter

;; Oracle Configuration
(define-data-var oracle-address principal CONTRACT_OWNER)
(define-data-var btc-price uint u0)
(define-data-var price-last-updated uint u0)
(define-data-var price-validity-window uint u150) ;; ~25 minutes validity window

;; DATA MAPS

;; Options Storage - Core option contract data
(define-map options
  uint ;; option-id
  {
    creator: principal,
    holder: principal,
    option-type: (string-ascii 4), ;; "CALL" or "PUT"
    strike-price: uint,
    expiry: uint,
    amount: uint,
    collateral: uint,
    status: (string-ascii 10), ;; "ACTIVE", "EXERCISED", "EXPIRED"
  }
)

;; User Balances - Track user deposits and locked collateral
(define-map user-balances
  principal
  {
    sbtc-balance: uint,
    locked-collateral: uint,
  }
)

;; ORACLE FUNCTIONS

;; Update BTC Price - Oracle-only function for price feeds
(define-public (update-btc-price (new-price uint))
  (begin
    (asserts! (is-eq tx-sender (var-get oracle-address)) ERR_NOT_AUTHORIZED)
    (asserts! (> new-price u0) ERR_INVALID_PRICE)
    (var-set btc-price new-price)
    (var-set price-last-updated stacks-block-height)
    (ok true)
  )
)

;; Get Current BTC Price - Validates price freshness
(define-read-only (get-current-btc-price)
  (let (
      (price (var-get btc-price))
      (last-updated (var-get price-last-updated))
      (validity-window (var-get price-validity-window))
    )
    (asserts! (> price u0) ERR_INVALID_PRICE)
    (asserts! (< (- stacks-block-height last-updated) validity-window)
      ERR_STALE_PRICE
    )
    (ok price)
  )
)

;; Set Oracle Address - Admin function to update oracle
(define-public (set-oracle-address (new-oracle principal))
  (begin
    (asserts! (is-contract-owner) ERR_NOT_AUTHORIZED)
    (asserts! (not (is-eq new-oracle 'SP000000000000000000002Q6VF78))
      ERR_INVALID_PARAMETER
    )
    (var-set oracle-address new-oracle)
    (ok true)
  )
)

;; Set Price Validity Window - Configure price staleness threshold
(define-public (set-price-validity-window (new-window uint))
  (begin
    (asserts! (is-contract-owner) ERR_NOT_AUTHORIZED)
    (asserts!
      (and
        (>= new-window MIN_VALIDITY_WINDOW)
        (<= new-window MAX_VALIDITY_WINDOW)
      )
      ERR_INVALID_PARAMETER
    )
    (var-set price-validity-window new-window)
    (ok true)
  )
)

;; PRIVATE HELPER FUNCTIONS

;; Authorization Check - Verify contract owner
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT_OWNER)
)

;; Option Expiry Check - Validate option is not expired
(define-private (check-expiry (option-id uint))
  (let (
      (option (unwrap! (map-get? options option-id) ERR_OPTION_NOT_FOUND))
      (current-height stacks-block-height)
    )
    (if (> current-height (get expiry option))
      ERR_OPTION_EXPIRED
      (ok true)
    )
  )
)

;; Balance Management - Update user balances with safety checks
(define-private (update-user-balance
    (user principal)
    (delta uint)
    (is-subtract bool)
  )
  (let (
      (current-balance (default-to {
        sbtc-balance: u0,
        locked-collateral: u0,
      }
        (map-get? user-balances user)
      ))
      (current-sbtc (get sbtc-balance current-balance))
      (new-balance (if is-subtract
        (begin
          (asserts! (>= current-sbtc delta) ERR_INSUFFICIENT_BALANCE)
          (- current-sbtc delta)
        )
        (+ current-sbtc delta)
      ))
    )
    (ok (map-set user-balances user
      (merge current-balance { sbtc-balance: new-balance })
    ))
  )
)

;; CORE PUBLIC FUNCTIONS

;; Deposit sBTC - Fund user account for trading
(define-public (deposit-sbtc (amount uint))
  (begin
    ;; Validate deposit parameters
    (asserts!
      (and
        (>= amount MIN_DEPOSIT_AMOUNT)
        (<= amount MAX_DEPOSIT_AMOUNT)
      )
      ERR_INVALID_AMOUNT
    )
    ;; Transfer STX and update balance
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (try! (update-user-balance tx-sender amount false))
    (ok true)
  )
)